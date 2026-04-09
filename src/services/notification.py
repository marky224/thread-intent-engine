"""Failure notification service — sends structured error emails via Graph sendMail.

Emails are sent from a mailbox within the customer's own tenant, keeping the
entire notification pipeline within the customer's Microsoft environment.
"""

import logging
from datetime import datetime, timezone

from models import WebhookPayload
from models.errors import IntentError, get_suggested_fix
from services.graph_client import GraphClient
from services.keyvault_client import AppSecrets

logger = logging.getLogger(__name__)


def _build_failure_html(
    payload: WebhookPayload,
    error: IntentError | Exception,
    timestamp: str,
) -> str:
    """Build the HTML body for the failure notification email."""

    # Extract error details
    if isinstance(error, IntentError):
        status_code = error.status_code
        graph_error_code = error.graph_error_code
        error_message = str(error)
        suggested_fix = error.suggested_fix or get_suggested_fix(graph_error_code)
    else:
        status_code = 500
        graph_error_code = "UnknownError"
        error_message = str(error)
        suggested_fix = "An unexpected error occurred. Review the Application Insights logs for details."

    # Format intent fields as a readable table
    fields_html = ""
    for key, value in payload.intent_fields.items():
        fields_html += f"<tr><td style='padding:4px 12px 4px 0;font-weight:600;'>{key}</td><td style='padding:4px 0;'>{value}</td></tr>"

    return f"""
    <div style="font-family: Segoe UI, Arial, sans-serif; max-width: 640px; margin: 0 auto;">
        <div style="background: #d13438; color: white; padding: 16px 20px; border-radius: 6px 6px 0 0;">
            <h2 style="margin: 0; font-size: 18px;">[FAILED] Thread Automation: {payload.intent_name}</h2>
        </div>
        <div style="border: 1px solid #e0e0e0; border-top: none; padding: 20px; border-radius: 0 0 6px 6px;">
            <table style="width: 100%; border-collapse: collapse; margin-bottom: 16px;">
                <tr><td style="padding:4px 12px 4px 0;font-weight:600;color:#666;">Timestamp</td><td>{timestamp}</td></tr>
                <tr><td style="padding:4px 12px 4px 0;font-weight:600;color:#666;">Ticket ID</td><td>#{payload.meta_data.ticket_id}</td></tr>
                <tr><td style="padding:4px 12px 4px 0;font-weight:600;color:#666;">Requested By</td><td>{payload.meta_data.contact_name} ({payload.meta_data.contact_email})</td></tr>
                <tr><td style="padding:4px 12px 4px 0;font-weight:600;color:#666;">Company</td><td>{payload.meta_data.company_name}</td></tr>
            </table>

            <h3 style="margin: 16px 0 8px; font-size: 14px; color: #333;">Intent Fields</h3>
            <table style="width: 100%; border-collapse: collapse; margin-bottom: 16px; background: #f9f9f9; padding: 8px; border-radius: 4px;">
                {fields_html}
            </table>

            <h3 style="margin: 16px 0 8px; font-size: 14px; color: #d13438;">Error Details</h3>
            <table style="width: 100%; border-collapse: collapse; margin-bottom: 16px;">
                <tr><td style="padding:4px 12px 4px 0;font-weight:600;color:#666;">HTTP Status</td><td>{status_code}</td></tr>
                <tr><td style="padding:4px 12px 4px 0;font-weight:600;color:#666;">Error Code</td><td>{graph_error_code}</td></tr>
                <tr><td style="padding:4px 12px 4px 0;font-weight:600;color:#666;">Message</td><td>{error_message}</td></tr>
            </table>

            <div style="background: #fff4ce; border-left: 4px solid #ffb900; padding: 12px; border-radius: 0 4px 4px 0; margin-top: 12px;">
                <strong style="color: #8a6d00;">Suggested Fix:</strong> {suggested_fix}
            </div>
        </div>
    </div>
    """


def send_failure_notification(
    payload: WebhookPayload,
    error: IntentError | Exception,
    secrets: AppSecrets,
    graph_client: GraphClient | None = None,
) -> bool:
    """Send a failure notification email via Graph sendMail.

    Returns True if the email was sent successfully, False otherwise.
    If the notification mailbox or email is not configured, logs a warning and skips.
    """
    if not secrets.notification_email:
        logger.warning("No notification email configured — skipping failure notification")
        return False

    if not secrets.notification_mailbox:
        logger.warning("No notification mailbox configured — skipping failure notification (email would have no sender)")
        return False

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    subject = f"[FAILED] Thread Automation: {payload.intent_name} — Ticket #{payload.meta_data.ticket_id}"
    body_html = _build_failure_html(payload, error, timestamp)

    try:
        client = graph_client or GraphClient()
        success = client.send_mail(
            from_upn=secrets.notification_mailbox,
            to_email=secrets.notification_email,
            subject=subject,
            body_html=body_html,
        )
        if success:
            logger.info("Failure notification sent to %s", secrets.notification_email)
        else:
            logger.error("Failed to send failure notification email")
        return success
    except Exception as e:
        # Don't let notification failures crash the main flow
        logger.error("Exception sending failure notification: %s", e)
        return False
