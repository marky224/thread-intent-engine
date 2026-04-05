// Function App — webhook receiver and automation dispatcher
// Consumption plan, Python runtime, IP-restricted to Thread's outbound IPs
param functionAppName string
param hostingPlanName string
param location string
param storageAccountName string
@secure()
param storageAccountKey string
param appInsightsConnectionString string
param appInsightsInstrumentationKey string
param keyVaultName string
param threadIpAddresses array
param packageUrl string

// ---------- Consumption Plan ----------

resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: hostingPlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
    size: 'Y1'
    family: 'Y'
    capacity: 0
  }
  kind: 'functionapp'
  properties: {
    reserved: true // Required for Linux
  }
}

// ---------- Function App ----------

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    reserved: true
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      pythonVersion: '3.11'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageAccountKey};EndpointSuffix=core.windows.net'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsightsInstrumentationKey
        }
        {
          name: 'KEY_VAULT_NAME'
          value: keyVaultName
        }
        {
          name: 'STORAGE_ACCOUNT_NAME'
          value: storageAccountName
        }
        {
          name: 'IDEMPOTENCY_TTL_SECONDS'
          value: '3600'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: packageUrl != '' ? packageUrl : '0'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: packageUrl != '' ? 'false' : 'true'
        }
      ]
      // IP access restrictions — only Thread's outbound IPs + Azure portal
      ipSecurityRestrictions: [
        {
          ipAddress: '${threadIpAddresses[0]}/32'
          action: 'Allow'
          priority: 100
          name: 'Thread-IP-1'
          description: 'Thread outbound IP ${threadIpAddresses[0]}'
        }
        {
          ipAddress: '${threadIpAddresses[1]}/32'
          action: 'Allow'
          priority: 101
          name: 'Thread-IP-2'
          description: 'Thread outbound IP ${threadIpAddresses[1]}'
        }
        {
          ipAddress: '${threadIpAddresses[2]}/32'
          action: 'Allow'
          priority: 102
          name: 'Thread-IP-3'
          description: 'Thread outbound IP ${threadIpAddresses[2]}'
        }
        {
          ipAddress: '${threadIpAddresses[3]}/32'
          action: 'Allow'
          priority: 103
          name: 'Thread-IP-4'
          description: 'Thread outbound IP ${threadIpAddresses[3]}'
        }
        {
          ipAddress: '${threadIpAddresses[4]}/32'
          action: 'Allow'
          priority: 104
          name: 'Thread-IP-5'
          description: 'Thread outbound IP ${threadIpAddresses[4]}'
        }
        {
          ipAddress: '${threadIpAddresses[5]}/32'
          action: 'Allow'
          priority: 105
          name: 'Thread-IP-6'
          description: 'Thread outbound IP ${threadIpAddresses[5]}'
        }
        {
          ipAddress: 'Any'
          action: 'Deny'
          priority: 2147483647
          name: 'Deny-All'
          description: 'Deny all other traffic'
        }
      ]
      ipSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictions: [
        {
          ipAddress: 'Any'
          action: 'Allow'
          priority: 100
          name: 'Allow-SCM'
          description: 'Allow SCM access for deployments'
        }
      ]
    }
  }
}

output functionAppId string = functionApp.id
output defaultHostName string = functionApp.properties.defaultHostName
output principalId string = functionApp.identity.principalId
output functionAppName string = functionApp.name
