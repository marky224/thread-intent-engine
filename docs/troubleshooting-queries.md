# Application Insights — Troubleshooting Queries

Use these queries in the Azure Portal under your **Application Insights** resource → **Logs**.

---

## View All Recent Webhooks

See every webhook Thread has sent, with the full payload:

```kql
traces
| where customDimensions.event == "webhook_received"
| project
    timestamp,
    intent = customDimensions.intent_name,
    ticket = customDimensions.ticket_id,
    company = customDimensions.company_name,
    contact = customDimensions.contact_email,
    payload = customDimensions.raw_payload,
    headers = customDimensions.raw_headers
| order by timestamp desc
| take 50
```

## View All Intent Results (Success + Failure)

```kql
traces
| where customDimensions.event == "intent_result"
| project
    timestamp,
    intent = customDimensions.intent_name,
    ticket = customDimensions.ticket_id,
    company = customDimensions.company_name,
    status = customDimensions.status,
    duration = customDimensions.duration_ms,
    error = customDimensions.error_message
| order by timestamp desc
| take 50
```

## Failures Only

```kql
traces
| where customDimensions.event == "intent_result"
| where customDimensions.status == "failed"
| project
    timestamp,
    intent = customDimensions.intent_name,
    ticket = customDimensions.ticket_id,
    company = customDimensions.company_name,
    error_type = customDimensions.error_type,
    error = customDimensions.error_message,
    http_status = customDimensions.http_status,
    duration = customDimensions.duration_ms
| order by timestamp desc
```

## Find a Specific Ticket

Replace `5678` with the actual ticket ID:

```kql
traces
| where customDimensions.ticket_id == "5678"
| project
    timestamp,
    event = customDimensions.event,
    intent = customDimensions.intent_name,
    status = customDimensions.status,
    payload = customDimensions.raw_payload,
    error = customDimensions.error_message
| order by timestamp asc
```

## Find a Specific Intent Type

```kql
traces
| where customDimensions.intent_name == "Password Reset"
| where customDimensions.event == "intent_result"
| project
    timestamp,
    ticket = customDimensions.ticket_id,
    status = customDimensions.status,
    duration = customDimensions.duration_ms,
    error = customDimensions.error_message
| order by timestamp desc
| take 20
```

## Duplicate / Skipped Requests

See webhooks that were caught by idempotency:

```kql
traces
| where customDimensions.event == "idempotency_skip"
| project
    timestamp,
    intent = customDimensions.intent_name,
    ticket = customDimensions.ticket_id,
    dedup_key = customDimensions.dedup_key
| order by timestamp desc
```

## Payload Validation Failures

Malformed payloads from Thread — useful during initial integration:

```kql
traces
| where customDimensions.event == "webhook_validation_error"
| project
    timestamp,
    intent = customDimensions.intent_name,
    validation_error = customDimensions.validation_error,
    payload = customDimensions.raw_payload
| order by timestamp desc
```

## Raw Payload for a Specific Webhook

When you need to see exactly what Thread sent — the raw JSON body:

```kql
traces
| where customDimensions.event == "webhook_received"
| where customDimensions.ticket_id == "5678"
| project
    timestamp,
    payload = customDimensions.raw_payload,
    headers = customDimensions.raw_headers
```

## Success Rate Over Time (Last 7 Days)

```kql
traces
| where customDimensions.event == "intent_result"
| where timestamp > ago(7d)
| summarize
    total = count(),
    succeeded = countif(customDimensions.status == "success"),
    failed = countif(customDimensions.status == "failed")
    by bin(timestamp, 1d)
| extend success_rate = round(100.0 * succeeded / total, 1)
| order by timestamp asc
```

## Average Duration by Intent

```kql
traces
| where customDimensions.event == "intent_result"
| where customDimensions.status == "success"
| extend duration = toint(customDimensions.duration_ms)
| summarize
    avg_ms = avg(duration),
    p95_ms = percentile(duration, 95),
    count = count()
    by tostring(customDimensions.intent_name)
| order by count desc
```

## Notification Failures

Cases where the intent failed AND the failure email also failed to send:

```kql
traces
| where customDimensions.event == "notification_failure"
| project
    timestamp,
    intent = customDimensions.intent_name,
    ticket = customDimensions.ticket_id,
    notification_error = customDimensions.notification_error
| order by timestamp desc
```

---

## How to Access These Queries

1. Open the **Azure Portal**
2. Navigate to the **Application Insights** resource in the customer's resource group
3. Click **Logs** in the left sidebar
4. Paste any query above and click **Run**

Tip: Save frequently-used queries by clicking **Save** → **Save as query** in the Logs blade.
