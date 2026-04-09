<#
.SYNOPSIS
    Runs all post-Bicep-deployment steps for the Thread Intent Automation Engine.

.DESCRIPTION
    After the Bicep template deploys infrastructure, this script completes setup:
      1. Deploys Function App code via func CLI
      2. Grants Storage Table Data Contributor to Function App managed identity
      3. Uploads and publishes PowerShell runbooks to the Automation Account
      4. Sets Automation Account environment variables on the Function App
      5. Assigns Exchange Administrator role to the Automation Account managed identity
      6. Assigns Helpdesk Administrator role to the app registration service principal
      7. Opens the admin consent URL in the default browser
      8. (Optional) Adds a temporary IP rule for testing and sends a test webhook

    Run this from the project root directory.

.PARAMETER ResourceGroup
    Azure resource group name containing the deployed resources.

.PARAMETER AppName
    The appName used during Bicep deployment (resource name prefix).

.PARAMETER SubscriptionId
    Azure subscription ID where resources are deployed.

.PARAMETER AppClientId
    Client ID of the multi-tenant app registration.

.PARAMETER TestUserUpn
    (Optional) UPN for the test webhook. If provided, runs a test at the end.

.PARAMETER SkipCodeDeploy
    (Optional) Skip Function App code deployment (if already deployed).

.PARAMETER SkipAdminConsent
    (Optional) Skip opening the admin consent URL in the browser.

.EXAMPLE
    .\scripts\post-deploy.ps1 `
        -ResourceGroup "rg-thread-automation-test" `
        -AppName "marktest-threadauto" `
        -SubscriptionId "your-sub-id" `
        -AppClientId "b90fe3f0-416d-4b5f-a4c0-fd1b3a65a1e0" `
        -TestUserUpn "testuser@markandrewmarquez.onmicrosoft.com"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$AppClientId,

    [string]$TestUserUpn = "",

    [switch]$SkipCodeDeploy,

    [switch]$SkipAdminConsent
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ---------- Derived resource names (must match main.bicep naming) ----------
$FunctionAppName    = "$AppName-func"
$StorageAccountName = $null  # Resolved dynamically below
$AutomationAccount  = "$AppName-auto"
$KeyVaultName       = $null  # Resolved dynamically below

# ---------- Well-known Azure AD role template IDs ----------
$ExchangeAdminRoleId   = "29232cdf-9323-42fd-ade2-1d097af3e4de"
$HelpdeskAdminRoleId   = "729827e3-9c14-49f7-bb1b-9608f156bbb8"

# ---------- Helper ----------
function Write-Step {
    param([int]$Number, [string]$Title)
    Write-Host ""
    Write-Host "=== Step $Number : $Title ===" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "  [SKIP] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

# ---------- Pre-flight checks ----------

Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  Thread Intent Automation Engine — Post-Deployment Setup"
Write-Host "============================================================" -ForegroundColor White
Write-Host ""
Write-Host "Resource Group:    $ResourceGroup"
Write-Host "App Name:          $AppName"
Write-Host "Function App:      $FunctionAppName"
Write-Host "Subscription:      $SubscriptionId"
Write-Host "App Client ID:     $AppClientId"
Write-Host ""

# Verify Azure CLI is logged in and set to the right subscription
Write-Host "Verifying Azure CLI session..." -ForegroundColor Gray
az account set --subscription $SubscriptionId 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to set subscription. Run 'az login' first." -ForegroundColor Red
    exit 1
}
$currentSub = az account show --query "name" -o tsv
Write-Host "  Active subscription: $currentSub"

# Resolve the actual Storage Account name (Bicep uses uniqueString)
Write-Host "Resolving resource names from deployment..." -ForegroundColor Gray
$resources = az resource list --resource-group $ResourceGroup --query "[].{name:name, type:type}" -o json | ConvertFrom-Json

$StorageAccountName = ($resources | Where-Object { $_.type -eq "Microsoft.Storage/storageAccounts" }).name
$KeyVaultName = ($resources | Where-Object { $_.type -eq "Microsoft.KeyVault/vaults" }).name
$AppInsightsName = ($resources | Where-Object { $_.type -eq "Microsoft.Insights/components" }).name

if (-not $StorageAccountName) {
    Write-Host "ERROR: Could not find Storage Account in $ResourceGroup" -ForegroundColor Red
    exit 1
}

Write-Host "  Storage Account:   $StorageAccountName"
Write-Host "  Key Vault:         $KeyVaultName"
Write-Host "  App Insights:      $AppInsightsName"
Write-Host "  Automation Acct:   $AutomationAccount"

# Get tenant ID
$TenantId = az account show --query "tenantId" -o tsv

# ================================================================
# STEP 1: Deploy Function App Code
# ================================================================
Write-Step 1 "Deploy Function App Code"

if ($SkipCodeDeploy) {
    Write-Skip "Code deployment skipped (flag set)"
} else {
    $srcPath = Join-Path $PSScriptRoot ".." "src"
    if (-not (Test-Path $srcPath)) {
        Write-Fail "src/ directory not found at $srcPath"
        Write-Host "  Ensure you are running from the project root." -ForegroundColor Yellow
    } else {
        Push-Location $srcPath
        try {
            Write-Host "  Publishing Function App code..." -ForegroundColor Gray
            func azure functionapp publish $FunctionAppName --python 2>&1 | ForEach-Object {
                Write-Host "    $_" -ForegroundColor DarkGray
            }
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Function App code deployed to $FunctionAppName"
            } else {
                Write-Fail "Code deployment failed (exit code $LASTEXITCODE)"
            }
        } finally {
            Pop-Location
        }
    }
}

# ================================================================
# STEP 2: Grant Storage Table Data Contributor to Function App MI
# ================================================================
Write-Step 2 "Grant Storage Table Data Contributor Role"

$funcPrincipalId = az functionapp identity show `
    --resource-group $ResourceGroup `
    --name $FunctionAppName `
    --query "principalId" -o tsv

if (-not $funcPrincipalId) {
    Write-Fail "Could not retrieve Function App managed identity principal ID"
} else {
    $storageId = az storage account show `
        --resource-group $ResourceGroup `
        --name $StorageAccountName `
        --query "id" -o tsv

    # Check if assignment already exists
    $existing = az role assignment list `
        --assignee $funcPrincipalId `
        --role "Storage Table Data Contributor" `
        --scope $storageId `
        --query "length(@)" -o tsv

    if ([int]$existing -gt 0) {
        Write-Skip "Role already assigned"
    } else {
        az role assignment create `
            --assignee $funcPrincipalId `
            --role "Storage Table Data Contributor" `
            --scope $storageId `
            --output none

        if ($LASTEXITCODE -eq 0) {
            Write-Success "Storage Table Data Contributor granted to Function App MI"
        } else {
            Write-Fail "Role assignment failed"
        }
    }
}

# ================================================================
# STEP 3: Upload and Publish Runbooks
# ================================================================
Write-Step 3 "Upload and Publish Runbooks"

$runbooksPath = Join-Path $PSScriptRoot ".." "runbooks"
if (-not (Test-Path $runbooksPath)) {
    Write-Fail "runbooks/ directory not found at $runbooksPath"
} else {
    $runbookFiles = Get-ChildItem -Path $runbooksPath -Filter "*.ps1"
    foreach ($file in $runbookFiles) {
        $runbookName = $file.BaseName
        Write-Host "  Uploading: $runbookName" -ForegroundColor Gray

        az automation runbook replace-content `
            --resource-group $ResourceGroup `
            --automation-account-name $AutomationAccount `
            --name $runbookName `
            --content "@$($file.FullName)" `
            --output none 2>&1 | Out-Null

        az automation runbook publish `
            --resource-group $ResourceGroup `
            --automation-account-name $AutomationAccount `
            --name $runbookName `
            --output none 2>&1 | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Success "$runbookName uploaded and published"
        } else {
            Write-Fail "$runbookName may need manual upload/publish"
        }
    }
}

# ================================================================
# STEP 4: Set Automation Account Env Vars on Function App
# ================================================================
Write-Step 4 "Configure Automation Account Environment Variables"

az functionapp config appsettings set `
    --resource-group $ResourceGroup `
    --name $FunctionAppName `
    --settings `
        AZURE_SUBSCRIPTION_ID="$SubscriptionId" `
        AZURE_RESOURCE_GROUP="$ResourceGroup" `
        AUTOMATION_ACCOUNT_NAME="$AutomationAccount" `
    --output none

if ($LASTEXITCODE -eq 0) {
    Write-Success "Automation environment variables set on Function App"
} else {
    Write-Fail "Failed to set environment variables"
}

# ================================================================
# STEP 5: Assign Exchange Administrator to Automation Account MI
# ================================================================
Write-Step 5 "Assign Exchange Administrator Role to Automation Account MI"

$automationPrincipalId = az automation account show `
    --resource-group $ResourceGroup `
    --name $AutomationAccount `
    --query "identity.principalId" -o tsv

if (-not $automationPrincipalId) {
    Write-Fail "Could not retrieve Automation Account managed identity"
} else {
    # Check if already assigned
    $existingRole = az rest --method GET `
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$automationPrincipalId' and roleDefinitionId eq '$ExchangeAdminRoleId'" `
        --query "value | length(@)" -o tsv 2>$null

    if ($existingRole -and [int]$existingRole -gt 0) {
        Write-Skip "Exchange Administrator already assigned"
    } else {
        $roleBody = @{
            principalId = $automationPrincipalId
            roleDefinitionId = $ExchangeAdminRoleId
            directoryScopeId = "/"
        } | ConvertTo-Json -Compress

        az rest --method POST `
            --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" `
            --headers "Content-Type=application/json" `
            --body $roleBody `
            --output none 2>&1 | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Success "Exchange Administrator assigned to Automation Account MI"
        } else {
            Write-Fail "Role assignment failed — assign manually in Entra ID > Roles and administrators"
            Write-Host "    Search for 'Exchange Administrator' and add the Automation Account." -ForegroundColor Yellow
        }
    }
}

# ================================================================
# STEP 6: Assign Helpdesk Administrator to App Registration SP
# ================================================================
Write-Step 6 "Assign Helpdesk Administrator Role to App Registration SP"

# Get the service principal object ID for the app registration
$spObjectId = az ad sp show --id $AppClientId --query "id" -o tsv 2>$null

if (-not $spObjectId) {
    Write-Fail "Service principal not found for client ID $AppClientId"
    Write-Host "    Ensure the app registration exists and has a service principal in this tenant." -ForegroundColor Yellow
} else {
    $existingRole = az rest --method GET `
        --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$spObjectId' and roleDefinitionId eq '$HelpdeskAdminRoleId'" `
        --query "value | length(@)" -o tsv 2>$null

    if ($existingRole -and [int]$existingRole -gt 0) {
        Write-Skip "Helpdesk Administrator already assigned"
    } else {
        $roleBody = @{
            principalId = $spObjectId
            roleDefinitionId = $HelpdeskAdminRoleId
            directoryScopeId = "/"
        } | ConvertTo-Json -Compress

        az rest --method POST `
            --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" `
            --headers "Content-Type=application/json" `
            --body $roleBody `
            --output none 2>&1 | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Success "Helpdesk Administrator assigned to app registration SP"
        } else {
            Write-Fail "Role assignment failed — assign manually in Entra ID > Roles and administrators"
            Write-Host "    Search for 'Helpdesk Administrator' and add 'Thread Intent Automation Engine'." -ForegroundColor Yellow
        }
    }
}

# ================================================================
# STEP 7: Open Admin Consent URL
# ================================================================
Write-Step 7 "Admin Consent"

$consentUrl = "https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$AppClientId&redirect_uri=https://portal.azure.com"

if ($SkipAdminConsent) {
    Write-Skip "Admin consent skipped (flag set)"
    Write-Host "  Consent URL: $consentUrl" -ForegroundColor Gray
} else {
    Write-Host "  Opening admin consent URL in browser..." -ForegroundColor Gray
    Write-Host "  URL: $consentUrl" -ForegroundColor DarkGray
    Start-Process $consentUrl
    Write-Success "Admin consent URL opened — click Accept in the browser"
}

# ================================================================
# STEP 8: (Optional) Test Webhook
# ================================================================
if ($TestUserUpn) {
    Write-Step 8 "Test Webhook"

    # Get public IP
    Write-Host "  Detecting your public IP..." -ForegroundColor Gray
    $myIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5) 2>$null

    if (-not $myIp) {
        Write-Fail "Could not detect public IP — skipping test"
    } else {
        Write-Host "  Your IP: $myIp" -ForegroundColor Gray

        # Add temporary IP rule
        Write-Host "  Adding temporary IP access rule..." -ForegroundColor Gray
        az functionapp config access-restriction add `
            --resource-group $ResourceGroup `
            --name $FunctionAppName `
            --priority 90 `
            --rule-name "PostDeployTest" `
            --action Allow `
            --ip-address "$myIp/32" `
            --output none 2>&1 | Out-Null

        # Wait for propagation
        Start-Sleep -Seconds 10

        # Build test payload
        $webhookUrl = "https://$FunctionAppName.azurewebsites.net/api/intent"
        $testBody = @{
            intent_name = "Password Reset"
            intent_fields = @{
                "User Email" = $TestUserUpn
                "Force Change on Login" = "Yes"
            }
            meta_data = @{
                ticket_id = 99999
                contact_name = "Post-Deploy Test"
                contact_email = "test@test.com"
                company_name = "Deployment Test"
            }
        } | ConvertTo-Json -Depth 3

        Write-Host "  Sending test webhook to $webhookUrl ..." -ForegroundColor Gray
        try {
            $response = Invoke-RestMethod -Uri $webhookUrl `
                -Method POST `
                -ContentType "application/json" `
                -Body $testBody `
                -TimeoutSec 60

            Write-Host "  Response:" -ForegroundColor Gray
            $response | ConvertTo-Json -Depth 3 | Write-Host -ForegroundColor DarkGray

            if ($response.status -eq "success") {
                Write-Success "Test webhook succeeded!"
            } else {
                Write-Fail "Test returned status: $($response.status)"
                if ($response.error) {
                    Write-Host "    Error: $($response.error)" -ForegroundColor Yellow
                }
            }
        } catch {
            Write-Fail "Test webhook failed: $($_.Exception.Message)"
        }

        # Remove temporary IP rule
        Write-Host "  Removing temporary IP access rule..." -ForegroundColor Gray
        az functionapp config access-restriction remove `
            --resource-group $ResourceGroup `
            --name $FunctionAppName `
            --rule-name "PostDeployTest" `
            --output none 2>&1 | Out-Null

        Write-Success "Temporary IP rule removed"
    }
}

# ================================================================
# Summary
# ================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  POST-DEPLOYMENT COMPLETE"
Write-Host "============================================================" -ForegroundColor White
Write-Host ""
Write-Host "Webhook URL:" -ForegroundColor Cyan
Write-Host "  https://$FunctionAppName.azurewebsites.net/api/intent"
Write-Host ""
Write-Host "Admin Consent URL:" -ForegroundColor Cyan
Write-Host "  $consentUrl"
Write-Host ""
Write-Host "App Insights:" -ForegroundColor Cyan
Write-Host "  https://portal.azure.com/#resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/components/$AppInsightsName/overview"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Verify admin consent was accepted (green checkmarks in API permissions)"
Write-Host "  2. Share the Webhook URL with the MSP for Thread intent configuration"
Write-Host "  3. Monitor Application Insights for incoming webhooks"
Write-Host ""
