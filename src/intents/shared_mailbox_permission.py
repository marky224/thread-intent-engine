"""Shared Mailbox Permission intent handler.

Delegates to Azure Automation Runbooks for Exchange Online PowerShell operations:
  - Add-MailboxPermission (Full Access)
  - Add-RecipientPermission (Send As)
  - Set-Mailbox -GrantSendOnBehalfTo (Send on Behalf)

The Python Function App triggers the appropriate runbook via the Azure Management
REST API. The Automation Account authenticates to Exchange Online using its
managed identity with Exchange Administrator role.
"""

import logging
from typing import Any

from intents.base import BaseIntentHandler
from models.errors import GraphApiError, ValidationError
from services.automation import trigger_runbook

logger = logging.getLogger(__name__)

VALID_PERMISSION_TYPES = {"full access", "send as", "send on behalf"}
VALID_ACTIONS = {"grant", "revoke"}


class SharedMailboxPermissionHandler(BaseIntentHandler):

    def validate(self) -> None:
        self.require_field("Shared Mailbox Email")
        self.require_field("User Email")

        perm_type = self.optional_field("Permission Type", "Full Access").lower()
        if perm_type not in VALID_PERMISSION_TYPES:
            raise ValidationError(
                message=(
                    f"Invalid Permission Type: '{perm_type}'. "
                    f"Must be one of: Full Access, Send As, Send on Behalf."
                ),
                intent_name=self.payload.intent_name,
            )

        action = self.optional_field("Action", "Grant").lower()
        if action not in VALID_ACTIONS:
            raise ValidationError(
                message=f"Invalid Action: '{action}'. Must be Grant or Revoke.",
                intent_name=self.payload.intent_name,
            )

    def execute(self) -> dict[str, Any]:
        mailbox_email = self.require_field("Shared Mailbox Email")
        user_email = self.require_field("User Email")
        permission_type = self.optional_field("Permission Type", "Full Access")
        action = self.optional_field("Action", "Grant")

        # Validate the user exists in Graph before triggering the runbook
        user_id, upn = self.resolve_user("User Email")

        result = trigger_runbook(
            runbook_name="Set-SharedMailboxPermission",
            parameters={
                "SharedMailboxEmail": mailbox_email,
                "UserEmail": user_email,
                "PermissionType": permission_type,
                "Action": action,
            },
            wait=True,
            timeout_seconds=120,
        )

        if result["status"] == "completed":
            logger.info(
                "Shared mailbox permission %s: %s → %s (%s)",
                action, user_email, mailbox_email, permission_type,
            )
            return {
                "status": "success",
                "action": action.lower(),
                "user": user_email,
                "mailbox": mailbox_email,
                "permission_type": permission_type,
                "runbook_output": result.get("output", ""),
            }

        raise GraphApiError(
            message=f"Shared mailbox permission runbook failed: {result.get('error', 'Unknown error')}",
            intent_name=self.payload.intent_name,
            status_code=500,
            graph_error_code="RunbookFailed",
            suggested_fix=(
                "Check the Azure Automation job logs for details. Common issues: "
                "1) Automation Account managed identity missing Exchange Administrator role. "
                "2) ExchangeOnlineManagement module not installed in Automation Account. "
                "3) Shared mailbox email address is incorrect."
            ),
        )
