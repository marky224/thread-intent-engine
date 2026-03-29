"""Idempotency service — prevents duplicate operations via Azure Table Storage.

Composite key: ticket_id + intent_name
States: "processing" → "completed" (on success) or deleted (on failure, allowing retry)
TTL: configurable via IDEMPOTENCY_TTL_SECONDS (default 3600 = 1 hour)
"""

import logging
import os
from datetime import datetime, timedelta, timezone

from azure.data.tables import TableClient, TableServiceClient
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError

from models.errors import IdempotencySkip

logger = logging.getLogger(__name__)

TABLE_NAME = "idempotency"
PARTITION_KEY = "intents"  # Single partition for simplicity at MVP scale


def _get_table_client() -> TableClient:
    """Get a TableClient for the idempotency table."""
    is_local = os.environ.get("LOCAL_DEV", "").lower() == "true"

    if is_local:
        # Local development uses Azurite or the connection string from local.settings.json
        conn_str = os.environ.get(
            "AzureWebJobsStorage", "UseDevelopmentStorage=true"
        )
        service = TableServiceClient.from_connection_string(conn_str)
    else:
        storage_name = os.environ["STORAGE_ACCOUNT_NAME"]
        # Use DefaultAzureCredential for managed identity access
        from azure.identity import DefaultAzureCredential
        credential = DefaultAzureCredential()
        service = TableServiceClient(
            endpoint=f"https://{storage_name}.table.core.windows.net",
            credential=credential,
        )

    return service.get_table_client(TABLE_NAME)


def _get_ttl_seconds() -> int:
    return int(os.environ.get("IDEMPOTENCY_TTL_SECONDS", "3600"))


def _make_row_key(ticket_id: int, intent_name: str) -> str:
    """Build the composite deduplication key."""
    # Sanitize intent_name: Table Storage row keys can't contain / \ # ?
    safe_intent = intent_name.replace("/", "_").replace("\\", "_").replace("#", "_").replace("?", "_")
    return f"{ticket_id}_{safe_intent}"


def check_and_claim(ticket_id: int, intent_name: str) -> None:
    """Check for a duplicate and claim a processing slot.

    Raises IdempotencySkip if a duplicate is found within the TTL window.
    Otherwise, inserts a "processing" record.
    """
    table = _get_table_client()
    row_key = _make_row_key(ticket_id, intent_name)
    ttl = _get_ttl_seconds()
    now = datetime.now(timezone.utc)

    # Check for existing record
    try:
        existing = table.get_entity(partition_key=PARTITION_KEY, row_key=row_key)
        created_at = existing.get("created_at")
        if isinstance(created_at, str):
            created_at = datetime.fromisoformat(created_at)

        if created_at and (now - created_at) < timedelta(seconds=ttl):
            status = existing.get("status", "unknown")
            logger.warning(
                "Idempotency: duplicate detected — key=%s, status=%s, age=%s",
                row_key, status, now - created_at,
            )
            raise IdempotencySkip(row_key)
        else:
            # Record exists but is outside TTL — treat as expired, overwrite
            logger.info("Idempotency: expired record found, overwriting — key=%s", row_key)
            table.delete_entity(partition_key=PARTITION_KEY, row_key=row_key)
    except ResourceNotFoundError:
        pass  # No existing record — proceed to claim

    # Claim the slot with "processing" status
    entity = {
        "PartitionKey": PARTITION_KEY,
        "RowKey": row_key,
        "status": "processing",
        "intent_name": intent_name,
        "ticket_id": ticket_id,
        "created_at": now.isoformat(),
    }
    try:
        table.create_entity(entity)
        logger.info("Idempotency: claimed processing slot — key=%s", row_key)
    except ResourceExistsError:
        # Race condition: another instance claimed it between our check and insert
        logger.warning("Idempotency: race condition — another instance claimed key=%s", row_key)
        raise IdempotencySkip(row_key)


def mark_completed(ticket_id: int, intent_name: str) -> None:
    """Mark a processing record as completed (success)."""
    table = _get_table_client()
    row_key = _make_row_key(ticket_id, intent_name)

    try:
        entity = table.get_entity(partition_key=PARTITION_KEY, row_key=row_key)
        entity["status"] = "completed"
        entity["completed_at"] = datetime.now(timezone.utc).isoformat()
        table.update_entity(entity, mode="merge")
        logger.info("Idempotency: marked completed — key=%s", row_key)
    except ResourceNotFoundError:
        logger.warning("Idempotency: record not found for completion — key=%s", row_key)


def clear_on_failure(ticket_id: int, intent_name: str) -> None:
    """Delete the processing record on failure (allows retry)."""
    table = _get_table_client()
    row_key = _make_row_key(ticket_id, intent_name)

    try:
        table.delete_entity(partition_key=PARTITION_KEY, row_key=row_key)
        logger.info("Idempotency: cleared on failure — key=%s (retry allowed)", row_key)
    except ResourceNotFoundError:
        logger.warning("Idempotency: record not found for clearing — key=%s", row_key)
