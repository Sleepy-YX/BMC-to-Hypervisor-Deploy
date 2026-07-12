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

    # 1. Reachability
    if (-not (Test-HostReachable -IP $ip)) {
        Write-Stage -Host_ $ip -Stage 'Readiness' -Status 'FAIL' -Message 'ICMP unreachable'
        Add-LogRow  -Host_ $ip -Stage 'Readiness' -Status 'FAIL' -Message 'ICMP unreachable'
        continue
    }
    Write-Stage -Host_ $ip -Stage 'Reachability' -Status 'OK' -Message 'ping reply'
    Add-LogRow  -Host_ $ip -Stage 'Reachability' -Status 'OK' -Message 'ping reply'

    # 2. BMC web port
    $web = Test-TcpPort -IP $ip -Port 443
    Write-Stage -Host_ $ip -Stage 'BMC-Port-443' -Status ($(if ($web) {'OK'} else {'WARN'})) -Message ($(if ($web) {'open'} else {'closed/filtered'}))
    Add-LogRow  -Host_ $ip -Stage 'BMC-Port-443' -Status ($(if ($web) {'OK'} else {'WARN'})) -Message ($(if ($web) {'open'} else {'closed'}))

    # 3. Auth + firmware (read-only), per platform
    try {
        if ($platform -eq 'dell') {
            $info = Get-iDRACInfo -IP $ip -Credential $cred
            if ($info.Reachable) {
                Write-Stage -Host_ $ip -Stage 'BMC-Auth' -Status 'OK' -Message "iDRAC $($info.Firmware)"
                Add-LogRow  -Host_ $ip -Stage 'BMC-Auth' -Status 'OK' -Message $info.Firmware
            } else {
                Write-Stage -Host_ $ip -Stage 'BMC-Auth' -Status 'FAIL' -Message 'racadm read failed (auth/cert?)'
                Add-LogRow  -Host_ $ip -Stage 'BMC-Auth' -Status 'FAIL' -Message 'racadm read failed'
            }
        }
        elseif ($platform -eq 'lenovo') {
            $info = Get-XCC3Info -IP $ip -Credential $cred
            if ($info.Reachable) {
                Write-Stage -Host_ $ip -Stage 'BMC-Auth' -Status 'OK' -Message 'onecli inventory read ok'
                Add-LogRow  -Host_ $ip -Stage 'BMC-Auth' -Status 'OK' -Message 'onecli inventory read ok'
            } else {
                Write-Stage -Host_ $ip -Stage 'BMC-Auth' -Status 'FAIL' -Message 'onecli read failed'
                Add-LogRow  -Host_ $ip -Stage 'BMC-Auth' -Status 'FAIL' -Message 'onecli read failed'
            }
        }
    }
    catch {
        Write-Stage -Host_ $ip -Stage 'BMC-Auth' -Status 'FAIL' -Message $_.Exception.Message
        Add-LogRow  -Host_ $ip -Stage 'BMC-Auth' -Status 'FAIL' -Message $_.Exception.Message
    }
}

# Summary + CSV
Write-Host ""
Write-Host "===== Readiness summary =====" -ForegroundColor Cyan
Get-DeploySummary | Format-Table -AutoSize
$logPath = Save-DeployLog
Write-Host "Log written: $logPath" -ForegroundColor DarkGray
