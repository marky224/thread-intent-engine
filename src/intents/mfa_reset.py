"""MFA Reset intent handler.

Graph API: DELETE /users/{id}/authentication/methods/{methodId}
Permission: UserAuthenticationMethod.ReadWrite.All

Lists existing authentication methods first, then deletes the specified
method types (All, Phone, Authenticator).
"""

import logging
from typing import Any

from intents.base import BaseIntentHandler
from models.errors import GraphApiError

logger = logging.getLogger(__name__)

# Graph API method type → human-readable name
METHOD_TYPES = {
    "#microsoft.graph.phoneAuthenticationMethod": "Phone",
    "#microsoft.graph.microsoftAuthenticatorAuthenticationMethod": "Authenticator",
    "#microsoft.graph.softwareOathAuthenticationMethod": "Software OATH Token",
    "#microsoft.graph.fido2AuthenticationMethod": "FIDO2 Security Key",
    "#microsoft.graph.windowsHelloForBusinessAuthenticationMethod": "Windows Hello",
    "#microsoft.graph.emailAuthenticationMethod": "Email",
}

# Method type → API path segment for listing
METHOD_ENDPOINTS = {
    "phone": "phoneMethods",
    "authenticator": "microsoftAuthenticatorMethods",
    "software_oath": "softwareOathMethods",
    "email": "emailMethods",
}


class MfaResetHandler(BaseIntentHandler):

    def validate(self) -> None:
        self.require_field("User Email")

    def execute(self) -> dict[str, Any]:
        user_id, upn = self.resolve_user("User Email")
        method_filter = self.optional_field("MFA Method to Reset", "All").lower()

        # List all authentication methods for the user
        methods = self._list_methods(user_id)

        if not methods:
            logger.info("No MFA methods found for %s", upn)
            return {
                "status": "success",
                "action": "no_methods_found",
                "user": upn,
                "message": f"No removable MFA methods found for {upn}",
            }

        # Filter methods based on the requested type
        to_delete = self._filter_methods(methods, method_filter)

        if not to_delete:
            logger.info("No matching MFA methods to delete for %s (filter: %s)", upn, method_filter)
            return {
                "status": "success",
                "action": "no_matching_methods",
                "user": upn,
                "filter": method_filter,
            }

        # Delete each matching method
        deleted = []
        errors = []
        for method in to_delete:
            success = self._delete_method(user_id, method)
            if success:
                deleted.append(method["type_name"])
            else:
                errors.append(method["type_name"])

        if errors and not deleted:
            raise GraphApiError(
                message=f"Failed to delete any MFA methods for {upn}: {', '.join(errors)}",
                intent_name=self.payload.intent_name,
                status_code=500,
                graph_error_code="MfaResetFailed",
                suggested_fix="Some MFA methods cannot be removed via API. Check the user's auth methods in Entra ID.",
            )

        logger.info("MFA reset for %s: deleted %s, errors %s", upn, deleted, errors)
        return {
            "status": "success",
            "action": "methods_deleted",
            "user": upn,
            "deleted": deleted,
            "errors": errors,
        }

    def _list_methods(self, user_id: str) -> list[dict]:
        """List all authentication methods for a user."""
        resp = self.graph.get(f"/users/{user_id}/authentication/methods")

        if resp.status_code != 200:
            self.raise_graph_error(resp, "List authentication methods")

        methods = []
        for m in resp.json().get("value", []):
            odata_type = m.get("@odata.type", "")
            type_name = METHOD_TYPES.get(odata_type, odata_type)

            # Skip password method — can't be deleted via this API
            if "passwordAuthenticationMethod" in odata_type:
                continue

            methods.append({
                "id": m["id"],
                "odata_type": odata_type,
                "type_name": type_name,
            })

        return methods

    def _filter_methods(self, methods: list[dict], method_filter: str) -> list[dict]:
        """Filter methods based on the user's requested MFA method type."""
        if method_filter == "all":
            return methods

        filter_map = {
            "phone": "phoneAuthenticationMethod",
            "authenticator": "microsoftAuthenticatorAuthenticationMethod",
            "email": "emailAuthenticationMethod",
            "fido2": "fido2AuthenticationMethod",
            "software oath": "softwareOathAuthenticationMethod",
        }

        target = filter_map.get(method_filter, method_filter)
        return [m for m in methods if target.lower() in m["odata_type"].lower()]

    def _delete_method(self, user_id: str, method: dict) -> bool:
        """Delete a single authentication method."""
        odata_type = method["odata_type"]

        # Map @odata.type to the correct API endpoint
        type_to_endpoint = {
            "phoneAuthenticationMethod": "phoneMethods",
            "microsoftAuthenticatorAuthenticationMethod": "microsoftAuthenticatorMethods",
            "softwareOathAuthenticationMethod": "softwareOathMethods",
            "emailAuthenticationMethod": "emailMethods",
            "fido2AuthenticationMethod": "fido2Methods",
        }

        endpoint = None
        for key, path in type_to_endpoint.items():
            if key in odata_type:
                endpoint = path
                break

        if not endpoint:
            logger.warning("Unknown method type %s — skipping deletion", odata_type)
            return False

        resp = self.graph.delete(f"/users/{user_id}/authentication/{endpoint}/{method['id']}")
        if resp.status_code == 204:
            logger.info("Deleted MFA method %s (%s)", method["type_name"], method["id"])
            return True

        logger.error("Failed to delete MFA method %s: %d", method["type_name"], resp.status_code)
        return False
