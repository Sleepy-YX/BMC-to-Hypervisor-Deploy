<#
.SYNOPSIS
    Dell iDRAC provider -- thin wrappers over `racadm` for the deployment pipeline.

    The BMC baseline (DNS/NTP/Timezone/Syslog/Alerts) is already production-ready
    in the BMC Fleet Automation repo (Set-iDRAC-NTP-Syslog-Alerts.ps1). This module
    covers the *deployment* verbs the pipeline needs on top of that: firmware,
    BIOS/RAID, and virtual-media boot control.

    Hard-won racadm rules (carried over -- do not relearn):
      1. Pass --nocertwarn on EVERY call, or cert banners break output parsing.
      2. Some commands (e.g. eventfilters) return exit 0 while partially failing.
         Inspect output TEXT for failure strings, never trust exit code alone.
      3. Enum attributes often take string values (Enabled/Disabled), not 1/0.
#>

Set-StrictMode -Version Latest

function Invoke-Racadm {
    <#
        Run a racadm command against a host and return a structured result.
        Credential is decrypted only for the child process invocation.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string[]]$Args
    )
    $user = $Credential.UserName
    $pass = ConvertTo-PlainText -Secure $Credential.Password
    try {
        $full = @('-r', $IP, '-u', $user, '-p', $pass, '--nocertwarn') + $Args
        $out  = & racadm @full 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($out | Out-String).TrimEnd()
            # Rule 2: surface a text-level failure signal for callers to check.
            HasError = ($out | Out-String) -match 'ERROR|RAC\d{4}|failed|Unable'
        }
    }
    finally { $pass = $null }
}

function Get-iDRACInfo {
    <# Read-only: firmware version, model, service tag. Safe for the audit stage. #>
    param([string]$IP, [pscredential]$Credential)
    $fw    = Invoke-Racadm -IP $IP -Credential $Credential -Args @('get', 'iDRAC.Info.Version')
    $model = Invoke-Racadm -IP $IP -Credential $Credential -Args @('get', 'System.ServerInfo')
    return [pscustomobject]@{
        Firmware = $fw.Output
        System   = $model.Output
        Reachable = -not $fw.HasError
    }
}

function Set-iDRACBootToVirtualMedia {
    <#
        Set one-time boot to virtual CD and (re)mount the install ISO from a share.
        Requires an SMB/NFS/HTTP-reachable ISO path in $IsoUrl.
        TODO(live-hardware): confirm remoteimage attach syntax on target iDRAC gen.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$IsoUrl
    )
    # Attach remote ISO as virtual media, then set one-time boot to VCD-DVD.
    $attach = Invoke-Racadm -IP $IP -Credential $Credential -Args @('remoteimage', '-c', '-l', $IsoUrl)
    $boot   = Invoke-Racadm -IP $IP -Credential $Credential -Args @('set', 'iDRAC.ServerBoot.FirstBootDevice', 'VCD-DVD')
    $once   = Invoke-Racadm -IP $IP -Credential $Credential -Args @('set', 'iDRAC.ServerBoot.BootOnce', 'Enabled')
    return [pscustomobject]@{
        Ok      = -not ($attach.HasError -or $boot.HasError -or $once.HasError)
        Detail  = @($attach.Output, $boot.Output, $once.Output) -join "`n"
    }
}

function Restart-iDRACHost {
    <# Power-cycle the server (graceful if possible) to begin the install boot. #>
    param([string]$IP, [pscredential]$Credential, [switch]$Hard)
    $verb = if ($Hard) { 'hardreset' } else { 'powercycle' }
    return Invoke-Racadm -IP $IP -Credential $Credential -Args @('serveraction', $verb)
}

Export-ModuleMember -Function Invoke-Racadm, Get-iDRACInfo, Set-iDRACBootToVirtualMedia, Restart-iDRACHost
