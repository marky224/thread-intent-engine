"""Thread Intent Automation Engine — Azure Function App entry point.

HTTP-triggered serverless function that receives webhook payloads from Thread's
Magic Agent Intent system and dispatches them to the appropriate intent handler.

Flow:
  1. Receive HTTP POST at /api/intent
  2. Validate payload structure (Pydantic)
  3. Check idempotency (Azure Table Storage)
  4. Route to intent handler by intent_name
  5. Execute Graph API operation(s)
  6. On success: mark idempotency record completed, log to App Insights
  7. On failure: clear idempotency record, send notification email, log error
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

# ---------- Azure Function App ----------

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


@app.route(route="intent", methods=["POST"])
def intent_webhook(req: func.HttpRequest) -> func.HttpResponse:
    """Main webhook endpoint — receives Thread intent payloads and dispatches to handlers."""
    start_time = time.time()
    payload = None

    try:
        # --- Step 1: Parse and validate payload ---
        try:
            body = req.get_json()
        except ValueError:
            logger.error("Invalid JSON in request body")
            return func.HttpResponse(
                json.dumps({"error": "Invalid JSON"}),
                status_code=400,
                mimetype="application/json",
            )

        try:
            payload = WebhookPayload(**body)
        except Exception as e:
            logger.error("Payload validation failed: %s", e)
            return func.HttpResponse(
                json.dumps({"error": f"Payload validation failed: {e}"}),
                status_code=400,
                mimetype="application/json",
            )

        intent_name = payload.intent_name
        ticket_id = payload.meta_data.ticket_id

        logger.info(
            "Webhook received: intent=%s, ticket=%d, company=%s",
            intent_name, ticket_id, payload.meta_data.company_name,
        )

        # --- Step 2: Look up intent handler ---
        handler_class = INTENT_REGISTRY.get(intent_name)
        if not handler_class:
            logger.error("Unknown intent: %s", intent_name)
            return func.HttpResponse(
                json.dumps({
                    "error": f"Unknown intent: {intent_name}",
                    "supported_intents": list(INTENT_REGISTRY.keys()),
                }),
                status_code=400,
                mimetype="application/json",
            )

        # --- Step 3: Idempotency check ---
        try:
            check_and_claim(ticket_id, intent_name)
        except IdempotencySkip as e:
            logger.info("Idempotency: skipping duplicate — %s", e.dedup_key)
            return func.HttpResponse(
                json.dumps({"status": "skipped", "reason": "duplicate_request", "key": e.dedup_key}),
                status_code=200,
                mimetype="application/json",
            )

        # --- Step 4: Initialize services and execute ---
        secrets = get_secrets()
        graph_client = GraphClient(secrets)

        handler = handler_class(payload=payload, graph_client=graph_client)

        # Validate intent fields
        handler.validate()

        # Execute the Graph API operation(s)
        result = handler.execute()

        # --- Step 5: Success ---
        mark_completed(ticket_id, intent_name)

        duration_ms = int((time.time() - start_time) * 1000)
        logger.info(
            "Intent completed: intent=%s, ticket=%d, duration=%dms, result=%s",
            intent_name, ticket_id, duration_ms, result.get("status", "success"),
        )

        return func.HttpResponse(
            json.dumps({"status": "success", "intent": intent_name, "result": result}),
            status_code=200,
            mimetype="application/json",
        )

    except (ValidationError, GraphApiError, IntentError) as e:
        # --- Known error: clear idempotency, send notification ---
        duration_ms = int((time.time() - start_time) * 1000)
        logger.error(
            "Intent failed: intent=%s, error=%s, status=%d, duration=%dms",
            getattr(e, "intent_name", "unknown"), str(e),
            getattr(e, "status_code", 500), duration_ms,
        )

        if payload:
            clear_on_failure(payload.meta_data.ticket_id, payload.intent_name)
            try:
                secrets = get_secrets()
                send_failure_notification(payload, e, secrets)
            except Exception as notify_err:
                logger.error("Failed to send failure notification: %s", notify_err)

        return func.HttpResponse(
            json.dumps({"status": "failed", "error": str(e)}),
            status_code=200,  # Return 200 to Thread (fire-and-forget, no retry needed)
            mimetype="application/json",
        )

    except Exception as e:
        # --- Unexpected error ---
        duration_ms = int((time.time() - start_time) * 1000)
        logger.exception("Unexpected error processing webhook (duration=%dms): %s", duration_ms, e)

        if payload:
            clear_on_failure(payload.meta_data.ticket_id, payload.intent_name)
            try:
                secrets = get_secrets()
                send_failure_notification(payload, e, secrets)
            except Exception as notify_err:
                logger.error("Failed to send failure notification: %s", notify_err)

        return func.HttpResponse(
            json.dumps({"status": "failed", "error": "Internal server error"}),
            status_code=200,  # Return 200 to Thread
            mimetype="application/json",
        )
