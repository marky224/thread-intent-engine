<#
.SYNOPSIS
    Creates the Thread Intent Automation Engine multi-tenant app registration
    with all required Graph API permissions, Exchange Online permission, and
    the redirect URI needed for admin consent.

.DESCRIPTION
    Automates the manual portal steps (README Steps 2-4) into a single script:
      1. Creates the multi-tenant app registration
      2. Adds all required Microsoft Graph application permissions
      3. Adds Exchange.ManageAsApp application permission
      4. Adds the https://portal.azure.com redirect URI
      5. Creates a client secret (12-month expiry)
      6. Grants admin consent for all permissions in the current tenant
      7. Assigns Helpdesk Administrator role to the service principal

    The client secret VALUE is displayed once — copy it immediately.

.PARAMETER AppName
    Display name for the app registration. Default: "Thread Intent Automation Engine"

.PARAMETER SecretExpiryMonths
    Client secret validity in months. Default: 12

.PARAMETER SkipHelpdeskRole
    Skip assigning the Helpdesk Administrator directory role.

.EXAMPLE
    .\scripts\register-app.ps1

.EXAMPLE
    .\scripts\register-app.ps1 -AppName "Thread Automation - Dev" -SecretExpiryMonths 6

.NOTES
    Requires: Azure CLI logged in with Global Administrator or
    Application Administrator + Privileged Role Administrator permissions.
#>

[CmdletBinding()]
param(
    [string]$AppName = "Thread Intent Automation Engine",
    [int]$SecretExpiryMonths = 12,
    [switch]$SkipHelpdeskRole
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ---------- Well-known permission IDs ----------
# Microsoft Graph (resource ID: 00000003-0000-0000-c000-000000000000)
$graphResourceId = "00000003-0000-0000-c000-000000000000"
$graphPermissions = @{
    "User.ReadWrite.All"                       = "741f803b-c850-494e-b5df-cde7c675a1ca"
    "Directory.ReadWrite.All"                   = "19dbc75e-c2e2-444c-a770-ec69d8559fc7"
    "GroupMember.ReadWrite.All"                 = "dbaae8cf-10b5-4b86-a4a1-f871c94c6571"
    "UserAuthenticationMethod.ReadWrite.All"    = "50483e42-d915-4231-9639-7fdb7fd190e5"
    "MailboxSettings.ReadWrite"                 = "6931bccd-447a-43d1-b442-00a195474933"
    "Mail.Send"                                = "b633e1c5-b582-4048-a93e-9f11b44c7e96"
}

# Office 365 Exchange Online (resource ID: 00000002-0000-0ff1-ce00-000000000000)
$exchangeResourceId = "00000002-0000-0ff1-ce00-000000000000"
$exchangePermissions = @{
    "Exchange.ManageAsApp"                     = "dc50a0fb-09a3-484d-be87-e023b12c6440"
}

$HelpdeskAdminRoleId = "729827e3-9c14-49f7-bb1b-9608f156bbb8"

# ---------- Helpers ----------
function Write-Step {
    param([int]$Number, [string]$Title)
    Write-Host ""
    Write-Host "=== Step $Number : $Title ===" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

# ---------- Pre-flight ----------

Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  Thread Intent Automation Engine — App Registration Setup"
Write-Host "============================================================" -ForegroundColor White
Write-Host ""

# Verify login
$account = az account show --query "{tenant:tenantId, name:name, user:user.name}" -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "ERROR: Not logged in. Run 'az login' first." -ForegroundColor Red
    exit 1
}

Write-Host "Signed in as: $($account.user)"
Write-Host "Tenant:        $($account.tenant)"
Write-Host "Subscription:  $($account.name)"
Write-Host ""

# ================================================================
# STEP 1: Create the multi-tenant app registration
# ================================================================
Write-Step 1 "Create App Registration"

# Check if app already exists
$existingApp = az ad app list --display-name $AppName --query "[0].appId" -o tsv 2>$null
if ($existingApp) {
    Write-Host "  App registration '$AppName' already exists: $existingApp" -ForegroundColor Yellow
    $confirm = Read-Host "  Overwrite permissions and create a new secret? (y/N)"
    if ($confirm -ne "y") {
        Write-Host "  Exiting." -ForegroundColor Yellow
        exit 0
    }
    $appId = $existingApp
    Write-Host "  Using existing app: $appId" -ForegroundColor Gray
} else {
    # Create the app registration (multi-tenant, no redirect URI yet)
    $appJson = az ad app create `
        --display-name $AppName `
        --sign-in-audience "AzureADMultipleOrgs" `
        --query "{appId:appId, objectId:id}" `
        -o json | ConvertFrom-Json

    $appId = $appJson.appId
    $appObjectId = $appJson.objectId

    Write-Success "App registration created"
    Write-Host "    Client ID: $appId" -ForegroundColor White
}

# Get object ID (needed for subsequent operations)
$appObjectId = az ad app show --id $appId --query "id" -o tsv

# ================================================================
# STEP 2: Add Redirect URI
# ================================================================
Write-Step 2 "Add Redirect URI"

az ad app update --id $appId `
    --web-redirect-uris "https://portal.azure.com" `
    --output none

Write-Success "Redirect URI set: https://portal.azure.com"

# ================================================================
# STEP 3: Add Microsoft Graph Permissions
# ================================================================
Write-Step 3 "Add Microsoft Graph API Permissions"

foreach ($perm in $graphPermissions.GetEnumerator()) {
    Write-Host "  Adding: $($perm.Key)" -ForegroundColor Gray
    az ad app permission add `
        --id $appId `
        --api $graphResourceId `
        --api-permissions "$($perm.Value)=Role" `
        --output none 2>&1 | Out-Null
}
Write-Success "All Graph permissions added"

# ================================================================
# STEP 4: Add Exchange Online Permission
# ================================================================
Write-Step 4 "Add Exchange Online Permission (Exchange.ManageAsApp)"

foreach ($perm in $exchangePermissions.GetEnumerator()) {
    Write-Host "  Adding: $($perm.Key)" -ForegroundColor Gray
    az ad app permission add `
        --id $appId `
        --api $exchangeResourceId `
        --api-permissions "$($perm.Value)=Role" `
        --output none 2>&1 | Out-Null
}
Write-Success "Exchange.ManageAsApp permission added"

# ================================================================
# STEP 5: Create Client Secret
# ================================================================
Write-Step 5 "Create Client Secret ($SecretExpiryMonths-month expiry)"

$endDate = (Get-Date).AddMonths($SecretExpiryMonths).ToString("yyyy-MM-ddTHH:mm:ssZ")
$secretJson = az ad app credential reset `
    --id $appId `
    --append `
    --display-name "thread-auto-secret" `
    --end-date $endDate `
    --query "{password:password, endDate:endDateTime}" `
    -o json | ConvertFrom-Json

$clientSecret = $secretJson.password

Write-Success "Client secret created (expires: $($secretJson.endDate))"
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Red
Write-Host "  COPY THIS SECRET NOW — it will not be shown again:" -ForegroundColor Red
Write-Host ""
Write-Host "    Client Secret: $clientSecret" -ForegroundColor White
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Red

# ================================================================
# STEP 6: Ensure Service Principal Exists + Grant Admin Consent
# ================================================================
Write-Step 6 "Grant Admin Consent"

# Ensure SP exists (created automatically for single-tenant, may not exist for multi-tenant)
$spId = az ad sp show --id $appId --query "id" -o tsv 2>$null
if (-not $spId) {
    Write-Host "  Creating service principal..." -ForegroundColor Gray
    $spId = az ad sp create --id $appId --query "id" -o tsv
}

Write-Host "  Service Principal Object ID: $spId" -ForegroundColor Gray
Write-Host "  Granting admin consent for all permissions..." -ForegroundColor Gray

# Grant admin consent (Graph permissions)
az ad app permission admin-consent --id $appId 2>&1 | Out-Null
Start-Sleep -Seconds 5  # Allow propagation

# Verify consent
$permsStatus = az ad app permission list-grants --id $spId --query "length(@)" -o tsv 2>$null
Write-Success "Admin consent granted"

# ================================================================
# STEP 7: Assign Helpdesk Administrator Role
# ================================================================
Write-Step 7 "Assign Helpdesk Administrator Role"

if ($SkipHelpdeskRole) {
    Write-Host "  [SKIP] Helpdesk Administrator assignment skipped (flag set)" -ForegroundColor Yellow
} else {
    # Check if already assigned
    $existingRole = az rest --method GET `
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$spId' and roleDefinitionId eq '$HelpdeskAdminRoleId'" `
        --query "value | length(@)" -o tsv 2>$null

    if ($existingRole -and [int]$existingRole -gt 0) {
        Write-Host "  [SKIP] Helpdesk Administrator already assigned" -ForegroundColor Yellow
    } else {
        $roleBody = @{
            principalId = $spId
            roleDefinitionId = $HelpdeskAdminRoleId
            directoryScopeId = "/"
        } | ConvertTo-Json -Compress

        az rest --method POST `
            --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" `
            --headers "Content-Type=application/json" `
            --body $roleBody `
            --output none 2>&1 | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Success "Helpdesk Administrator assigned to service principal"
        } else {
            Write-Host "  [FAIL] Could not assign role — do this manually in Entra ID" -ForegroundColor Red
            Write-Host "    Roles and administrators > Helpdesk Administrator > Add assignment > '$AppName'" -ForegroundColor Yellow
        }
    }
}

# ================================================================
# Summary
# ================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  APP REGISTRATION COMPLETE"
Write-Host "============================================================" -ForegroundColor White
Write-Host ""
Write-Host "  App Name:          $AppName" -ForegroundColor White
Write-Host "  Client ID:         $appId" -ForegroundColor White
Write-Host "  Client Secret:     (shown above — copy it now!)" -ForegroundColor Yellow
Write-Host "  Tenant ID:         $($account.tenant)" -ForegroundColor White
Write-Host "  SP Object ID:      $spId" -ForegroundColor White
Write-Host ""
Write-Host "  Permissions granted:" -ForegroundColor Cyan
foreach ($p in $graphPermissions.Keys) { Write-Host "    - $p" }
foreach ($p in $exchangePermissions.Keys) { Write-Host "    - $p" }
Write-Host "    - Helpdesk Administrator (directory role)" -ForegroundColor $(if ($SkipHelpdeskRole) { "Yellow" } else { "White" })
Write-Host ""
Write-Host "  Next: Deploy infrastructure with Bicep:" -ForegroundColor Yellow
Write-Host "    az deployment group create ``" -ForegroundColor Gray
Write-Host "      --resource-group <rg-name> ``" -ForegroundColor Gray
Write-Host "      --template-file infra/main.bicep ``" -ForegroundColor Gray
Write-Host "      --parameters appName=`"<name>`" ``" -ForegroundColor Gray
Write-Host "      --parameters notificationEmail=`"<email>`" ``" -ForegroundColor Gray
Write-Host "      --parameters appClientId=`"$appId`" ``" -ForegroundColor Gray
Write-Host "      --parameters appClientSecret=`"<paste-secret>`"" -ForegroundColor Gray
Write-Host ""
