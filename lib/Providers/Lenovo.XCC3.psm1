<#
.SYNOPSIS
    Lenovo ThinkAgile HX650 V3 (XCC3) provider -- wrappers over Lenovo `OneCLI`.

    STATUS: interface defined; hardware-specific attribute names are UNCONFIRMED.
    The BMC Fleet Automation repo marks XCC3 baseline as IN DESIGN with a BLOCKING
    open question on syslog attribute mapping. The same caution applies here:

    Do NOT trust these attribute paths until verified against live hardware with:
        onecli config show BMC.RemoteAlertRecipientMethod_1

    Checks to carry over from iDRAC lessons (unconfirmed on XCC3):
      - Is there a master alert-enable switch (iDRAC.IPMILan.AlertEnable equivalent)?
      - Are XCC3 enum attributes string-based (Enabled/Disabled) or integer (1/0)?
      - Does onecli have silent-partial-failure like racadm eventfilters?
        Inspect output text, not just exit code, until proven otherwise.
#>

Set-StrictMode -Version Latest

function Invoke-OneCli {
    <#
        Run a OneCLI command against an XCC target and return a structured result.
        OneCLI takes remote host/creds via --bmc-username/--bmc-password/--bmc.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string[]]$Args
    )
    $user = $Credential.UserName
    $pass = ConvertTo-PlainText -Secure $Credential.Password
    try {
        $remote = @('--bmc', "$user`:$pass@$IP")
        $full   = $Args + $remote
        $out    = & onecli @full 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($out | Out-String).TrimEnd()
            HasError = ($out | Out-String) -match 'Error|Failed|Invalid|not supported'
        }
    }
    finally { $pass = $null }
}

function Get-XCC3Info {
    <# Read-only inventory -- safe for the audit stage. #>
    param([string]$IP, [pscredential]$Credential)
    $inv = Invoke-OneCli -IP $IP -Credential $Credential -Args @('inventory', 'getinfor')
    return [pscustomobject]@{
        Inventory = $inv.Output
        Reachable = -not $inv.HasError
    }
}

function Set-XCC3BootToVirtualMedia {
    <#
        Mount install ISO via XCC virtual media and set one-time boot.
        TODO(live-hardware): confirm the OneCLI storage/rdmount + boot-order verbs
        for XCC3. Placeholder attribute paths below MUST be verified before use.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$IsoUrl
    )
    Write-Warning "Set-XCC3BootToVirtualMedia: attribute paths UNCONFIRMED on live XCC3 hardware."
    # Expected shape (verify): mount remote media, then set boot order to CD/DVD once.
    $boot = Invoke-OneCli -IP $IP -Credential $Credential -Args @('config', 'set', 'BootOrder.BootOrder', 'CD/DVD Rom')
    return [pscustomobject]@{
        Ok     = -not $boot.HasError
        Detail = $boot.Output
        Note   = 'Verify OneCLI virtual-media + boot-order syntax against live XCC3 before relying on this.'
    }
}

Export-ModuleMember -Function Invoke-OneCli, Get-XCC3Info, Set-XCC3BootToVirtualMedia
