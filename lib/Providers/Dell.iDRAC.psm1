<#
.SYNOPSIS
    Dell iDRAC provider -- racadm wrappers for the deployment pipeline.

    The BMC baseline logic here is PORTED VERBATIM (attribute names, values,
    ordering, and gotcha-handling) from the production-tested scripts:
        platforms\dell\Set-iDRAC-NTP-Syslog-Alerts.ps1   (config)
        platforms\dell\Test-iDRACReadiness.ps1           (read-only audit)
    Those two remain the standalone source of truth; this module exposes the same
    proven operations as composable per-host functions so the orchestrator's
    bmc-baseline and readiness stages run identical logic. Do not diverge the
    attribute names/values here from those scripts without re-confirming on hardware.

    Hard-won racadm rules (confirmed on test host 10.10.10.31, fw 7.20.60.50):
      1. --nocertwarn on EVERY call, or cert banners break output parsing.
      2. eventfilters returns exit 0 while partially failing -- inspect output TEXT
         for 'failed', report PARTIAL separately. Never trust exit code alone.
      3. Enum attributes are string-based (Enabled/Disabled) EXCEPT NTPEnable which
         is 1/0 -- confirmed per-attribute, do not assume uniformity.
      4. SecureSysLogEnable throws RAC1019 unless a CA cert (type 12) is uploaded
         FIRST; cert upload can restart the cert store, so pause ~5s before enable.
      5. idrac.IPMILan.AlertEnable is the master switch -- no alert fires without it.
#>

Set-StrictMode -Version Latest

# --- Confirmed attribute names (single source of truth for the pipeline) ------
$script:iDRAC = @{
    Dns1            = 'idrac.IPv4.DNS1'
    Dns2            = 'idrac.IPv4.DNS2'
    NtpEnable       = 'idrac.NTPConfigGroup.NTPEnable'   # value: 1/0 (NOT Enabled/Disabled)
    Ntp1            = 'idrac.NTPConfigGroup.NTP1'
    Ntp2            = 'idrac.NTPConfigGroup.NTP2'
    Timezone        = 'idrac.Time.Timezone'              # IANA string, e.g. Asia/Singapore
    AlertMaster     = 'idrac.IPMILan.AlertEnable'        # value: Enabled/Disabled (master switch)
    SysLogEnable    = 'idrac.SysLog.SysLogEnable'        # Basic mode (we Disable it)
    SysLogServer1   = 'idrac.SysLog.Server1'
    SecureEnable    = 'idrac.SysLog.SecureSysLogEnable'  # value: Enabled/Disabled
    SecureServer1   = 'idrac.SysLog.SecureServer1'       # single target only (platform limit)
}
# Alert categories/severities/notifications -- as in the proven eventfilters loop.
$script:AlertCategories   = @('idrac.alert.system','idrac.alert.storage','idrac.alert.updates','idrac.alert.audit','idrac.alert.config')
$script:AlertSeverities   = @('critical','warning')
$script:AlertNotifications = 'snmp,remotesyslog'

function Get-iDRACAttributeMap { return $script:iDRAC }

# --- Low-level invocation -----------------------------------------------------

function Invoke-Racadm {
    <#
        Run a racadm command against a host and return a structured result.
        Credential is decrypted only for the child process invocation.
        Uses an argument ARRAY (safe for values/paths) rather than a split string.
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
        $text = ($out | Out-String).TrimEnd()
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $text
            Success  = ($LASTEXITCODE -eq 0)
            # Rule 2: surface a text-level failure signal for callers to check.
            HasError = ($text -match 'ERROR|RAC\d{4}|failed|Unable')
        }
    }
    finally { $pass = $null }
}

function Get-RacadmValue {
    <#
        Pull a single value out of racadm 'Group.Index#Attribute=Value' output,
        ignoring cert banners, [Key=...] header lines, and blanks.
        (Same parser as the proven scripts.)
    #>
    param([string]$RawOutput)
    foreach ($line in ($RawOutput -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^\[Key=') { continue }
        if ($t -match '^Security Alert') { continue }
        if ($t -match '^Continuing execution') { continue }
        if ($t -match '^\S+\s*=\s*(.*)$') { return $Matches[1].Trim() }
    }
    return '(no value found)'
}

# --- Read-only (readiness) ----------------------------------------------------

function Get-iDRACInfo {
    <# Read-only: auth check + firmware + product/license. Safe for the audit stage. #>
    param([string]$IP, [pscredential]$Credential)
    $ver = Invoke-Racadm -IP $IP -Credential $Credential -Args @('getversion')
    $lic = Invoke-Racadm -IP $IP -Credential $Credential -Args @('get', 'idrac.Info.Product')
    $fw  = if ($ver.Success) {
        (($ver.Output -split "`r?`n") | Where-Object { $_.Trim() -and $_ -notmatch '^Security Alert' -and $_ -notmatch '^Continuing execution' } | Select-Object -First 1)
    } else { '(read failed)' }
    return [pscustomobject]@{
        Reachable = $ver.Success
        Firmware  = ($fw | ForEach-Object { $_.Trim() })
        Product   = if ($lic.Success) { Get-RacadmValue $lic.Output } else { 'Unknown' }
    }
}

# --- BMC baseline operations (ported from Set-iDRAC-NTP-Syslog-Alerts.ps1) -----
# Each returns [pscustomobject]@{ Step; Status; Detail } with Status in
# Success | Failed | Partial | Skipped, matching the proven script's reporting.

function Set-iDRACDns {
    param([string]$IP, [pscredential]$Credential, [Parameter(Mandatory)][string]$Dns1, [string]$Dns2)
    $ok = $true; $d = @()
    foreach ($c in @(@('set',$script:iDRAC.Dns1,$Dns1)) + $(if ($Dns2) { ,@('set',$script:iDRAC.Dns2,$Dns2) } else { @() })) {
        $r = Invoke-Racadm -IP $IP -Credential $Credential -Args $c
        if (-not $r.Success) { $ok = $false }
        $d += "$($c -join ' ') => $(if ($r.Success) {'OK'} else {'FAIL'})"
    }
    [pscustomobject]@{ Step='DNS'; Status=$(if($ok){'Success'}else{'Failed'}); Detail=($d -join '; ') }
}

function Enable-iDRACMasterAlert {
    <# Master alert switch -- must be Enabled first or no alert fires (rule 5). #>
    param([string]$IP, [pscredential]$Credential)
    $r = Invoke-Racadm -IP $IP -Credential $Credential -Args @('set', $script:iDRAC.AlertMaster, 'Enabled')
    [pscustomobject]@{ Step='MasterAlert'; Status=$(if($r.Success){'Success'}else{'Failed'}); Detail=$r.Output }
}

function Set-iDRACNtp {
    param([string]$IP, [pscredential]$Credential, [Parameter(Mandatory)][string]$Ntp1, [string]$Ntp2)
    $ok = $true; $d = @()
    $cmds = @(@('set',$script:iDRAC.NtpEnable,'1'), @('set',$script:iDRAC.Ntp1,$Ntp1))   # NTPEnable is 1/0
    if ($Ntp2) { $cmds += ,@('set',$script:iDRAC.Ntp2,$Ntp2) }
    foreach ($c in $cmds) {
        $r = Invoke-Racadm -IP $IP -Credential $Credential -Args $c
        if (-not $r.Success) { $ok = $false }
        $d += "$($c -join ' ') => $(if ($r.Success) {'OK'} else {'FAIL'})"
    }
    [pscustomobject]@{ Step='NTP'; Status=$(if($ok){'Success'}else{'Failed'}); Detail=($d -join '; ') }
}

function Set-iDRACTimezone {
    param([string]$IP, [pscredential]$Credential, [Parameter(Mandatory)][string]$Timezone)
    $r = Invoke-Racadm -IP $IP -Credential $Credential -Args @('set', $script:iDRAC.Timezone, $Timezone)
    [pscustomobject]@{ Step='Timezone'; Status=$(if($r.Success){'Success'}else{'Failed'}); Detail=$r.Output }
}

function Set-iDRACSecureSyslog {
    <#
        Secure Syslog, in the proven order:
          1. Upload CA cert (sslcertupload -t 12) FIRST  -- else RAC1019 (rule 4)
          2. Pause ~5s (cert store may restart)
          3. Set SecureServer1, enable SecureSysLogEnable, disable Basic SysLogEnable
          4. Read back SecureSysLogEnable to confirm it actually stuck
        If cert upload fails, the enable steps are SKIPPED (avoids repeat RAC1019).
    #>
    param(
        [string]$IP, [pscredential]$Credential,
        [Parameter(Mandatory)][string]$SyslogServer,
        [Parameter(Mandatory)][string]$CaCertPath
    )
    if (-not (Test-Path $CaCertPath)) {
        return [pscustomobject]@{ Step='SecureSyslog'; Status='Failed'; Detail="CA cert not found: $CaCertPath"; Verify='(n/a)' }
    }
    $certFull = (Resolve-Path $CaCertPath).Path
    $cert = Invoke-Racadm -IP $IP -Credential $Credential -Args @('sslcertupload','-t','12','-f',$certFull)
    if (-not $cert.Success) {
        return [pscustomobject]@{ Step='SecureSyslog'; Status='Skipped'; Detail="CA cert upload failed (type 12) -- skipped enable to avoid RAC1019: $($cert.Output)"; Verify='(skipped)' }
    }
    Start-Sleep -Seconds 5
    $ok = $true; $d = @('cert upload => OK')
    foreach ($c in @(
        @('set',$script:iDRAC.SecureServer1,$SyslogServer),
        @('set',$script:iDRAC.SecureEnable,'Enabled'),
        @('set',$script:iDRAC.SysLogEnable,'Disabled')   # disable Basic to avoid mode ambiguity
    )) {
        $r = Invoke-Racadm -IP $IP -Credential $Credential -Args $c
        if (-not $r.Success) { $ok = $false }
        $d += "$($c -join ' ') => $(if ($r.Success) {'OK'} else {'FAIL'})"
    }
    $v = Invoke-Racadm -IP $IP -Credential $Credential -Args @('get', $script:iDRAC.SecureEnable)
    $verify = if ($v.Success) { Get-RacadmValue $v.Output } else { '(read failed)' }
    [pscustomobject]@{ Step='SecureSyslog'; Status=$(if($ok){'Success'}else{'Failed'}); Detail=($d -join '; '); Verify=$verify }
}

function Set-iDRACAlerts {
    <#
        eventfilters for SNMP + Remote Syslog on Critical & Warning, all categories.
        Detects silent partial failure via output text (rule 2) and reports Partial.
    #>
    param([string]$IP, [pscredential]$Credential)
    $ok = $true; $partial = $false; $d = @()
    foreach ($cat in $script:AlertCategories) {
        foreach ($sev in $script:AlertSeverities) {
            $r = Invoke-Racadm -IP $IP -Credential $Credential -Args @('eventfilters','set','-c',"$cat.$sev",'-a','none','-n',$script:AlertNotifications)
            $textFail = $r.Output -match 'failed'
            $status = if ($r.Success -and -not $textFail) { 'OK' }
                      elseif ($r.Success -and $textFail)  { $partial = $true; 'PARTIAL' }
                      else                                 { $ok = $false; 'FAIL' }
            $d += "$cat.$sev => $status"
        }
    }
    $final = if (-not $ok) { 'Failed' } elseif ($partial) { 'Partial' } else { 'Success' }
    [pscustomobject]@{ Step='Alerts'; Status=$final; Detail=($d -join '; ') }
}

function Invoke-DellBmcBaseline {
    <#
        Run the full Dell BMC baseline in the proven order and return one result
        row per step. Values come from the pipeline config (deploy.config.psd1
        Baseline section). Non-interactive -- for orchestrator use.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][hashtable]$Baseline   # Dns1,Dns2,Ntp1,Ntp2,Timezone,SyslogServer,SyslogCaCertPath
    )
    $steps = @()
    $steps += Set-iDRACDns          -IP $IP -Credential $Credential -Dns1 $Baseline.Dns1 -Dns2 $Baseline.Dns2
    $steps += Enable-iDRACMasterAlert -IP $IP -Credential $Credential                      # master switch before eventfilters
    $steps += Set-iDRACNtp          -IP $IP -Credential $Credential -Ntp1 $Baseline.Ntp1 -Ntp2 $Baseline.Ntp2
    $steps += Set-iDRACTimezone     -IP $IP -Credential $Credential -Timezone $Baseline.Timezone
    $steps += Set-iDRACSecureSyslog -IP $IP -Credential $Credential -SyslogServer $Baseline.SyslogServer -CaCertPath $Baseline.SyslogCaCertPath
    $steps += Set-iDRACAlerts       -IP $IP -Credential $Credential
    return $steps
}

# --- Virtual media / power (install stage) ------------------------------------

function Set-iDRACBootToVirtualMedia {
    <#
        Attach the install ISO as virtual media and set one-time boot to VCD-DVD.
        TODO(live-hardware): confirm remoteimage attach syntax on target iDRAC gen.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$IsoUrl
    )
    $attach = Invoke-Racadm -IP $IP -Credential $Credential -Args @('remoteimage', '-c', '-l', $IsoUrl)
    $boot   = Invoke-Racadm -IP $IP -Credential $Credential -Args @('set', 'iDRAC.ServerBoot.FirstBootDevice', 'VCD-DVD')
    $once   = Invoke-Racadm -IP $IP -Credential $Credential -Args @('set', 'iDRAC.ServerBoot.BootOnce', 'Enabled')
    [pscustomobject]@{
        Ok     = ($attach.Success -and $boot.Success -and $once.Success)
        Detail = @($attach.Output, $boot.Output, $once.Output) -join "`n"
    }
}

function Restart-iDRACHost {
    <# Power-cycle the server to begin the install boot. #>
    param([string]$IP, [pscredential]$Credential, [switch]$Hard)
    $verb = if ($Hard) { 'hardreset' } else { 'powercycle' }
    Invoke-Racadm -IP $IP -Credential $Credential -Args @('serveraction', $verb)
}

Export-ModuleMember -Function `
    Get-iDRACAttributeMap, Invoke-Racadm, Get-RacadmValue, Get-iDRACInfo, `
    Set-iDRACDns, Enable-iDRACMasterAlert, Set-iDRACNtp, Set-iDRACTimezone, `
    Set-iDRACSecureSyslog, Set-iDRACAlerts, Invoke-DellBmcBaseline, `
    Set-iDRACBootToVirtualMedia, Restart-iDRACHost
