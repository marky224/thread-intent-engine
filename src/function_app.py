"""Thread Intent Automation Engine — Azure Function App entry point.

HTTP-triggered serverless function that receives webhook payloads from Thread's
Magic Agent Intent system and dispatches them to the appropriate intent handler.

Flow:
  1. Receive HTTP POST at /api/intent
  2. Log raw payload and headers for troubleshooting
  3. Validate payload structure (Pydantic)
  4. Check idempotency (Azure Table Storage)
  5. Route to intent handler by intent_name
  6. Execute Graph API operation(s)
  7. On success: mark idempotency record completed, log to App Insights
  8. On failure: clear idempotency record, send notification email, log error
"""

import json
import logging
import time

import azure.functions as func

from models import WebhookPayload
from models.errors import GraphApiError, IdempotencySkip, IntentError, ValidationError
from services.graph_client import GraphClient
from services.idempotency import check_and_claim, clear_on_failure, mark_completed
from services.keyvault_client import get_secrets
from services.notification import send_failure_notification
from intents import INTENT_REGISTRY

# ---------- Configure logging ----------

logger = logging.getLogger("thread-intent-engine")
logger.setLevel(logging.INFO)

# ---------- Structured logging helpers ----------

# Headers worth capturing from Thread's inbound webhooks.
_HEADERS_TO_LOG = (
    "Content-Type",
    "User-Agent",
    "X-Request-Id",
    "X-Forwarded-For",
    "X-Thread-Request-Id",
)


def _log_webhook_received(req: func.HttpRequest, body: dict) -> None:
    """Log raw payload + selected headers as structured custom dimensions.

    This runs *before* Pydantic validation so we capture what Thread actually
    sent, even if the payload is malformed.  Every field lands as its own
    queryable column in Application Insights → Logs → traces.
    """
    headers = {h: req.headers.get(h) for h in _HEADERS_TO_LOG if req.headers.get(h)}

    meta = body.get("meta_data", {})

    logger.info(
        "Webhook received",
        extra={
            "custom_dimensions": {
                "event": "webhook_received",
                "intent_name": body.get("intent_name", "unknown"),
                "ticket_id": str(meta.get("ticket_id", "")),
                "contact_name": meta.get("contact_name", ""),
                "contact_email": meta.get("contact_email", ""),
                "company_name": meta.get("company_name", ""),
                "raw_payload": json.dumps(body),
                "raw_headers": json.dumps(headers),
            }
        },
    )


def _log_intent_result(
    intent_name: str,
    ticket_id: int | str,
    company_name: str,
    status: str,
    duration_ms: int,
    *,
    result: dict | None = None,
    error: str | None = None,
    error_type: str | None = None,
    http_status: int | None = None,
) -> None:
    """Emit a single structured log line for intent completion (success or failure).

    All fields are queryable independently in App Insights KQL.
    """
    dimensions: dict[str, str] = {
        "event": "intent_result",
        "intent_name": intent_name,
        "ticket_id": str(ticket_id),
        "company_name": company_name,
        "status": status,
        "duration_ms": str(duration_ms),
    }

    if result:
        dimensions["result_summary"] = json.dumps(result)
    if error:
        dimensions["error_message"] = str(error)[:1000]  # cap to avoid oversized fields
    if error_type:
        dimensions["error_type"] = error_type
    if http_status is not None:
        dimensions["http_status"] = str(http_status)

    log_level = logging.INFO if status == "success" else logging.ERROR
    logger.log(
        log_level,
        "Intent %s: %s (ticket=%s, duration=%dms)",
        status,
        intent_name,
        ticket_id,
        duration_ms,
        extra={"custom_dimensions": dimensions},
    )


# ---------- Azure Function App ----------

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


@app.route(route="intent", methods=["POST"])
def intent_webhook(req: func.HttpRequest) -> func.HttpResponse:
    """Main webhook endpoint — receives Thread intent payloads and dispatches to handlers."""

    start_time = time.time()
    payload = None

    try:
        # --- Step 1: Parse raw body (before validation) ---
        try:
            body = req.get_json()
        except ValueError:
            raw = req.get_body().decode("utf-8", errors="replace")
            logger.error(
                "Invalid JSON in request body",
                extra={
                    "custom_dimensions": {
                        "event": "webhook_parse_error",
                        "raw_body": raw[:2000],
                    }
                },
            )
            return func.HttpResponse(
                json.dumps({"error": "Invalid JSON"}),
                status_code=400,
                mimetype="application/json",
            )

        # --- Step 2: Log raw payload + headers (always, before validation) ---
        _log_webhook_received(req, body)

        # --- Step 3: Validate payload structure ---
        try:
            payload = WebhookPayload(**body)
        except Exception as e:
            logger.error(
                "Payload validation failed",
                extra={
                    "custom_dimensions": {
                        "event": "webhook_validation_error",
                        "intent_name": body.get("intent_name", "unknown"),
                        "validation_error": str(e),
                        "raw_payload": json.dumps(body),
                    }
                },
            )
            return func.HttpResponse(
                json.dumps({"error": f"Payload validation failed: {e}"}),
                status_code=400,
                mimetype="application/json",
            )

        intent_name = payload.intent_name
        ticket_id = payload.meta_data.ticket_id
        company_name = payload.meta_data.company_name

        # --- Step 4: Look up intent handler ---
        handler_class = INTENT_REGISTRY.get(intent_name)
        if not handler_class:
            duration_ms = int((time.time() - start_time) * 1000)
            _log_intent_result(
                intent_name, ticket_id, company_name,
                status="failed",
                duration_ms=duration_ms,
                error=f"Unknown intent: {intent_name}",
                error_type="UnknownIntent",
            )
            return func.HttpResponse(
                json.dumps({
                    "error": f"Unknown intent: {intent_name}",
                    "supported_intents": list(INTENT_REGISTRY.keys()),
                }),
                status_code=400,
                mimetype="application/json",
            )

        # --- Step 5: Idempotency check ---
        try:
            check_and_claim(ticket_id, intent_name)
        except IdempotencySkip as e:
            duration_ms = int((time.time() - start_time) * 1000)
            logger.info(
                "Idempotency: skipping duplicate",
                extra={
                    "custom_dimensions": {
                        "event": "idempotency_skip",
                        "intent_name": intent_name,
                        "ticket_id": str(ticket_id),
                        "company_name": company_name,
                        "dedup_key": e.dedup_key,
                        "duration_ms": str(duration_ms),
                    }
                },
            )
            return func.HttpResponse(
                json.dumps({"status": "skipped", "reason": "duplicate_request", "key": e.dedup_key}),
                status_code=200,
                mimetype="application/json",
            )

        # --- Step 6: Initialize services and execute ---
        secrets = get_secrets()
        graph_client = GraphClient(secrets)

        handler = handler_class(payload=payload, graph_client=graph_client)
        handler.validate()
        result = handler.execute()

        # --- Step 7: Success ---
        mark_completed(ticket_id, intent_name)
        duration_ms = int((time.time() - start_time) * 1000)

        _log_intent_result(
            intent_name, ticket_id, company_name,
            status="success",
            duration_ms=duration_ms,
            result=result,
        )

        return func.HttpResponse(
            json.dumps({"status": "success", "intent": intent_name, "result": result}),
            status_code=200,
            mimetype="application/json",
        )

    except (ValidationError, GraphApiError, IntentError) as e:
        # --- Known error: clear idempotency, send notification ---
        duration_ms = int((time.time() - start_time) * 1000)

        _log_intent_result(
            getattr(e, "intent_name", payload.intent_name if payload else "unknown"),
            payload.meta_data.ticket_id if payload else "unknown",
            payload.meta_data.company_name if payload else "unknown",
            status="failed",
            duration_ms=duration_ms,
            error=str(e),
            error_type=type(e).__name__,
            http_status=getattr(e, "status_code", 500),
        )

        if payload:
            clear_on_failure(payload.meta_data.ticket_id, payload.intent_name)
            try:
                secrets = get_secrets()
                send_failure_notification(payload, e, secrets)
            except Exception as notify_err:
                logger.error(
                    "Failed to send failure notification",
                    extra={
                        "custom_dimensions": {
                            "event": "notification_failure",
                            "intent_name": payload.intent_name,
                            "ticket_id": str(payload.meta_data.ticket_id),
                            "notification_error": str(notify_err),
                        }
                    },
                )

        return func.HttpResponse(
            json.dumps({"status": "failed", "error": str(e)}),
            status_code=200,  # Return 200 to Thread (fire-and-forget, no retry needed)
            mimetype="application/json",
        )

    except Exception as e:
        # --- Unexpected error ---
        duration_ms = int((time.time() - start_time) * 1000)

        _log_intent_result(
            payload.intent_name if payload else "unknown",
            payload.meta_data.ticket_id if payload else "unknown",
            payload.meta_data.company_name if payload else "unknown",
            status="failed",
            duration_ms=duration_ms,
            error=str(e),
            error_type="UnhandledException",
        )
        logger.exception(
            "Unhandled exception",
            extra={
                "custom_dimensions": {
                    "event": "unhandled_exception",
                    "intent_name": payload.intent_name if payload else "unknown",
                    "ticket_id": str(payload.meta_data.ticket_id) if payload else "unknown",
                    "exception_type": type(e).__name__,
                }
            },
        )

        if payload:
            clear_on_failure(payload.meta_data.ticket_id, payload.intent_name)
            try:
                secrets = get_secrets()
                send_failure_notification(payload, e, secrets)
            except Exception as notify_err:
                logger.error(
                    "Failed to send failure notification",
                    extra={
                        "custom_dimensions": {
                            "event": "notification_failure",
                            "intent_name": payload.intent_name,
                            "ticket_id": str(payload.meta_data.ticket_id),
                            "notification_error": str(notify_err),
                        }
                    },
                )

        return func.HttpResponse(
            json.dumps({"status": "failed", "error": "Internal server error"}),
            status_code=200,  # Return 200 to Thread
            mimetype="application/json",
        )
