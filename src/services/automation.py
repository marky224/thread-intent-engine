"""Azure Automation service — triggers EXO PowerShell runbooks.

The Python Function App delegates Exchange Online operations (shared mailbox
permissions, mailbox conversion) to pre-loaded PowerShell runbooks in the
Azure Automation Account deployed alongside the Function App.
"""

import logging
import os
import time

import requests
from azure.identity import DefaultAzureCredential

logger = logging.getLogger(__name__)

AZURE_MGMT_URL = "https://management.azure.com"


def _get_mgmt_token() -> str:
    """Acquire a management-plane token for Azure Resource Manager."""
    credential = DefaultAzureCredential()
    token = credential.get_token("https://management.azure.com/.default")
    return token.token


def _get_automation_context() -> dict:
    """Resolve the Automation Account's resource path from environment."""
    subscription_id = os.environ.get("AZURE_SUBSCRIPTION_ID", "")
    resource_group = os.environ.get("AZURE_RESOURCE_GROUP", "")
    automation_account = os.environ.get("AUTOMATION_ACCOUNT_NAME", "")

    if not all([subscription_id, resource_group, automation_account]):
        raise RuntimeError(
            "Automation Account context not configured. Ensure AZURE_SUBSCRIPTION_ID, "
            "AZURE_RESOURCE_GROUP, and AUTOMATION_ACCOUNT_NAME are set."
        )

    return {
        "subscription_id": subscription_id,
        "resource_group": resource_group,
        "automation_account": automation_account,
    }


def trigger_runbook(
    runbook_name: str,
    parameters: dict[str, str],
    wait: bool = True,
    timeout_seconds: int = 120,
) -> dict:
    """Trigger an Azure Automation runbook and optionally wait for completion.

    Args:
        runbook_name: Name of the runbook (e.g., "Set-SharedMailboxPermission")
        parameters: Key-value pairs passed to the runbook as parameters
        wait: If True, poll for completion (default True)
        timeout_seconds: Max seconds to wait for completion

    Returns:
        dict with keys: status, output, error
    """
    ctx = _get_automation_context()
    token = _get_mgmt_token()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    # Start the runbook job
    job_url = (
        f"{AZURE_MGMT_URL}/subscriptions/{ctx['subscription_id']}"
        f"/resourceGroups/{ctx['resource_group']}"
        f"/providers/Microsoft.Automation/automationAccounts/{ctx['automation_account']}"
        f"/jobs/{runbook_name}-{int(time.time())}"
        f"?api-version=2023-11-01"
    )

    body = {
        "properties": {
            "runbook": {"name": runbook_name},
            "parameters": parameters,
        }
    }

    logger.info("Triggering runbook: %s with params: %s", runbook_name, list(parameters.keys()))
    resp = requests.put(job_url, headers=headers, json=body, timeout=30)

    if resp.status_code not in (200, 201):
        logger.error("Failed to trigger runbook %s: %d %s", runbook_name, resp.status_code, resp.text[:500])
        return {"status": "failed", "output": "", "error": f"HTTP {resp.status_code}: {resp.text[:300]}"}

    job_data = resp.json()
    job_id_url = job_data.get("id", "")
    logger.info("Runbook job created: %s", job_id_url)

    if not wait:
        return {"status": "submitted", "output": "", "error": ""}

    # Poll for completion
    status_url = f"{AZURE_MGMT_URL}{job_id_url}?api-version=2023-11-01"
    elapsed = 0
    poll_interval = 5

    while elapsed < timeout_seconds:
        time.sleep(poll_interval)
        elapsed += poll_interval

        status_resp = requests.get(status_url, headers=headers, timeout=15)
        if status_resp.status_code != 200:
            continue

        props = status_resp.json().get("properties", {})
        status = props.get("status", "")

        if status in ("Completed",):
            # Fetch output
            output_url = f"{AZURE_MGMT_URL}{job_id_url}/output?api-version=2023-11-01"
            out_resp = requests.get(output_url, headers=headers, timeout=15)
            output_text = out_resp.text if out_resp.status_code == 200 else ""
            logger.info("Runbook %s completed successfully", runbook_name)
            return {"status": "completed", "output": output_text, "error": ""}

        if status in ("Failed", "Stopped", "Suspended"):
            error_msg = props.get("exception", f"Runbook ended with status: {status}")
            logger.error("Runbook %s failed: %s", runbook_name, error_msg)
            return {"status": "failed", "output": "", "error": error_msg}

    logger.error("Runbook %s timed out after %d seconds", runbook_name, timeout_seconds)
    return {"status": "timeout", "output": "", "error": f"Runbook did not complete within {timeout_seconds}s"}
