"""User Offboarding / Disable Account intent handler.

Graph API: PATCH /users/{id} (accountEnabled: false) + revokeSignInSessions
Permissions: User.ReadWrite.All, Directory.ReadWrite.All

Optional operations: revoke sessions, remove licenses, convert mailbox to shared.
Mailbox conversion is delegated to an Azure Automation Runbook.
"""

import logging
from typing import Any

from intents.base import BaseIntentHandler
from models.errors import GraphApiError

logger = logging.getLogger(__name__)


class UserOffboardingHandler(BaseIntentHandler):

    def validate(self) -> None:
        self.require_field("User Email")

    def execute(self) -> dict[str, Any]:
        user_id, upn = self.resolve_user("User Email")

        revoke_sessions = self.bool_field("Revoke Sessions", default=True)
        remove_licenses = self.bool_field("Remove Licenses", default=False)
        convert_to_shared = self.bool_field("Convert to Shared Mailbox", default=False)

        results: dict[str, Any] = {
            "status": "success",
            "user": upn,
            "user_id": user_id,
            "steps_completed": [],
            "steps_failed": [],
        }

        # Step 1: Disable the account
        self._disable_account(user_id, upn)
        results["steps_completed"].append("account_disabled")

        # Step 2: Revoke sign-in sessions (optional, default True)
        if revoke_sessions:
            try:
                self._revoke_sessions(user_id, upn)
                results["steps_completed"].append("sessions_revoked")
            except Exception as e:
                logger.error("Failed to revoke sessions for %s: %s", upn, e)
                results["steps_failed"].append(f"revoke_sessions: {e}")

        # Step 3: Remove licenses (optional)
        if remove_licenses:
            try:
                removed = self._remove_all_licenses(user_id, upn)
                results["steps_completed"].append("licenses_removed")
                results["licenses_removed"] = removed
            except Exception as e:
                logger.error("Failed to remove licenses for %s: %s", upn, e)
                results["steps_failed"].append(f"remove_licenses: {e}")

        # Step 4: Convert mailbox to shared (optional, via Automation Runbook)
        if convert_to_shared:
            try:
                self._convert_to_shared_mailbox(upn)
                results["steps_completed"].append("mailbox_converted_to_shared")
            except Exception as e:
                logger.error("Failed to convert mailbox for %s: %s", upn, e)
                results["steps_failed"].append(f"convert_mailbox: {e}")

        if results["steps_failed"]:
            results["status"] = "partial_success"

        return results

    def _disable_account(self, user_id: str, upn: str) -> None:
        """Disable the user account."""
        body = {"accountEnabled": False}
        resp = self.graph.patch(f"/users/{user_id}", body=body)

        if resp.status_code == 204:
            logger.info("Disabled account for %s", upn)
            return

        self.raise_graph_error(resp, f"Disable account for {upn}")

    def _revoke_sessions(self, user_id: str, upn: str) -> None:
        """Revoke all active sign-in sessions."""
        resp = self.graph.post(f"/users/{user_id}/revokeSignInSessions")

        if resp.status_code == 200:
            logger.info("Revoked sign-in sessions for %s", upn)
            return

        self.raise_graph_error(resp, f"Revoke sessions for {upn}")

    def _remove_all_licenses(self, user_id: str, upn: str) -> list[str]:
        """Remove all assigned licenses from the user."""
        # Get currently assigned licenses
        resp = self.graph.get(f"/users/{user_id}", params={"$select": "assignedLicenses"})

        if resp.status_code != 200:
            self.raise_graph_error(resp, f"Get licenses for {upn}")

        assigned = resp.json().get("assignedLicenses", [])
        if not assigned:
            logger.info("No licenses to remove for %s", upn)
            return []

        sku_ids = [lic["skuId"] for lic in assigned]

        body = {
            "addLicenses": [],
            "removeLicenses": sku_ids,
        }
        resp = self.graph.post(f"/users/{user_id}/assignLicense", body=body)

        if resp.status_code == 200:
            logger.info("Removed %d licenses from %s", len(sku_ids), upn)
            return sku_ids

        self.raise_graph_error(resp, f"Remove licenses from {upn}")

    def _convert_to_shared_mailbox(self, upn: str) -> None:
        """Convert user mailbox to shared mailbox via Azure Automation Runbook."""
        from services.automation import trigger_runbook

        result = trigger_runbook(
            runbook_name="Convert-ToSharedMailbox",
            parameters={"UserPrincipalName": upn},
            wait=True,
            timeout_seconds=120,
        )

        if result["status"] != "completed":
            raise GraphApiError(
                message=f"Mailbox conversion runbook failed: {result.get('error', 'Unknown error')}",
                intent_name=self.payload.intent_name,
                status_code=500,
                graph_error_code="RunbookFailed",
                suggested_fix="Check the Azure Automation job logs for details. Ensure the Automation Account's managed identity has Exchange Administrator role.",
            )

        logger.info("Mailbox converted to shared for %s", upn)
