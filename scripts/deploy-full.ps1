<#
.SYNOPSIS
    Full end-to-end deployment of the Thread Intent Automation Engine to Azure.

.DESCRIPTION
    Chains together the complete deployment workflow:
      1. Creates (or reuses) the app registration with all permissions
      2. Deploys the Bicep template (infra)
      3. Runs all post-deployment steps (code deploy, roles, runbooks, etc.)

    This is the "run once and done" script for a fresh deployment.

.PARAMETER ResourceGroup
    Azure resource group name. Created if it doesn't exist.

.PARAMETER AppName
    Unique name prefix (3-24 chars). Becomes part of the Function App URL.

.PARAMETER Location
    Azure region. Default: centralus

.PARAMETER NotificationEmail
    Email address for failure notification alerts.

.PARAMETER NotificationMailbox
    UPN of the mailbox to send failure emails from. Defaults to NotificationEmail.

.PARAMETER AppClientId
    (Optional) Existing app registration client ID. If not provided, register-app.ps1
    will create a new one.

.PARAMETER AppClientSecret
    (Optional) Existing client secret. If not provided, register-app.ps1 will create one.

.PARAMETER TestUserUpn
    (Optional) UPN to use for the post-deploy test webhook.

.EXAMPLE
    # Fresh deployment (creates everything):
    .\scripts\deploy-full.ps1 `
        -ResourceGroup "rg-thread-automation" `
        -AppName "contoso-threadauto" `
        -Location "centralus" `
        -NotificationEmail "admin@contoso.com"

.EXAMPLE
    # Reuse existing app registration:
    .\scripts\deploy-full.ps1 `
        -ResourceGroup "rg-thread-automation" `
        -AppName "contoso-threadauto" `
        -NotificationEmail "admin@contoso.com" `
        -AppClientId "b90fe3f0-..." `
        -AppClientSecret "your-secret" `
        -TestUserUpn "testuser@contoso.onmicrosoft.com"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [ValidateLength(3, 24)]
    [string]$AppName,

    [string]$Location = "centralus",

    [Parameter(Mandatory = $true)]
    [string]$NotificationEmail,

    [string]$NotificationMailbox = "",

    [string]$AppClientId = "",

    [string]$AppClientSecret = "",

    [string]$TestUserUpn = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

if (-not $NotificationMailbox) { $NotificationMailbox = $NotificationEmail }

Write-Host ""
Write-Host "================================================================" -ForegroundColor White
Write-Host "  Thread Intent Automation Engine — Full Deployment"
Write-Host "================================================================" -ForegroundColor White
Write-Host ""
Write-Host "  Resource Group:     $ResourceGroup"
Write-Host "  App Name:           $AppName"
Write-Host "  Location:           $Location"
Write-Host "  Notification Email: $NotificationEmail"
Write-Host ""

# Verify Azure CLI
$subInfo = az account show --query "{id:id, tenant:tenantId, name:name}" -o json 2>$null | ConvertFrom-Json
if (-not $subInfo) {
    Write-Host "ERROR: Not logged in. Run 'az login' first." -ForegroundColor Red
    exit 1
}

$SubscriptionId = $subInfo.id
Write-Host "  Subscription:       $($subInfo.name) ($SubscriptionId)"
Write-Host "  Tenant:             $($subInfo.tenant)"
Write-Host ""

# ================================================================
# PHASE 1: App Registration
# ================================================================

if (-not $AppClientId -or -not $AppClientSecret) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  PHASE 1: App Registration"
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  No AppClientId/AppClientSecret provided — creating a new app registration."
    Write-Host ""

    # Run register-app.ps1 and capture the output
    & "$scriptDir\register-app.ps1"

    # After register-app.ps1, prompt for the values
    Write-Host ""
    Write-Host "  Enter the values from the app registration output above:" -ForegroundColor Yellow
    if (-not $AppClientId) {
        $AppClientId = Read-Host "  Client ID"
    }
    if (-not $AppClientSecret) {
        $AppClientSecret = Read-Host "  Client Secret"
    }
} else {
    Write-Host "  Using provided app registration: $AppClientId" -ForegroundColor Gray
}

# ================================================================
# PHASE 2: Resource Group + Bicep Deployment
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  PHASE 2: Infrastructure Deployment (Bicep)"
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Register resource providers (idempotent)
Write-Host "  Registering resource providers..." -ForegroundColor Gray
$providers = @(
    "Microsoft.Web",
    "Microsoft.Storage",
    "Microsoft.KeyVault",
    "Microsoft.Insights",
    "Microsoft.Automation",
    "Microsoft.OperationalInsights"
)
foreach ($p in $providers) {
    az provider register --namespace $p --output none 2>&1 | Out-Null
}
Write-Host "  [OK] Resource providers registered" -ForegroundColor Green

# Create resource group
Write-Host "  Creating resource group: $ResourceGroup ($Location)" -ForegroundColor Gray
az group create --name $ResourceGroup --location $Location --output none 2>&1 | Out-Null
Write-Host "  [OK] Resource group ready" -ForegroundColor Green

# Deploy Bicep
Write-Host ""
Write-Host "  Deploying Bicep template... (this takes 1-2 minutes)" -ForegroundColor Gray

$bicepPath = Join-Path $projectRoot "infra" "main.bicep"
if (-not (Test-Path $bicepPath)) {
    Write-Host "ERROR: Bicep template not found at $bicepPath" -ForegroundColor Red
    exit 1
}

$deployOutput = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $bicepPath `
    --parameters `
        appName="$AppName" `
        location="$Location" `
        notificationEmail="$NotificationEmail" `
        notificationMailbox="$NotificationMailbox" `
        appClientId="$AppClientId" `
        appClientSecret="$AppClientSecret" `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Bicep deployment failed:" -ForegroundColor Red
    Write-Host $deployOutput -ForegroundColor Red
    exit 1
}

$outputs = ($deployOutput | ConvertFrom-Json).properties.outputs
$functionUrl = $outputs.functionAppUrl.value
$consentUrl = $outputs.adminConsentUrl.value

Write-Host ""
Write-Host "  [OK] Bicep deployment complete" -ForegroundColor Green
Write-Host "  Webhook URL: $functionUrl" -ForegroundColor White

# ================================================================
# PHASE 3: Post-Deployment Steps
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  PHASE 3: Post-Deployment Configuration"
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$postDeployArgs = @{
    ResourceGroup  = $ResourceGroup
    AppName        = $AppName
    SubscriptionId = $SubscriptionId
    AppClientId    = $AppClientId
}

if ($TestUserUpn) {
    $postDeployArgs["TestUserUpn"] = $TestUserUpn
}

& "$scriptDir\post-deploy.ps1" @postDeployArgs

# ================================================================
# Final Summary
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT COMPLETE"
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Webhook URL (for Thread intents):" -ForegroundColor Cyan
Write-Host "    $functionUrl" -ForegroundColor White
Write-Host ""
Write-Host "  Admin Consent URL (customer clicks this):" -ForegroundColor Cyan
Write-Host "    $consentUrl" -ForegroundColor White
Write-Host ""
Write-Host "  App Client ID:" -ForegroundColor Cyan
Write-Host "    $AppClientId" -ForegroundColor White
Write-Host ""
Write-Host "  Monitoring:" -ForegroundColor Cyan
Write-Host "    https://portal.azure.com > $ResourceGroup > Application Insights" -ForegroundColor White
Write-Host ""
