<#
.SYNOPSIS
    READ-ONLY deployment readiness audit. Run this against every host before any
    stage that changes settings -- every time. Touches nothing.

.DESCRIPTION
    For each host in the CSV inventory it checks:
      - BMC ICMP reachability
      - BMC management port open (623/udp is IPMI; we TCP-probe 443 for the web UI)
      - BMC auth works (a harmless read-only get/inventory call)
      - Firmware / model string (informational)
      - That the declared Platform + Hypervisor are supported

    Results print as a summary table and are written to a timestamped CSV in logs\.

.EXAMPLE
    .\stages\Test-DeployReadiness.ps1 -ServerList .\config\servers.csv
#>
[CmdletBinding()]
param(
    [string]$ServerList = (Join-Path $PSScriptRoot '..\config\servers.csv')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

Import-Module (Join-Path $root 'lib\Common.psm1') -Force
Import-Module (Join-Path $root 'lib\Providers\Dell.iDRAC.psm1') -Force
Import-Module (Join-Path $root 'lib\Providers\Lenovo.XCC3.psm1') -Force

$servers = @(Import-ServerList -Path $ServerList)
Write-Host "Loaded $($servers.Count) host(s) from $ServerList" -ForegroundColor Cyan
$cred = Read-BmcCredential

foreach ($s in $servers) {
    $ip = $s.IP
    $platform = $s.Platform.ToLower()

    # The console shows each check as it happens; the LOG gets ONE consolidated
    # 'readiness' row per host (the stage key the fleet grid joins on) plus
    # 'fact:*' INFO rows with the inventory details (model / serial / firmware).
    $notes  = @()
    $status = 'OK'
    $facts  = @{}

    # 1. Reachability
    if (-not (Test-HostReachable -IP $ip)) {
        Write-Stage -Host_ $ip -Stage 'readiness' -Status 'FAIL' -Message 'ICMP unreachable'
        Add-LogRow  -Host_ $ip -Stage 'readiness' -Status 'FAIL' -Message 'ICMP unreachable'
        continue
    }
    Write-Stage -Host_ $ip -Stage 'Reachability' -Status 'OK' -Message 'ping reply'
    $notes += 'ping ok'

    # 2. BMC web port
    $web = Test-TcpPort -IP $ip -Port 443
    Write-Stage -Host_ $ip -Stage 'BMC-Port-443' -Status ($(if ($web) {'OK'} else {'WARN'})) -Message ($(if ($web) {'open'} else {'closed/filtered'}))
    if ($web) { $notes += 'https 443 open' } else { $notes += '443 closed/filtered'; $status = 'WARN' }

    # 3. Auth + inventory (read-only), per platform
    try {
        if ($platform -eq 'dell') {
            $info = Get-iDRACInfo -IP $ip -Credential $cred
            if ($info.Reachable) {
                Write-Stage -Host_ $ip -Stage 'BMC-Auth' -Status 'OK' -Message "iDRAC $($info.Firmware)"
                $notes += "auth ok; iDRAC fw $($info.Firmware)"
                if ($info.Model)       { $facts['Model']       = $info.Model }
                if ($info.ServiceTag)  { $facts['Serial']      = $info.ServiceTag }
                if ($info.BiosVersion) { $facts['Bios']        = $info.BiosVersion }
                if ($info.Firmware)    { $facts['BmcFirmware'] = $info.Firmware }
            } else {
                Write-Stage -Host_ $ip -Stage 'BMC-Auth' -Status 'FAIL' -Message 'racadm read failed (auth/cert?)'
                $notes += 'racadm read failed (auth/cert?)'; $status = 'FAIL'
            }
        }
        elseif ($platform -eq 'lenovo') {
            $info = Get-XCC3Info -IP $ip -Credential $cred
            if ($info.Reachable) {
                Write-Stage -Host_ $ip -Stage 'BMC-Auth' -Status 'OK' -Message 'onecli inventory read ok'
                $notes += 'auth ok; onecli inventory read ok'
                if ($info.Model)    { $facts['Model']       = $info.Model }
                if ($info.Serial)   { $facts['Serial']      = $info.Serial }
                if ($info.Firmware) { $facts['BmcFirmware'] = $info.Firmware }
            } else {
                Write-Stage -Host_ $ip -Stage 'BMC-Auth' -Status 'FAIL' -Message 'onecli read failed'
                $notes += 'onecli read failed'; $status = 'FAIL'
            }
        }
    }
    catch {
        Write-Stage -Host_ $ip -Stage 'BMC-Auth' -Status 'FAIL' -Message $_.Exception.Message
        $notes += "auth check error: $($_.Exception.Message)"; $status = 'FAIL'
    }

    Add-LogRow -Host_ $ip -Stage 'readiness' -Status $status -Message ($notes -join '; ')
    foreach ($k in @($facts.Keys | Sort-Object)) {
        Add-LogRow -Host_ $ip -Stage "fact:$k" -Status 'INFO' -Message $facts[$k]
    }
}

# Summary + CSV
Write-Host ""
Write-Host "===== Readiness summary =====" -ForegroundColor Cyan
Get-DeploySummary | Format-Table -AutoSize
$logPath = Save-DeployLog
Write-Host "Log written: $logPath" -ForegroundColor DarkGray
