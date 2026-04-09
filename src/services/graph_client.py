"""Microsoft Graph API client with MSAL token caching.

Acquires tokens via client credentials flow and provides helper methods
for common Graph API operations used by intent handlers.
"""

import logging
from typing import Any

import msal
import requests

from services.keyvault_client import AppSecrets, get_secrets

logger = logging.getLogger(__name__)

GRAPH_BASE_URL = "https://graph.microsoft.com/v1.0"
GRAPH_SCOPE = ["https://graph.microsoft.com/.default"]

# Module-level MSAL app — persists across requests within the same Function instance
_msal_app: msal.ConfidentialClientApplication | None = None


def _get_msal_app(secrets: AppSecrets) -> msal.ConfidentialClientApplication:
    """Get or create the MSAL ConfidentialClientApplication (cached per instance)."""
    global _msal_app
    if _msal_app is None:
        authority = f"https://login.microsoftonline.com/{secrets.tenant_id}"
        _msal_app = msal.ConfidentialClientApplication(
            client_id=secrets.client_id,
            client_credential=secrets.client_secret,
            authority=authority,
        )
        logger.info("MSAL ConfidentialClientApplication initialized for tenant %s", secrets.tenant_id)
    return _msal_app


def _acquire_token(secrets: AppSecrets) -> str:
    """Acquire an access token using client credentials (app-only).

    MSAL handles token caching internally — repeated calls within the token
    lifetime return the cached token without hitting the token endpoint.
    """
    app = _get_msal_app(secrets)
    result = app.acquire_token_for_client(scopes=GRAPH_SCOPE)

    if "access_token" in result:
        return result["access_token"]

    error = result.get("error", "unknown")
    error_desc = result.get("error_description", "No description")
    raise RuntimeError(f"Token acquisition failed: {error} — {error_desc}")


class GraphClient:
    """Thin wrapper around Microsoft Graph API v1.0 with token management."""

    def __init__(self, secrets: AppSecrets | None = None):
        self._secrets = secrets or get_secrets()
        self._token: str | None = None

    @property
    def _headers(self) -> dict[str, str]:
        if self._token is None:
            self._token = _acquire_token(self._secrets)
        return {
            "Authorization": f"Bearer {self._token}",
            "Content-Type": "application/json",
        }

    def _request(
        self,
        method: str,
        endpoint: str,
        json_body: dict | None = None,
        params: dict | None = None,
    ) -> requests.Response:
        """Make an authenticated request to Graph API."""
        url = f"{GRAPH_BASE_URL}{endpoint}"
        logger.info("Graph API %s %s", method, endpoint)

        response = requests.request(
            method=method,
            url=url,
            headers=self._headers,
            json=json_body,
            params=params,
            timeout=30,
        )

        if response.status_code >= 400:
            logger.error(
                "Graph API error: %s %s → %d: %s",
                method, endpoint, response.status_code, response.text[:500],
            )
        else:
            logger.info("Graph API success: %s %s → %d", method, endpoint, response.status_code)

        return response

    # --- Convenience methods ---

    def get(self, endpoint: str, params: dict | None = None) -> requests.Response:
        return self._request("GET", endpoint, params=params)

    def post(self, endpoint: str, body: dict | None = None) -> requests.Response:
        return self._request("POST", endpoint, json_body=body)

    def patch(self, endpoint: str, body: dict | None = None) -> requests.Response:
        return self._request("PATCH", endpoint, json_body=body)

    def delete(self, endpoint: str) -> requests.Response:
        return self._request("DELETE", endpoint)

    # --- Helpers used across multiple intents ---

    def get_user_id(self, upn_or_email: str) -> str | None:
        """Resolve a UPN or email address to a user's Graph object ID."""
        resp = self.get(f"/users/{upn_or_email}", params={"$select": "id,displayName,userPrincipalName"})
        if resp.status_code == 200:
            return resp.json().get("id")
        return None

    def get_user(self, upn_or_email: str) -> dict[str, Any] | None:
        """Get full user profile by UPN or email."""
        resp = self.get(f"/users/{upn_or_email}", params={"$select": "id,displayName,userPrincipalName,accountEnabled,mail"})
        if resp.status_code == 200:
            return resp.json()
        return None

    def find_group_by_name(self, group_name: str) -> dict[str, Any] | None:
        """Find a group by display name. Returns the first exact match."""
        resp = self.get(
            "/groups",
            params={
                "$filter": f"displayName eq '{group_name}'",
                "$select": "id,displayName,groupTypes,mailEnabled,securityEnabled",
                "$top": "1",
            },
        )
        if resp.status_code == 200:
            groups = resp.json().get("value", [])
            return groups[0] if groups else None
        return None

    def is_member_of_group(self, group_id: str, user_id: str) -> bool:
        """Check if a user is already a member of a group."""
        resp = self.get(
            f"/groups/{group_id}/members",
            params={"$filter": f"id eq '{user_id}'", "$select": "id"},
        )
        if resp.status_code == 200:
            return len(resp.json().get("value", [])) > 0
        return False

    def send_mail(self, from_upn: str, to_email: str, subject: str, body_html: str) -> bool:
        """Send an email via Graph sendMail from a mailbox in the customer's tenant."""
        message = {
            "message": {
                "subject": subject,
                "body": {"contentType": "HTML", "content": body_html},
                "toRecipients": [{"emailAddress": {"address": to_email}}],
            },
            "saveToSentItems": "false",
        }
        resp = self.post(f"/users/{from_upn}/sendMail", body=message)
        return resp.status_code in (200, 202)
