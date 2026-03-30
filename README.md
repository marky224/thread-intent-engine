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

## Supported Intents

| Intent | Method |
|--------|--------|
| Password Reset | Graph API |
| Add User to Group | Graph API |
| License Assignment | Graph API |
| Remove User from Group | Graph API |
| MFA Reset | Graph API |
| New User Creation | Graph API (multi-step) |
| User Offboarding | Graph API + Runbook |
| Shared Mailbox Permission | EXO Runbook |

## Prerequisites

- Azure CLI (`az`) installed and logged in
- Python 3.11+
- Azure Functions Core Tools v4 (`func`)
- An Azure AD multi-tenant app registration with required Graph permissions
- A Microsoft 365 tenant

## Quick Start

### 1. Create the App Registration

In the Azure Portal → Entra ID → App registrations → New registration:
- Name: `Thread Intent Automation Engine`
- Supported account types: **Accounts in any organizational directory** (multi-tenant)
- Add a client secret and note the **Client ID** and **Client Secret**

Add these **Application** (not delegated) permissions:
- `User.ReadWrite.All`
- `Directory.ReadWrite.All`
- `GroupMember.ReadWrite.All`
- `UserAuthenticationMethod.ReadWrite.All`
- `MailboxSettings.ReadWrite`
- `Mail.Send`
- `Exchange.ManageAsApp`

### 2. Deploy to Azure

```bash
chmod +x scripts/deploy.sh scripts/package.sh

./scripts/deploy.sh \
  --resource-group rg-thread-automation \
  --app-name contoso-threadauto \
  --notification-email admin@contoso.com \
  --client-id <YOUR-APP-CLIENT-ID> \
  --client-secret <YOUR-APP-CLIENT-SECRET> \
  --deploy-code
```

The script outputs:
- **Webhook URL**: Give this to the MSP for Thread intent configuration
- **Admin Consent URL**: Customer clicks this to grant Graph permissions

### 3. Grant Admin Consent

Click the Admin Consent URL from the deployment output. This grants the app registration's Graph API permissions within the customer's tenant.

### 4. Test the Webhook

```bash
curl -X POST 'https://contoso-threadauto-func.azurewebsites.net/api/intent' \
  -H 'Content-Type: application/json' \
  -d '{
    "intent_name": "Password Reset",
    "intent_fields": {
      "User Email": "testuser@contoso.onmicrosoft.com",
      "Force Change on Login": "Yes"
    },
    "meta_data": {
      "ticket_id": 9999,
      "contact_name": "Test User",
      "contact_email": "test@contoso.com",
      "company_name": "Contoso"
    }
  }'
```

### 5. Local Development

```bash
cd src
cp local.settings.json.template local.settings.json
# Edit local.settings.json with your app registration credentials

pip install -r requirements.txt
func start
```

Test locally:
```bash
curl -X POST http://localhost:7071/api/intent \
  -H 'Content-Type: application/json' \
  -d '{ ... }'
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
└── scripts/
    ├── deploy.sh                 # Full deployment script
    └── package.sh                # ZIP packaging for RUN_FROM_PACKAGE
```

## Security

- **IP whitelisting**: Function App only accepts traffic from Thread's static IPs
- **Key Vault**: All secrets accessed via managed identity (never in app settings)
- **HTTPS only**: Enforced by Azure Functions
- **Idempotency**: Prevents duplicate operations from webhook retries
- **Customer-owned**: All resources visible in the customer's Azure portal

## Webhook Payload Format

```json
{
  "intent_name": "Add User to Group",
  "intent_fields": {
    "User Email": "jane.doe@contoso.com",
    "Group Name": "Marketing Team",
    "Group Type": "Microsoft 365"
  },
  "meta_data": {
    "ticket_id": 5678,
    "contact_name": "Jane Doe",
    "contact_email": "jane.doe@contoso.com",
    "company_name": "Contoso Corp"
  }
}
```

## Cost

$0–$2/month per customer deployment. All resources fall within Azure free tiers at expected webhook volumes (50–200/month).
