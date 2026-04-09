<#
.SYNOPSIS
    Grants or revokes shared mailbox permissions via Exchange Online PowerShell.

.DESCRIPTION
    Supports three permission types:
    - Full Access (Add-MailboxPermission / Remove-MailboxPermission)
    - Send As (Add-RecipientPermission / Remove-RecipientPermission)
    - Send on Behalf (Set-Mailbox -GrantSendOnBehalfTo)

    Authenticates to Exchange Online using the Automation Account's
    system-assigned managed identity with Exchange Administrator role.

.PARAMETER SharedMailboxEmail
    The email address of the shared mailbox.

.PARAMETER UserEmail
    The email address of the user to grant/revoke permissions for.

.PARAMETER PermissionType
    One of: "Full Access", "Send As", "Send on Behalf"

.PARAMETER Action
    One of: "Grant", "Revoke"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SharedMailboxEmail,

    [Parameter(Mandatory = $true)]
    [string]$UserEmail,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Full Access", "Send As", "Send on Behalf")]
    [string]$PermissionType,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Grant", "Revoke")]
    [string]$Action
)

$ErrorActionPreference = "Stop"

try {
    # Connect to Exchange Online using managed identity
    Write-Output "Connecting to Exchange Online via managed identity..."
    Connect-ExchangeOnline -ManagedIdentity -Organization (
        (Get-AzContext).Tenant.Id + ".onmicrosoft.com"
    ) -ShowBanner:$false

    Write-Output "Connected. Processing: $Action $PermissionType for $UserEmail on $SharedMailboxEmail"

    switch ($PermissionType) {
        "Full Access" {
            if ($Action -eq "Grant") {
                Add-MailboxPermission -Identity $SharedMailboxEmail `
                    -User $UserEmail `
                    -AccessRights FullAccess `
                    -InheritanceType All `
                    -AutoMapping $true `
                    -Confirm:$false
                Write-Output "SUCCESS: Granted Full Access to $UserEmail on $SharedMailboxEmail"
            }
            else {
                Remove-MailboxPermission -Identity $SharedMailboxEmail `
                    -User $UserEmail `
                    -AccessRights FullAccess `
                    -InheritanceType All `
                    -Confirm:$false
                Write-Output "SUCCESS: Revoked Full Access for $UserEmail on $SharedMailboxEmail"
            }
        }
        "Send As" {
            if ($Action -eq "Grant") {
                Add-RecipientPermission -Identity $SharedMailboxEmail `
                    -Trustee $UserEmail `
                    -AccessRights SendAs `
                    -Confirm:$false
                Write-Output "SUCCESS: Granted Send As to $UserEmail on $SharedMailboxEmail"
            }
            else {
                Remove-RecipientPermission -Identity $SharedMailboxEmail `
                    -Trustee $UserEmail `
                    -AccessRights SendAs `
                    -Confirm:$false
                Write-Output "SUCCESS: Revoked Send As for $UserEmail on $SharedMailboxEmail"
            }
        }
        "Send on Behalf" {
            $mailbox = Get-Mailbox -Identity $SharedMailboxEmail
            $currentDelegates = @($mailbox.GrantSendOnBehalfTo)

            if ($Action -eq "Grant") {
                if ($UserEmail -notin $currentDelegates) {
                    $currentDelegates += $UserEmail
                    Set-Mailbox -Identity $SharedMailboxEmail `
                        -GrantSendOnBehalfTo $currentDelegates `
                        -Confirm:$false
                    Write-Output "SUCCESS: Granted Send on Behalf to $UserEmail on $SharedMailboxEmail"
                }
                else {
                    Write-Output "INFO: $UserEmail already has Send on Behalf on $SharedMailboxEmail"
                }
            }
            else {
                $currentDelegates = $currentDelegates | Where-Object { $_ -ne $UserEmail }
                Set-Mailbox -Identity $SharedMailboxEmail `
                    -GrantSendOnBehalfTo $currentDelegates `
                    -Confirm:$false
                Write-Output "SUCCESS: Revoked Send on Behalf for $UserEmail on $SharedMailboxEmail"
            }
        }
    }
}
catch {
    Write-Error "FAILED: $($_.Exception.Message)"
    throw
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
