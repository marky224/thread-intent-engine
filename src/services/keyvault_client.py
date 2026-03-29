"""Key Vault client — reads app registration secrets and configuration.

In Azure: uses the Function App's system-assigned managed identity.
Locally: falls back to LOCAL_* environment variables for development.
"""

import logging
import os
from dataclasses import dataclass
from functools import lru_cache

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class AppSecrets:
    """Immutable container for secrets read from Key Vault (or local env)."""
    client_id: str
    client_secret: str
    tenant_id: str
    notification_email: str
    notification_mailbox: str


def _is_local_dev() -> bool:
    return os.environ.get("LOCAL_DEV", "").lower() == "true"


@lru_cache(maxsize=1)
def get_secrets() -> AppSecrets:
    """Load secrets once and cache for the lifetime of the Function App instance.

    Uses @lru_cache so Key Vault is hit once per cold start, not per request.
    """
    if _is_local_dev():
        logger.info("Running in LOCAL_DEV mode — reading secrets from environment variables")
        return AppSecrets(
            client_id=os.environ["LOCAL_APP_CLIENT_ID"],
            client_secret=os.environ["LOCAL_APP_CLIENT_SECRET"],
            tenant_id=os.environ["LOCAL_TENANT_ID"],
            notification_email=os.environ.get("LOCAL_NOTIFICATION_EMAIL", ""),
            notification_mailbox=os.environ.get("LOCAL_NOTIFICATION_MAILBOX", ""),
        )

    # --- Azure: read from Key Vault via managed identity ---
    from azure.identity import DefaultAzureCredential
    from azure.keyvault.secrets import SecretClient

    vault_name = os.environ["KEY_VAULT_NAME"]
    vault_url = f"https://{vault_name}.vault.azure.net"
    logger.info("Reading secrets from Key Vault: %s", vault_url)

    credential = DefaultAzureCredential()
    client = SecretClient(vault_url=vault_url, credential=credential)

    def _get(name: str, default: str = "") -> str:
        try:
            return client.get_secret(name).value or default
        except Exception:
            logger.warning("Secret '%s' not found in Key Vault, using default", name)
            return default

    secrets = AppSecrets(
        client_id=_get("AppClientId"),
        client_secret=_get("AppClientSecret"),
        tenant_id=_get("TenantId"),
        notification_email=_get("NotificationEmail"),
        notification_mailbox=_get("NotificationMailbox"),
    )

    if not secrets.client_id or not secrets.client_secret or not secrets.tenant_id:
        raise ValueError(
            "Required Key Vault secrets (AppClientId, AppClientSecret, TenantId) are missing. "
            "Verify the deployment completed successfully."
        )

    logger.info("Secrets loaded successfully for tenant %s", secrets.tenant_id)
    return secrets
