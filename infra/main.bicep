// ============================================================================
// Thread Intent Automation Engine — Main Deployment Template
// Deploys: Function App + Storage + Key Vault + App Insights + Automation Account
// ============================================================================

targetScope = 'resourceGroup'

// ---------- Parameters (Customer inputs during install) ----------

@description('Unique name prefix for all resources. Becomes part of the Function App URL.')
@minLength(3)
@maxLength(24)
param appName string

@description('Azure region for deployment. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Email address for failure notification emails.')
param notificationEmail string

@description('UPN of the mailbox to send failure emails from (e.g., noreply@contoso.com). If blank, notifications are logged only.')
param notificationMailbox string = ''

@description('Client ID of the multi-tenant app registration (provided by the app publisher).')
param appClientId string

@secure()
@description('Client secret of the multi-tenant app registration (provided by the app publisher).')
param appClientSecret string

@description('URL of the centrally hosted Function App code package (ZIP).')
param packageUrl string = ''

// ---------- Variables ----------

var tenantId = tenant().tenantId
var uniqueSuffix = uniqueString(resourceGroup().id, appName)
var functionAppName = '${appName}-func'
var storageAccountName = toLower(replace('${take(appName, 10)}${uniqueSuffix}sa', '-', ''))
var keyVaultName = '${take(appName, 14)}-kv-${take(uniqueSuffix, 4)}'
var appInsightsName = '${appName}-insights'
var automationAccountName = '${appName}-auto'
var hostingPlanName = '${appName}-plan'

// Thread's 6 static outbound IP addresses
var threadIpAddresses = [
  '52.70.34.233'
  '3.221.147.202'
  '54.152.112.100'
  '34.226.184.103'
  '52.23.25.207'
  '3.220.225.111'
]

// ---------- Storage Account ----------

module storage 'modules/storage.bicep' = {
  name: 'storage-deployment'
  params: {
    storageAccountName: take(storageAccountName, 24)
    location: location
  }
}

// ---------- Application Insights ----------

module appInsights 'modules/appInsights.bicep' = {
  name: 'appinsights-deployment'
  params: {
    appInsightsName: appInsightsName
    location: location
  }
}

// ---------- Key Vault ----------

module keyVault 'modules/keyVault.bicep' = {
  name: 'keyvault-deployment'
  params: {
    keyVaultName: keyVaultName
    location: location
    tenantId: tenantId
    appClientId: appClientId
    appClientSecret: appClientSecret
    notificationEmail: notificationEmail
    notificationMailbox: notificationMailbox
    functionAppPrincipalId: functionApp.outputs.principalId
  }
}

// ---------- Function App ----------

module functionApp 'modules/functionApp.bicep' = {
  name: 'functionapp-deployment'
  params: {
    functionAppName: functionAppName
    hostingPlanName: hostingPlanName
    location: location
    storageAccountName: storage.outputs.storageAccountName
    storageAccountKey: storage.outputs.storageAccountKey
    appInsightsConnectionString: appInsights.outputs.connectionString
    appInsightsInstrumentationKey: appInsights.outputs.instrumentationKey
    keyVaultName: keyVaultName
    threadIpAddresses: threadIpAddresses
    packageUrl: packageUrl
  }
}

// ---------- Automation Account ----------

module automationAccount 'modules/automationAccount.bicep' = {
  name: 'automation-deployment'
  params: {
    automationAccountName: automationAccountName
    location: location
  }
}

// ---------- Outputs ----------

@description('The Function App webhook URL for Thread intent automation.')
output functionAppUrl string = 'https://${functionApp.outputs.defaultHostName}/api/intent'

@description('Admin consent URL — customer clicks this to grant Graph API permissions.')
output adminConsentUrl string = 'https://login.microsoftonline.com/${tenantId}/adminconsent?client_id=${appClientId}&redirect_uri=https://portal.azure.com'

@description('The tenant ID where resources were deployed.')
output tenantId string = tenantId

@description('Function App name (for management reference).')
output functionAppName string = functionAppName

@description('Key Vault name (for secret management).')
output keyVaultName string = keyVaultName

@description('Application Insights name (for monitoring).')
output appInsightsName string = appInsightsName

@description('Automation Account name (for runbook management).')
output automationAccountName string = automationAccountName
