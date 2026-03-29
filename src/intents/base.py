"""Base intent handler — shared infrastructure for all intent implementations.

Every intent handler inherits from BaseIntentHandler and implements:
  - validate(): check that required intent_fields are present and valid
  - execute(): perform the Graph API operation(s)

The base class provides the Graph client, error extraction, and a consistent
interface for the dispatcher.
"""

import logging
from abc import ABC, abstractmethod
from typing import Any

from models import WebhookPayload
from models.errors import GraphApiError, ValidationError, get_suggested_fix
from services.graph_client import GraphClient

logger = logging.getLogger(__name__)


class BaseIntentHandler(ABC):
    """Base class for all intent handlers."""

    def __init__(self, payload: WebhookPayload, graph_client: GraphClient):
        self.payload = payload
        self.graph = graph_client
        self.fields = payload.intent_fields
        self.meta = payload.meta_data

    # --- Subclass contract ---

    @abstractmethod
    def validate(self) -> None:
        """Validate intent_fields before execution. Raise ValidationError on failure."""
        ...

    @abstractmethod
    def execute(self) -> dict[str, Any]:
        """Execute the Graph API operation(s). Return a result dict for logging."""
        ...

    # --- Shared helpers ---

    def require_field(self, field_name: str) -> str:
        """Get a required field value or raise ValidationError."""
        value = self.fields.get(field_name, "")
        if isinstance(value, str):
            value = value.strip()
        if not value:
            raise ValidationError(
                message=f"Required field '{field_name}' is missing or empty.",
                intent_name=self.payload.intent_name,
            )
        return value

    def optional_field(self, field_name: str, default: str = "") -> str:
        """Get an optional field value with a default."""
        value = self.fields.get(field_name, default)
        if isinstance(value, str):
            return value.strip()
        return str(value) if value else default

    def bool_field(self, field_name: str, default: bool = False) -> bool:
        """Parse a Yes/No or True/False field into a boolean."""
        value = self.fields.get(field_name, "")
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            return value.strip().lower() in ("yes", "true", "1", "y")
        return default

    def resolve_user(self, upn_field: str = "User Email") -> tuple[str, str]:
        """Resolve a user UPN to a Graph object ID.

        Returns (user_id, upn) tuple or raises GraphApiError.
        """
        upn = self.require_field(upn_field)
        user_id = self.graph.get_user_id(upn)
        if not user_id:
            raise GraphApiError(
                message=f"User not found: {upn}",
                intent_name=self.payload.intent_name,
                status_code=404,
                graph_error_code="UserNotFound",
                suggested_fix=f"Verify the UPN/email '{upn}' exists in this tenant.",
            )
        return user_id, upn

    def resolve_group(self, name_field: str = "Group Name") -> tuple[str, str]:
        """Resolve a group display name to a Graph object ID.

        Returns (group_id, group_name) tuple or raises GraphApiError.
        """
        group_name = self.require_field(name_field)
        group = self.graph.find_group_by_name(group_name)
        if not group:
            raise GraphApiError(
                message=f"Group not found: {group_name}",
                intent_name=self.payload.intent_name,
                status_code=404,
                graph_error_code="ResourceNotFound",
                suggested_fix=f"Verify the group '{group_name}' exists. Check exact spelling and case.",
            )
        return group["id"], group["displayName"]

    def raise_graph_error(self, response, operation: str = "") -> None:
        """Parse a Graph API error response and raise a GraphApiError."""
        try:
            error_body = response.json().get("error", {})
            graph_code = error_body.get("code", "UnknownError")
            graph_message = error_body.get("message", response.text[:300])
        except Exception:
            graph_code = "UnknownError"
            graph_message = response.text[:300] if response.text else "No response body"

        prefix = f"{operation}: " if operation else ""
        raise GraphApiError(
            message=f"{prefix}{graph_message}",
            intent_name=self.payload.intent_name,
            status_code=response.status_code,
            graph_error_code=graph_code,
            suggested_fix=get_suggested_fix(graph_code),
        )
