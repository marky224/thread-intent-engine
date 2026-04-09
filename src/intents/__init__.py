"""Intent handlers — each maps an intent_name to Graph API operations.

The INTENT_REGISTRY maps intent names (from Thread's webhook payload) to
handler classes. The dispatcher in function_app.py uses this registry to
route incoming webhooks to the correct handler.
"""

from intents.password_reset import PasswordResetHandler
from intents.add_user_to_group import AddUserToGroupHandler
from intents.remove_user_from_group import RemoveUserFromGroupHandler
from intents.license_assignment import LicenseAssignmentHandler
from intents.mfa_reset import MfaResetHandler
from intents.new_user_creation import NewUserCreationHandler
from intents.user_offboarding import UserOffboardingHandler
from intents.shared_mailbox_permission import SharedMailboxPermissionHandler

# Maps intent_name (as sent by Thread) → handler class
INTENT_REGISTRY: dict[str, type] = {
    "Password Reset": PasswordResetHandler,
    "Add User to Group": AddUserToGroupHandler,
    "Remove User from Group": RemoveUserFromGroupHandler,
    "License Assignment": LicenseAssignmentHandler,
    "MFA Reset": MfaResetHandler,
    "New User Creation": NewUserCreationHandler,
    "User Offboarding": UserOffboardingHandler,
    "Disable Account": UserOffboardingHandler,  # Alias
    "User Offboarding / Disable Account": UserOffboardingHandler,  # Alias
    "Shared Mailbox Permission": SharedMailboxPermissionHandler,
}
