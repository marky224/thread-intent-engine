"""Pydantic models for Thread webhook payload validation."""

from pydantic import BaseModel, Field, field_validator
from typing import Any


class MetaData(BaseModel):
    """Contextual data from Thread — used for audit logging and failure notifications."""
    ticket_id: int = Field(..., description="Thread PSA ticket ID")
    contact_name: str = Field(default="", description="Name of the requesting user")
    contact_email: str = Field(default="", description="Email of the requesting user")
    company_name: str = Field(default="", description="Customer company name")


class WebhookPayload(BaseModel):
    """Top-level webhook payload from Thread's Magic Agent Intent system."""
    intent_name: str = Field(..., description="Name of the intent — maps to a Graph API operation")
    intent_fields: dict[str, Any] = Field(
        default_factory=dict,
        description="Dynamic key-value pairs collected from the end user during triage",
    )
    meta_data: MetaData = Field(..., description="Contextual data for audit and notifications")

    @field_validator("intent_name")
    @classmethod
    def intent_name_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("intent_name cannot be empty")
        return v.strip()
