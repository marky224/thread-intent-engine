<#
.SYNOPSIS
    Converts a user mailbox to a shared mailbox.

.DESCRIPTION
    Used as part of the User Offboarding intent when "Convert to Shared Mailbox"
    is set to Yes. Authenticates via the Automation Account's managed identity.

.PARAMETER UserPrincipalName
    The UPN of the user whose mailbox should be converted.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$UserPrincipalName
)

$ErrorActionPreference = "Stop"

try {
    # Connect to Exchange Online using managed identity
    Write-Output "Connecting to Exchange Online via managed identity..."
    Connect-ExchangeOnline -ManagedIdentity -Organization (
        (Get-AzContext).Tenant.Id + ".onmicrosoft.com"
    ) -ShowBanner:$false

    Write-Output "Connected. Converting mailbox for: $UserPrincipalName"

    # Verify the mailbox exists and get current type
    $mailbox = Get-Mailbox -Identity $UserPrincipalName -ErrorAction Stop

    if ($mailbox.RecipientTypeDetails -eq "SharedMailbox") {
        Write-Output "INFO: Mailbox for $UserPrincipalName is already a shared mailbox. No action needed."
        return
    }

    # Convert to shared mailbox
    Set-Mailbox -Identity $UserPrincipalName -Type Shared -Confirm:$false
    Write-Output "SUCCESS: Converted mailbox for $UserPrincipalName to shared mailbox."

    # Verify conversion
    $updated = Get-Mailbox -Identity $UserPrincipalName
    Write-Output "Verification: RecipientTypeDetails = $($updated.RecipientTypeDetails)"
}
catch {
    Write-Error "FAILED: $($_.Exception.Message)"
    throw
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
