// Automation Account — executes Exchange Online PowerShell operations
// Managed identity with Exchange Administrator role for EXO cmdlets
param automationAccountName string
param location string

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Free'
    }
    publicNetworkAccess: true
  }
}

// ---------- PowerShell Modules ----------
// ExchangeOnlineManagement module for EXO cmdlets

resource exoModule 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automationAccount
  name: 'ExchangeOnlineManagement'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/ExchangeOnlineManagement'
    }
  }
}

// ---------- Runbooks ----------

resource setMailboxPermissionRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Set-SharedMailboxPermission'
  location: location
  properties: {
    runbookType: 'PowerShell'
    logProgress: true
    logVerbose: false
    description: 'Grants or revokes shared mailbox permissions (Full Access, Send As, Send on Behalf).'
  }
  dependsOn: [exoModule]
}

resource convertMailboxRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Convert-ToSharedMailbox'
  location: location
  properties: {
    runbookType: 'PowerShell'
    logProgress: true
    logVerbose: false
    description: 'Converts a user mailbox to a shared mailbox (used during offboarding).'
  }
  dependsOn: [exoModule]
}

output automationAccountName string = automationAccount.name
output automationAccountId string = automationAccount.id
output principalId string = automationAccount.identity.principalId
