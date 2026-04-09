"""Custom exception types for the Thread Intent Automation Engine."""


class IntentError(Exception):
    """Base exception for intent execution failures."""

    def __init__(
        self,
        message: str,
        intent_name: str = "",
        status_code: int = 500,
        graph_error_code: str = "",
        suggested_fix: str = "",
    ):
        super().__init__(message)
        self.intent_name = intent_name
        self.status_code = status_code
        self.graph_error_code = graph_error_code
        self.suggested_fix = suggested_fix


class GraphApiError(IntentError):
    """Raised when a Microsoft Graph API call fails."""
    pass


class ValidationError(IntentError):
    """Raised when intent field validation fails before calling Graph."""

    def __init__(self, message: str, intent_name: str = ""):
        super().__init__(
            message=message,
            intent_name=intent_name,
            status_code=400,
            suggested_fix="Verify the input fields are correct and retry.",
        )


class IdempotencySkip(Exception):
    """Raised when an idempotency check detects a duplicate request."""

    def __init__(self, dedup_key: str):
        self.dedup_key = dedup_key
        super().__init__(f"Duplicate request detected: {dedup_key}")


# ---------- Graph error code → suggested fix mapping ----------

GRAPH_ERROR_FIXES: dict[str, str] = {
    "Request_ResourceNotFound": "The user or resource was not found. Verify the UPN/email is correct.",
    "Authorization_RequestDenied": "Insufficient permissions. Verify admin consent was granted for this operation.",
    "InvalidAuthenticationToken": "Authentication token is invalid or expired. Check the app registration and Key Vault secrets.",
    "UserNotFound": "The specified user does not exist in this tenant. Verify the UPN/email address.",
    "ResourceNotFound": "The specified resource (group, license, etc.) was not found. Verify the name or ID.",
    "Request_BadRequest": "The request was malformed. Check the intent fields for formatting errors.",
    "Directory_QuotaExceeded": "The directory quota has been exceeded. Contact your Microsoft 365 administrator.",
    "ObjectConflict": "A conflict occurred — the object may already exist.",
    "License_QuotaExceeded": "No available licenses of the requested SKU. Purchase additional licenses.",
}


def get_suggested_fix(graph_error_code: str) -> str:
    """Look up a human-readable suggested fix for a Graph API error code."""
    return GRAPH_ERROR_FIXES.get(
        graph_error_code,
        "Review the error details and retry. If the issue persists, check the Microsoft 365 admin portal.",
    )
