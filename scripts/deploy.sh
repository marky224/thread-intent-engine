#!/usr/bin/env bash
# ==============================================================================
# Deploy the Thread Intent Automation Engine to a customer's Azure subscription.
#
# This script:
#   1. Deploys the Bicep template (Function App + Storage + Key Vault + etc.)
#   2. Optionally deploys the Function App code via ZIP deployment
#   3. Uploads PowerShell runbooks to the Automation Account
#   4. Outputs the webhook URL and admin consent link
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - Target subscription selected (az account set --subscription <id>)
#
# Usage:
#   ./scripts/deploy.sh \
#     --resource-group <rg-name> \
#     --app-name <app-name> \
#     --notification-email <email> \
#     --client-id <app-client-id> \
#     --client-secret <app-client-secret> \
#     [--location <azure-region>] \
#     [--deploy-code]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- Parse arguments ----------
RESOURCE_GROUP=""
APP_NAME=""
NOTIFICATION_EMAIL=""
CLIENT_ID=""
CLIENT_SECRET=""
LOCATION="eastus"
DEPLOY_CODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        --app-name) APP_NAME="$2"; shift 2 ;;
        --notification-email) NOTIFICATION_EMAIL="$2"; shift 2 ;;
        --client-id) CLIENT_ID="$2"; shift 2 ;;
        --client-secret) CLIENT_SECRET="$2"; shift 2 ;;
        --location) LOCATION="$2"; shift 2 ;;
        --deploy-code) DEPLOY_CODE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate required args
for var_name in RESOURCE_GROUP APP_NAME NOTIFICATION_EMAIL CLIENT_ID CLIENT_SECRET; do
    if [[ -z "${!var_name}" ]]; then
        echo "ERROR: --$(echo $var_name | tr '_' '-' | tr '[:upper:]' '[:lower:]') is required"
        exit 1
    fi
done

echo "============================================"
echo "Thread Intent Automation Engine — Deployment"
echo "============================================"
echo "Resource Group:     $RESOURCE_GROUP"
echo "App Name:           $APP_NAME"
echo "Location:           $LOCATION"
echo "Notification Email: $NOTIFICATION_EMAIL"
echo "Deploy Code:        $DEPLOY_CODE"
echo ""

# ---------- Step 1: Create resource group if it doesn't exist ----------
echo "--- Step 1: Ensure resource group exists ---"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none 2>/dev/null || true
echo "Resource group ready: $RESOURCE_GROUP"

# ---------- Step 2: Deploy Bicep template ----------
echo ""
echo "--- Step 2: Deploy Bicep template ---"
DEPLOYMENT_OUTPUT=$(az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$PROJECT_ROOT/infra/main.bicep" \
    --parameters \
        appName="$APP_NAME" \
        location="$LOCATION" \
        notificationEmail="$NOTIFICATION_EMAIL" \
        appClientId="$CLIENT_ID" \
        appClientSecret="$CLIENT_SECRET" \
    --output json)

# Extract outputs
FUNCTION_URL=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.functionAppUrl.value')
CONSENT_URL=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.adminConsentUrl.value')
FUNC_APP_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.functionAppName.value')
AUTOMATION_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.automationAccountName.value')

echo "Bicep deployment complete."
echo ""

# ---------- Step 3: Deploy Function App code (optional) ----------
if [[ "$DEPLOY_CODE" == true ]]; then
    echo "--- Step 3: Deploy Function App code ---"

    # Package the code
    bash "$SCRIPT_DIR/package.sh" "deploy"

    # Deploy via ZIP
    az functionapp deployment source config-zip \
        --resource-group "$RESOURCE_GROUP" \
        --name "$FUNC_APP_NAME" \
        --src "$PROJECT_ROOT/dist/function-app-vdeploy.zip" \
        --output none

    echo "Function App code deployed."
    echo ""
fi

# ---------- Step 4: Upload runbooks ----------
echo "--- Step 4: Upload PowerShell runbooks ---"
for runbook_file in "$PROJECT_ROOT/runbooks"/*.ps1; do
    runbook_name=$(basename "$runbook_file" .ps1)
    echo "  Uploading runbook: $runbook_name"

    az automation runbook replace-content \
        --resource-group "$RESOURCE_GROUP" \
        --automation-account-name "$AUTOMATION_NAME" \
        --name "$runbook_name" \
        --content @"$runbook_file" \
        --output none 2>/dev/null || echo "  (Runbook $runbook_name may need manual upload)"

    az automation runbook publish \
        --resource-group "$RESOURCE_GROUP" \
        --automation-account-name "$AUTOMATION_NAME" \
        --name "$runbook_name" \
        --output none 2>/dev/null || echo "  (Runbook $runbook_name publish may need manual action)"
done
echo "Runbooks uploaded."

# ---------- Step 5: Output results ----------
echo ""
echo "============================================"
echo "  DEPLOYMENT COMPLETE"
echo "============================================"
echo ""
echo "Webhook URL (give to MSP):"
echo "  $FUNCTION_URL"
echo ""
echo "Admin Consent URL (customer clicks this):"
echo "  $CONSENT_URL"
echo ""
echo "Next steps:"
echo "  1. Customer clicks the Admin Consent URL to grant Graph API permissions"
echo "  2. Customer shares the Webhook URL with their MSP"
echo "  3. MSP sets the URL as the automation endpoint in Thread intents"
echo "  4. Assign Exchange Administrator role to the Automation Account's managed identity"
echo "     (required for shared mailbox operations)"
echo ""
echo "To test the webhook:"
echo "  curl -X POST '$FUNCTION_URL' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"intent_name\": \"Password Reset\", \"intent_fields\": {\"User Email\": \"testuser@yourdomain.com\"}, \"meta_data\": {\"ticket_id\": 9999, \"contact_name\": \"Test\", \"contact_email\": \"test@test.com\", \"company_name\": \"Test Co\"}}'"
