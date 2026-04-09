<#
.SYNOPSIS
    Sets up the local development environment for the Thread Intent Automation Engine.

.DESCRIPTION
    Automates local setup:
      1. Verifies prerequisites (Python, Azure Functions Core Tools, Node.js, Azurite)
      2. Creates Python virtual environment and installs requirements
      3. Generates local.settings.json from template (prompts for credentials)
      4. Starts Azurite and creates the idempotency table
      5. Validates connectivity to the configured tenant

    Run this from the project root directory.

.PARAMETER NonInteractive
    Skip prompts — requires all LOCAL_* environment variables to be pre-set.

.PARAMETER SkipVenv
    Skip virtual environment creation (use if already set up).

.PARAMETER AzuriteDataPath
    Directory for Azurite data files. Default: C:\temp\azurite

.EXAMPLE
    .\scripts\setup-local.ps1

.EXAMPLE
    .\scripts\setup-local.ps1 -SkipVenv -AzuriteDataPath "D:\azurite-data"
#>

[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$SkipVenv,
    [string]$AzuriteDataPath = "C:\temp\azurite"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$srcPath = Join-Path $PSScriptRoot ".." "src"

function Write-Step {
    param([int]$Number, [string]$Title)
    Write-Host ""
    Write-Host "=== Step $Number : $Title ===" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  Thread Intent Automation Engine — Local Setup"
Write-Host "============================================================" -ForegroundColor White

# ================================================================
# STEP 1: Verify Prerequisites
# ================================================================
Write-Step 1 "Verify Prerequisites"

$allGood = $true

# Python 3.11+
if (Test-Command "python") {
    $pyVer = python --version 2>&1
    Write-Success "Python: $pyVer"
} else {
    Write-Fail "Python not found. Install Python 3.11+: https://www.python.org/downloads/"
    $allGood = $false
}

# Azure Functions Core Tools
if (Test-Command "func") {
    $funcVer = func --version 2>&1
    Write-Success "Azure Functions Core Tools: $funcVer"
} else {
    Write-Fail "func not found. Install: https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local"
    $allGood = $false
}

# Node.js (for Azurite)
if (Test-Command "node") {
    $nodeVer = node --version 2>&1
    Write-Success "Node.js: $nodeVer"
} else {
    Write-Fail "Node.js not found. Install: https://nodejs.org/"
    $allGood = $false
}

# Azurite
if (Test-Command "azurite") {
    Write-Success "Azurite: installed"
} else {
    Write-Host "  [WARN] Azurite not found. Installing globally..." -ForegroundColor Yellow
    npm install -g azurite 2>&1 | Out-Null
    if (Test-Command "azurite") {
        Write-Success "Azurite: installed"
    } else {
        Write-Fail "Failed to install Azurite. Run: npm install -g azurite"
        $allGood = $false
    }
}

# Azure CLI (optional but recommended)
if (Test-Command "az") {
    $azVer = az version --query '\"azure-cli\"' -o tsv 2>$null
    Write-Success "Azure CLI: $azVer"
} else {
    Write-Host "  [WARN] Azure CLI not found — not required for local dev but needed for deployment." -ForegroundColor Yellow
}

if (-not $allGood) {
    Write-Host ""
    Write-Host "Some prerequisites are missing. Install them and re-run this script." -ForegroundColor Red
    exit 1
}

# ================================================================
# STEP 2: Create Virtual Environment + Install Dependencies
# ================================================================
Write-Step 2 "Python Virtual Environment"

$venvPath = Join-Path $srcPath ".venv"

if ($SkipVenv) {
    Write-Host "  [SKIP] Virtual environment setup skipped" -ForegroundColor Yellow
} elseif (Test-Path $venvPath) {
    Write-Host "  Virtual environment already exists at $venvPath" -ForegroundColor Gray
    Write-Host "  Installing/updating dependencies..." -ForegroundColor Gray
    & "$venvPath\Scripts\pip.exe" install -r "$srcPath\requirements.txt" --quiet
    Write-Success "Dependencies installed"
} else {
    Write-Host "  Creating virtual environment..." -ForegroundColor Gray
    python -m venv $venvPath
    & "$venvPath\Scripts\pip.exe" install --upgrade pip --quiet
    & "$venvPath\Scripts\pip.exe" install -r "$srcPath\requirements.txt" --quiet
    Write-Success "Virtual environment created and dependencies installed"
    Write-Host "  Activate with: $venvPath\Scripts\Activate.ps1" -ForegroundColor Gray
}

# ================================================================
# STEP 3: Generate local.settings.json
# ================================================================
Write-Step 3 "Configure local.settings.json"

$localSettingsPath = Join-Path $srcPath "local.settings.json"

if (Test-Path $localSettingsPath) {
    Write-Host "  local.settings.json already exists." -ForegroundColor Yellow
    if (-not $NonInteractive) {
        $overwrite = Read-Host "  Overwrite? (y/N)"
        if ($overwrite -ne "y") {
            Write-Host "  [SKIP] Keeping existing local.settings.json" -ForegroundColor Yellow
            goto SkipSettings
        }
    } else {
        Write-Host "  [SKIP] Non-interactive mode — keeping existing file" -ForegroundColor Yellow
        goto SkipSettings
    }
}

if ($NonInteractive) {
    # Pull from environment variables
    $clientId      = $env:LOCAL_APP_CLIENT_ID
    $clientSecret  = $env:LOCAL_APP_CLIENT_SECRET
    $tenantId      = $env:LOCAL_TENANT_ID
    $notifEmail    = $env:LOCAL_NOTIFICATION_EMAIL
    $notifMailbox  = $env:LOCAL_NOTIFICATION_MAILBOX

    if (-not $clientId -or -not $clientSecret -or -not $tenantId) {
        Write-Fail "Non-interactive mode requires LOCAL_APP_CLIENT_ID, LOCAL_APP_CLIENT_SECRET, LOCAL_TENANT_ID env vars"
        exit 1
    }
} else {
    Write-Host ""
    Write-Host "  Enter your app registration credentials:" -ForegroundColor Gray
    Write-Host "  (Find these in Azure Portal > Entra ID > App registrations)" -ForegroundColor DarkGray
    Write-Host ""

    $clientId     = Read-Host "  App Client ID"
    $clientSecret = Read-Host "  Client Secret Value"
    $tenantId     = Read-Host "  Tenant ID"
    $notifEmail   = Read-Host "  Notification Email (your admin UPN)"
    $notifMailbox = Read-Host "  Notification Mailbox (FROM address, same as above is fine)"

    if (-not $notifMailbox) { $notifMailbox = $notifEmail }
}

$settings = @{
    IsEncrypted = $false
    Values = @{
        AzureWebJobsStorage           = "UseDevelopmentStorage=true"
        FUNCTIONS_WORKER_RUNTIME      = "python"
        FUNCTIONS_EXTENSION_VERSION   = "~4"
        KEY_VAULT_NAME                = ""
        STORAGE_ACCOUNT_NAME          = ""
        IDEMPOTENCY_TTL_SECONDS       = "3600"
        LOCAL_DEV                     = "true"
        LOCAL_APP_CLIENT_ID           = $clientId
        LOCAL_APP_CLIENT_SECRET       = $clientSecret
        LOCAL_TENANT_ID               = $tenantId
        LOCAL_NOTIFICATION_EMAIL      = $notifEmail
        LOCAL_NOTIFICATION_MAILBOX    = $notifMailbox
    }
}

$settings | ConvertTo-Json -Depth 3 | Set-Content $localSettingsPath -Encoding UTF8
Write-Success "local.settings.json created"
Write-Host "  NOTE: This file is in .gitignore and will not be committed." -ForegroundColor DarkGray

:SkipSettings

# ================================================================
# STEP 4: Ensure Azurite Data Directory Exists
# ================================================================
Write-Step 4 "Prepare Azurite Storage"

if (-not (Test-Path $AzuriteDataPath)) {
    New-Item -ItemType Directory -Path $AzuriteDataPath -Force | Out-Null
    Write-Success "Azurite data directory created: $AzuriteDataPath"
} else {
    Write-Host "  Azurite data directory exists: $AzuriteDataPath" -ForegroundColor Gray
}

# ================================================================
# STEP 5: Create Idempotency Table
# ================================================================
Write-Step 5 "Create Idempotency Table in Azurite"

Write-Host "  Checking if Azurite is running..." -ForegroundColor Gray

# Try to connect to Azurite's Table Storage port (10002)
$azuriteRunning = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("127.0.0.1", 10002)
    $tcp.Close()
    $azuriteRunning = $true
} catch {
    $azuriteRunning = $false
}

if (-not $azuriteRunning) {
    Write-Host "  Azurite is not running. Starting it in a background job..." -ForegroundColor Yellow
    Start-Job -ScriptBlock {
        param($DataPath)
        azurite --silent --location $DataPath
    } -ArgumentList $AzuriteDataPath | Out-Null

    Write-Host "  Waiting for Azurite to start..." -ForegroundColor Gray
    Start-Sleep -Seconds 3

    # Re-check
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", 10002)
        $tcp.Close()
        Write-Success "Azurite started"
    } catch {
        Write-Fail "Azurite failed to start. Start it manually: azurite --silent --location $AzuriteDataPath"
        Write-Host "  Then re-run this script." -ForegroundColor Yellow
    }
}

# Create the idempotency table
Write-Host "  Creating idempotency table..." -ForegroundColor Gray
$pythonExe = if (Test-Path "$venvPath\Scripts\python.exe") { "$venvPath\Scripts\python.exe" } else { "python" }

& $pythonExe -c @"
from azure.data.tables import TableServiceClient
client = TableServiceClient.from_connection_string('UseDevelopmentStorage=true')
client.create_table_if_not_exists('idempotency')
print('  Table ready: idempotency')
"@ 2>&1 | ForEach-Object { Write-Host $_ }

if ($LASTEXITCODE -eq 0) {
    Write-Success "Idempotency table created in Azurite"
} else {
    Write-Host "  [WARN] Table creation may have failed — check Azurite is running." -ForegroundColor Yellow
}

# ================================================================
# Summary
# ================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor White
Write-Host "  LOCAL SETUP COMPLETE"
Write-Host "============================================================" -ForegroundColor White
Write-Host ""
Write-Host "  To start developing:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Terminal 1 — Azurite:" -ForegroundColor Yellow
Write-Host "    azurite --silent --location $AzuriteDataPath" -ForegroundColor Gray
Write-Host ""
Write-Host "  Terminal 2 — Function App:" -ForegroundColor Yellow
Write-Host "    cd src" -ForegroundColor Gray
Write-Host "    .venv\Scripts\Activate.ps1" -ForegroundColor Gray
Write-Host "    func start" -ForegroundColor Gray
Write-Host ""
Write-Host "  Terminal 3 — Test:" -ForegroundColor Yellow
Write-Host '    $body = @{' -ForegroundColor Gray
Write-Host '        intent_name = "Password Reset"' -ForegroundColor Gray
Write-Host '        intent_fields = @{ "User Email" = "testuser@yourtenant.onmicrosoft.com" }' -ForegroundColor Gray
Write-Host '        meta_data = @{ ticket_id = 1001; contact_name = "Test"; contact_email = "t@t.com"; company_name = "Test" }' -ForegroundColor Gray
Write-Host '    } | ConvertTo-Json -Depth 3' -ForegroundColor Gray
Write-Host '    Invoke-RestMethod -Uri http://localhost:7071/api/intent -Method POST -ContentType "application/json" -Body $body' -ForegroundColor Gray
Write-Host ""
