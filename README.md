# Thread Intent Automation Engine

Microsoft 365 user management automation app, deployed as a customer-hosted Azure Function App. Receives structured webhook payloads from Thread's Magic Agent Intent system and executes corresponding M365 operations via Microsoft Graph API and Exchange Online PowerShell.

## Architecture

Each customer deployment is a self-contained unit in the customer's own Azure subscription:

```
Thread Magic Agent
       │
       ▼ HTTP POST (IP-whitelisted)
┌──────────────────────────────────────────────────┐
│  Customer's Azure Subscription                   │
│                                                  │
│  ┌──────────────┐   ┌───────────┐   ┌─────────┐ │
│  │ Function App │──▶│ Key Vault │   │ Storage │ │
│  │ (Python)     │   │ (secrets) │   │ (dedup) │ │
│  └──────┬───────┘   └───────────┘   └─────────┘ │
│         │                                        │
│         ├──▶ Microsoft Graph API (user mgmt)     │
│         │                                        │
│         └──▶ Automation Account (EXO runbooks)   │
│                                                  │
│  ┌──────────────────┐                            │
│  │ App Insights     │ (monitoring & audit)       │
│  └──────────────────┘                            │
└──────────────────────────────────────────────────┘
```

## Project Structure

```
thread-intent-engine/
├── infra/                        # Bicep deployment templates
│   ├── main.bicep                # Orchestrator
│   ├── modules/
│   │   ├── functionApp.bicep     # Function App + IP restrictions
│   │   ├── storage.bicep         # Storage + idempotency table
│   │   ├── keyVault.bicep        # Key Vault + secrets
│   │   ├── appInsights.bicep     # Application Insights
│   │   └── automationAccount.bicep # Automation Account + runbooks
│   └── parameters/
│       └── dev.parameters.json   # Dev deployment params (template)
├── src/                          # Python Function App
│   ├── function_app.py           # HTTP trigger + dispatcher
│   ├── intents/                  # Intent handlers (one per intent)
│   │   ├── base.py               # Base class with shared helpers
│   │   ├── password_reset.py
│   │   ├── add_user_to_group.py
│   │   ├── remove_user_from_group.py
│   │   ├── license_assignment.py
│   │   ├── mfa_reset.py
│   │   ├── new_user_creation.py
│   │   ├── user_offboarding.py
│   │   └── shared_mailbox_permission.py
│   ├── services/                 # Shared infrastructure
│   │   ├── graph_client.py       # MSAL + Graph API helpers
│   │   ├── keyvault_client.py    # Secret reads (KV or env vars)
│   │   ├── idempotency.py        # Table Storage deduplication
│   │   ├── notification.py       # Failure email via Graph sendMail
│   │   └── automation.py         # Trigger Automation runbooks
│   ├── models/
│   │   ├── __init__.py           # Pydantic webhook payload models
│   │   └── errors.py             # Custom exceptions + error mapping
│   ├── host.json
│   └── requirements.txt
├── runbooks/                     # PowerShell runbooks (Exchange Online)
│   ├── Set-SharedMailboxPermission.ps1
│   └── Convert-ToSharedMailbox.ps1
├── scripts/
│   ├── deploy.sh                 # Full deployment script
│   └── package.sh                # ZIP packaging for RUN_FROM_PACKAGE
└── docs/
    └── troubleshooting-queries.md
```

## Webhook Payload Format

```json
{
  "intent_name": "Add User to Group",
  "intent_fields": {
    "User Email": "jane.doe@contoso.com",
    "Group Name": "Marketing Team"
  },
  "meta_data": {
    "ticket_id": 5678,
    "contact_name": "Jane Doe",
    "contact_email": "jane.doe@contoso.com",
    "company_name": "Contoso Corp"
  }
}
```

## Supported Intents

| Intent | Method |
|--------|--------|
| Password Reset | Graph API |
| Add User to Group | Graph API |
| License Assignment | Graph API |
| Remove User from Group | Graph API |
| MFA Reset | Graph API |
| New User Creation | Graph API |
| User Offboarding | Graph API + Runbook |
| Shared Mailbox Permission | EXO Runbook |

## Prerequisites

**Tools:**
- Python 3.11+
- Azure CLI (`az`) — [install](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- Bicep CLI — install via `az bicep install`
- Azure Functions Core Tools v4 (`func`) — [install](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local)
- Azurite (local storage emulator) — `npm install -g azurite`
- Git

**Azure / Microsoft 365:**
- A Microsoft 365 tenant with an Azure subscription
- An Azure AD multi-tenant app registration with required permissions (see Step 2 below)
- A test user in the tenant for validation

## Deploy Locally

### 1. Clone and install
 
```bash
git clone https://github.com/marky224/thread-intent-engine.git
cd thread-intent-engine/src
python -m venv .venv
.venv\Scripts\activate      # Windows
# source .venv/bin/activate  # macOS/Linux
pip install -r requirements.txt
```

### 2. Create the App Registration
 
In the Azure Portal → **Microsoft Entra ID** → **App registrations** → **New registration**:
 
| Setting | Value |
|---------|-------|
| Name | `Thread Intent Automation Engine` |
| Supported account types | **Multiple Entra ID tenants** (multi-tenant) |
| Redirect URI | Leave blank for now |
 
Create a **client secret** (Certificates & secrets → New client secret → 12 months). Copy the **Value** immediately — it's only shown once.

**Add a Redirect URI** (required for admin consent during Azure deployment):

1. Go to **Authentication** in the left sidebar
2. Click **+ Add a platform** → choose **Web**
3. Enter `https://portal.azure.com` as the Redirect URI
4. Click **Configure**

> **Why this is needed:** The admin consent URL redirects to this URI after the customer grants permissions. Without it, the consent flow fails with error `AADSTS500113: No reply address is registered for the application`.
 
### 3. Add API Permissions
 
Add these **Application** permissions (not Delegated) under **API permissions** → **Microsoft Graph**:
 
```
User.ReadWrite.All
Directory.ReadWrite.All
GroupMember.ReadWrite.All
UserAuthenticationMethod.ReadWrite.All
MailboxSettings.ReadWrite
Mail.Send
```

Then add one more: **APIs my organization uses** → **Office 365 Exchange Online** → **Application permissions** → `Exchange.ManageAsApp`
 
Click **Grant admin consent for [your tenant]** — all permissions should show green checkmarks.

### 4. Assign the Helpdesk Administrator Role
 
The app registration's service principal needs the **Helpdesk Administrator** directory role to reset user (non-admin) passwords. This is a directory-level role assignment, not an API permission.
 
1. Go to **Microsoft Entra ID** → **Roles and administrators**
2. Search for **Helpdesk Administrator** → click on the role name
3. Click **+ Add assignments**
4. Search for `Thread Intent Automation Engine` → select it → click **Add**
 
> **Why this is needed:** The `User.ReadWrite.All` permission allows updating most user properties, but `passwordProfile` is a privileged operation that requires a directory role. Helpdesk Administrator grants password reset for non-admin users, which is the correct security boundary — the app cannot reset passwords for Global Admins or other privileged roles.

### 5. Configure local settings
 
```bash
cd src
cp local.settings.json.template local.settings.json
```
 
Edit `local.settings.json` with your credentials:
 
```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "FUNCTIONS_EXTENSION_VERSION": "~4",
    "KEY_VAULT_NAME": "",
    "STORAGE_ACCOUNT_NAME": "",
    "IDEMPOTENCY_TTL_SECONDS": "3600",
    "LOCAL_DEV": "true",
    "LOCAL_APP_CLIENT_ID": "<your-app-client-id>",
    "LOCAL_APP_CLIENT_SECRET": "<your-client-secret-value>",
    "LOCAL_TENANT_ID": "<your-tenant-id>",
    "LOCAL_NOTIFICATION_EMAIL": "<your-admin-upn>",
    "LOCAL_NOTIFICATION_MAILBOX": "<your-admin-upn>"
  }
}
```

### 6. Run locally
 
Start Azurite (separate terminal):
```bash
azurite --silent --location C:\temp\azurite
```
 
Create the idempotency table (separate terminal):
```bash
python -c "from azure.data.tables import TableServiceClient; client = TableServiceClient.from_connection_string('UseDevelopmentStorage=true'); client.create_table_if_not_exists('idempotency'); print('Table created')"
```
 
Start the Function App (separate terminal):
```bash
cd src
func start
```

### 7. Test
 
```powershell
$body = @{
    intent_name = "Password Reset"
    intent_fields = @{
        "User Email" = "testuser@yourtenant.onmicrosoft.com"
        "Force Change on Login" = "Yes"
    }
    meta_data = @{
        ticket_id = 1001
        contact_name = "Test Admin"
        contact_email = "admin@yourtenant.onmicrosoft.com"
        company_name = "Test Company"
    }
} | ConvertTo-Json -Depth 3
 
Invoke-RestMethod -Uri http://localhost:7071/api/intent -Method POST -ContentType "application/json" -Body $body
```

## Deploy to Azure

### Prerequisites

- Azure CLI installed (`az --version`)
- Bicep CLI installed (`az bicep install`)
- Azure Functions Core Tools v4 (`func --version`)
- App registration created with all permissions granted (see Steps 2-4 above)
- **Redirect URI** `https://portal.azure.com` added to the app registration (Authentication → Add a platform → Web)

### Step 1: Login and Register Resource Providers
```bash
az login
az account set --subscription "<your-subscription-id>"

# Register required providers (one-time per subscription)
az provider register --namespace Microsoft.Web
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.Insights
az provider register --namespace Microsoft.Automation
az provider register --namespace Microsoft.OperationalInsights
```

### Step 2: Create Resource Group
```bash
az group create --name rg-thread-automation --location eastus
```

> **Note:** If you haven't already created the app registration, follow Steps 2-4 under "Deploy Locally" above. Before proceeding, also add a Redirect URI:
> 1. App registration → **Authentication** → **+ Add a platform** → **Web**
> 2. Enter `https://portal.azure.com` → click **Configure**
>
> Without this, the admin consent URL will fail with `AADSTS500113`.

### Step 3: Deploy Infrastructure (Bicep)
```bash
az deployment group create \
  --resource-group rg-thread-automation \
  --template-file infra/main.bicep \
  --parameters \
    appName="yourcompany-threadauto" \
    location="eastus" \
    notificationEmail="admin@yourdomain.com" \
    notificationMailbox="admin@yourdomain.com" \
    appClientId="<APP-CLIENT-ID>" \
    appClientSecret="<APP-CLIENT-SECRET>" \
  --output json
```

Save the `functionAppUrl` and `adminConsentUrl` from the deployment outputs.

> **Note:** `notificationEmail` is the TO address for failure alerts. `notificationMailbox` is the FROM address (must be a valid mailbox UPN in the tenant). If `notificationMailbox` is left empty, failure notification emails will not be sent.

### Step 4: Grant Admin Consent

Open the `adminConsentUrl` from the deployment outputs in your browser and click **Accept**.

### Step 5: Deploy Function App Code
```bash
cd src
func azure functionapp publish <functionAppName> --python
```

Replace `<functionAppName>` with the value from deployment outputs (e.g., `yourcompany-threadauto-func`).

### Step 6: Grant Table Storage Access

The Function App's managed identity needs access to Table Storage for idempotency:
```bash
# Get the managed identity principal ID
principalId=$(az functionapp identity show \
  --resource-group rg-thread-automation \
  --name <functionAppName> \
  --query principalId --output tsv)

# Get the storage account resource ID
storageId=$(az storage account show \
  --resource-group rg-thread-automation \
  --name <storageAccountName> \
  --query id --output tsv)

# Assign role
az role assignment create \
  --assignee $principalId \
  --role "Storage Table Data Contributor" \
  --scope $storageId
```

### Step 7: Grant Key Vault Access for Admin (Optional)

If you need to manage Key Vault secrets via CLI (e.g., update notification settings), add your user:
```bash
az keyvault set-policy \
  --name <keyVaultName> \
  --upn <your-admin-upn> \
  --secret-permissions get list set
```

> **Note:** After updating any Key Vault secret, restart the Function App to clear the cached values:
> ```bash
> az functionapp restart \
>   --resource-group rg-thread-automation \
>   --name <functionAppName>
> ```

### Step 8: Configure Automation Account

Upload runbook content and publish:
```bash
cd ..
az automation runbook replace-content \
  --resource-group rg-thread-automation \
  --automation-account-name <automationAccountName> \
  --name Set-SharedMailboxPermission \
  --content @runbooks/Set-SharedMailboxPermission.ps1

az automation runbook publish \
  --resource-group rg-thread-automation \
  --automation-account-name <automationAccountName> \
  --name Set-SharedMailboxPermission

az automation runbook replace-content \
  --resource-group rg-thread-automation \
  --automation-account-name <automationAccountName> \
  --name Convert-ToSharedMailbox \
  --content @runbooks/Convert-ToSharedMailbox.ps1

az automation runbook publish \
  --resource-group rg-thread-automation \
  --automation-account-name <automationAccountName> \
  --name Convert-ToSharedMailbox
```

Set environment variables so the Function App can trigger runbooks:
```bash
az functionapp config appsettings set \
  --resource-group rg-thread-automation \
  --name <functionAppName> \
  --settings \
    AZURE_SUBSCRIPTION_ID="<your-subscription-id>" \
    AZURE_RESOURCE_GROUP="rg-thread-automation" \
    AUTOMATION_ACCOUNT_NAME="<automationAccountName>"
```

### Step 9: Assign Exchange Administrator Role (Portal)

1. Azure Portal → **Microsoft Entra ID** → **Roles and administrators**
2. Search for **Exchange Administrator** → click the role name
3. Click **+ Add assignments**
4. Search for your Automation Account name → select it → click **Add**

### Step 10: Test

Temporarily allow your IP for testing:
```bash
az functionapp config access-restriction add \
  --resource-group rg-thread-automation \
  --name <functionAppName> \
  --priority 90 \
  --rule-name "MyTestIP" \
  --action Allow \
  --ip-address <YOUR-PUBLIC-IP>/32
```

Send a test webhook:
```powershell
$body = @{
    intent_name = "Password Reset"
    intent_fields = @{
        "User Email" = "testuser@yourtenant.onmicrosoft.com"
        "Force Change on Login" = "Yes"
    }
    meta_data = @{
        ticket_id = 1001
        contact_name = "Test Admin"
        contact_email = "admin@yourtenant.onmicrosoft.com"
        company_name = "Test Company"
    }
} | ConvertTo-Json -Depth 3

Invoke-RestMethod -Uri <functionAppUrl> -Method POST -ContentType "application/json" -Body $body
```

After testing, remove your IP rule:
```bash
az functionapp config access-restriction remove \
  --resource-group rg-thread-automation \
  --name <functionAppName> \
  --rule-name "MyTestIP"
```

## Observability
 
All events are logged to Application Insights with structured `custom_dimensions` for KQL queryability:
 
| Event | Fields |
|-------|--------|
| `webhook_received` | intent_name, ticket_id, company_name, raw_payload, raw_headers |
| `intent_result` | intent_name, ticket_id, status, duration_ms, result_summary or error_message |
| `idempotency_skip` | intent_name, ticket_id, dedup_key |
| `notification_failure` | intent_name, ticket_id, notification_error |

## Security

- **IP whitelisting**: Function App only accepts traffic from Thread's static IPs
- **Key Vault**: All secrets accessed via managed identity (never in app settings)
- **HTTPS only**: Enforced by Azure Functions
- **Idempotency**: Prevents duplicate operations from webhook retries
- **Helpdesk Administrator scope** — App can reset passwords for standard users only, not admin accounts
- **Customer-owned**: All resources visible in the customer's Azure portal

## Required Permissions Summary
 
**Graph API Permissions (Application):**
- `User.ReadWrite.All`, `Directory.ReadWrite.All`, `GroupMember.ReadWrite.All`
- `UserAuthenticationMethod.ReadWrite.All`, `MailboxSettings.ReadWrite`, `Mail.Send`
 
**Exchange Online Permission (Application):**
- `Exchange.ManageAsApp`
 
**Entra ID Directory Roles:**
- **Helpdesk Administrator** — on the app registration's service principal (required for password reset)
- **Exchange Administrator** — on the Automation Account's managed identity (required for EXO runbooks (Shared Mailbox Functionality))

## Cost

$0–$2/month per customer deployment. All resources fall within Azure free tiers at expected webhook volumes (50–200/month).
