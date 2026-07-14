<#
.SYNOPSIS
    Master orchestrator: drives each host in the CSV inventory through the full
    deployment pipeline, BMC -> hypervisor, one staged step at a time.

.DESCRIPTION
    Stages (each host runs them in order; a FAIL aborts that host but not the run):

        readiness  -> firmware -> bios -> bmc-baseline -> install -> clusterjoin

    Design rules carried from the BMC Fleet Automation repo:
      - Read-only readiness runs first and is also runnable standalone.
      - Every changing stage shows intended changes and confirms (unless -Force).
      - Per-host status is logged to a timestamped CSV + console summary.
      - -WhatIf performs no changes anywhere (dry run of the whole pipeline).

    Stages you can start from / stop at with -FromStage / -ToStage let you resume
    a partial rollout without re-running earlier steps.

.PARAMETER Stages
    Explicit subset of stages to run (default: all). Overrides From/To.

.EXAMPLE
    .\Invoke-Deployment.ps1 -ServerList .\config\servers.csv -WhatIf
.EXAMPLE
    .\Invoke-Deployment.ps1 -ServerList .\config\servers.csv -FromStage bmc-baseline
.EXAMPLE
    .\Invoke-Deployment.ps1 -ServerList .\config\servers.csv -Stages readiness,install -Force
#>
[CmdletBinding()]
param(
    [string]$ServerList = (Join-Path $PSScriptRoot 'config\servers.csv'),
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'config\deploy.config.psd1'),
    [ValidateSet('readiness','firmware','bios','bmc-baseline','install','clusterjoin')]
    [string[]]$Stages,
    [ValidateSet('readiness','firmware','bios','bmc-baseline','install','clusterjoin')]
    [string]$FromStage = 'readiness',
    [ValidateSet('readiness','firmware','bios','bmc-baseline','install','clusterjoin')]
    [string]$ToStage = 'clusterjoin',
    # JSON file with BMC-baseline values (Dns1, Dns2, Ntp1, Ntp2, Timezone,
    # SyslogServer, SyslogCaCertPath) that override the config's Baseline
    # section for this run. Written by the InfraServerSetup Deploy tab.
    [string]$BaselineFile,
    [switch]$Force,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# --- Load modules & config ---------------------------------------------------
Import-Module (Join-Path $root 'lib\Common.psm1') -Force
Import-Module (Join-Path $root 'lib\Providers\Dell.iDRAC.psm1') -Force
Import-Module (Join-Path $root 'lib\Providers\Lenovo.XCC3.psm1') -Force
Import-Module (Join-Path $root 'lib\Hypervisors\VMware.ESXi.psm1') -Force
Import-Module (Join-Path $root 'lib\Hypervisors\Nutanix.AHV.psm1') -Force
Import-Module (Join-Path $root 'lib\Hypervisors\Proxmox.VE.psm1') -Force
Import-Module (Join-Path $root 'lib\Hypervisors\AzureStackHCI.psm1') -Force

$cfg = if (Test-Path $ConfigFile) { Import-PowerShellDataFile -Path $ConfigFile } else { @{} }

# Baseline override from a web launch: replaces the config's Baseline section
# wholesale (the form always posts all seven keys, blank = not set).
if ($BaselineFile) {
    if (-not (Test-Path $BaselineFile)) { throw "BaselineFile not found: $BaselineFile" }
    $ovr = Get-Content -Path $BaselineFile -Raw | ConvertFrom-Json
    $bl = @{ Dns1=''; Dns2=''; Ntp1=''; Ntp2=''; Timezone=''; SyslogServer=''; SyslogCaCertPath='' }
    foreach ($p in $ovr.PSObject.Properties) {
        if ($bl.ContainsKey($p.Name)) { $bl[$p.Name] = [string]$p.Value }
    }
    $cfg['Baseline'] = $bl
    Write-Host "BMC baseline values overridden from $BaselineFile" -ForegroundColor DarkGray
}

# --- Resolve which stages to run ---------------------------------------------
$allStages = @('readiness','firmware','bios','bmc-baseline','install','clusterjoin')
if ($Stages) {
    $runStages = $allStages | Where-Object { $_ -in $Stages }
} else {
    $fromIdx = [array]::IndexOf($allStages, $FromStage)
    $toIdx   = [array]::IndexOf($allStages, $ToStage)
    $runStages = $allStages[$fromIdx..$toIdx]
}

# @() guard: a one-host CSV yields a scalar, and .Count/foreach break under StrictMode.
$servers = @(Import-ServerList -Path $ServerList)
Write-Host "Loaded $($servers.Count) host(s). Stages: $($runStages -join ' -> ')" -ForegroundColor Cyan
if ($WhatIf) { Write-Host "DRY RUN (-WhatIf): no changes will be made." -ForegroundColor Yellow }

$cred = Read-BmcCredential

# --- Per-host pipeline -------------------------------------------------------
foreach ($s in $servers) {
    $ip        = $s.IP
    $platform  = $s.Platform.ToLower()
    $hyper     = $s.Hypervisor.ToLower()
    Write-Host ""
    Write-Host "########## $ip  ($platform -> $hyper)  ##########" -ForegroundColor White

    # `break` inside the switch only exits the switch, so a failed readiness
    # check needs this flag to actually abort the host's remaining stages.
    $abortHost = $false

    foreach ($stage in $runStages) {
        try {
            switch ($stage) {

                'readiness' {
                    # Full read-only audit (same checks as stages\Test-DeployReadiness.ps1):
                    # ping, BMC web port, auth + inventory. One consolidated log row for
                    # the grid plus fact:* INFO rows (model / serial / firmware).
                    if (-not (Test-HostReachable -IP $ip)) {
                        Write-Stage $ip 'readiness' 'FAIL' 'ICMP unreachable -- aborting host'
                        Add-LogRow  $ip 'readiness' 'FAIL' 'ICMP unreachable'
                        $abortHost = $true
                        break
                    }
                    $notes = @('ping ok'); $rdyStatus = 'OK'; $facts = @{}
                    $web = Test-TcpPort -IP $ip -Port 443
                    if ($web) { $notes += 'https 443 open' } else { $notes += '443 closed/filtered'; $rdyStatus = 'WARN' }
                    if ($platform -eq 'dell') {
                        $info = Get-iDRACInfo -IP $ip -Credential $cred
                        if ($info.Reachable) {
                            $notes += "auth ok; iDRAC fw $($info.Firmware)"
                            if ($info.Model)       { $facts['Model']       = $info.Model }
                            if ($info.ServiceTag)  { $facts['Serial']      = $info.ServiceTag }
                            if ($info.BiosVersion) { $facts['Bios']        = $info.BiosVersion }
                            if ($info.Firmware)    { $facts['BmcFirmware'] = $info.Firmware }
                        } else { $notes += 'racadm read failed (auth/cert?)'; $rdyStatus = 'FAIL' }
                    } else {
                        $info = Get-XCC3Info -IP $ip -Credential $cred
                        if ($info.Reachable) {
                            $notes += 'auth ok; onecli inventory read ok'
                            if ($info.Model)    { $facts['Model']       = $info.Model }
                            if ($info.Serial)   { $facts['Serial']      = $info.Serial }
                            if ($info.Firmware) { $facts['BmcFirmware'] = $info.Firmware }
                        } else { $notes += 'onecli read failed'; $rdyStatus = 'FAIL' }
                    }
                    Write-Stage $ip 'readiness' $rdyStatus ($notes -join '; ')
                    Add-LogRow  $ip 'readiness' $rdyStatus ($notes -join '; ')
                    foreach ($k in @($facts.Keys | Sort-Object)) {
                        Add-LogRow $ip "fact:$k" 'INFO' $facts[$k]
                    }
                    if ($rdyStatus -eq 'FAIL') { $abortHost = $true }   # no auth => later stages can't work
                }

                'firmware' {
                    $msg = "Update BMC/BIOS firmware from repository defined in config (Firmware section)."
                    if (Confirm-Change -Summary "[$ip] $msg" -Force:$Force -WhatIf:$WhatIf) {
                        # TODO(live-hardware): call vendor firmware update
                        #   Dell:   racadm update -f <catalog>  (or iDRAC repo update)
                        #   Lenovo: onecli update flash / OneCLI ESXi bundle
                        Write-Stage $ip 'firmware' 'WARN' 'stub -- wire vendor firmware update'
                        Add-LogRow  $ip 'firmware' 'WARN' 'stub -- not yet implemented'
                    } else {
                        Write-Stage $ip 'firmware' 'SKIP' 'declined/whatif'
                        Add-LogRow  $ip 'firmware' 'SKIP' 'declined/whatif'
                    }
                }

                'bios' {
                    $profile = if ($s.PSObject.Properties.Name -contains 'BiosProfile') { $s.BiosProfile } else { '(default)' }
                    $msg = "Apply BIOS/RAID profile '$profile' (boot mode, power profile, virtual disk layout)."
                    if (Confirm-Change -Summary "[$ip] $msg" -Force:$Force -WhatIf:$WhatIf) {
                        # TODO(live-hardware): apply BIOS/RAID template
                        #   Dell:   racadm set BIOS.* + jobqueue / SCP import
                        #   Lenovo: onecli config set for UEFI.* + storage config
                        Write-Stage $ip 'bios' 'WARN' "stub -- apply profile '$profile'"
                        Add-LogRow  $ip 'bios' 'WARN' "stub -- profile '$profile'"
                    } else {
                        Write-Stage $ip 'bios' 'SKIP' 'declined/whatif'
                        Add-LogRow  $ip 'bios' 'SKIP' 'declined/whatif'
                    }
                }

                'bmc-baseline' {
                    $bl = if ($cfg.ContainsKey('Baseline')) { $cfg.Baseline } else { $null }
                    if (-not $bl) {
                        Write-Stage $ip 'bmc-baseline' 'FAIL' 'config Baseline section missing'
                        Add-LogRow  $ip 'bmc-baseline' 'FAIL' 'config Baseline section missing'
                        break
                    }
                    $msg = "Apply BMC baseline (Dell): DNS $($bl.Dns1)/$($bl.Dns2), NTP $($bl.Ntp1)/$($bl.Ntp2), " +
                           "TZ $($bl.Timezone), Secure Syslog $($bl.SyslogServer) (CA $($bl.SyslogCaCertPath)), " +
                           "master alert + eventfilters (snmp,remotesyslog; critical+warning; all categories)."
                    if (Confirm-Change -Summary "[$ip] $msg" -Force:$Force -WhatIf:$WhatIf) {
                        if ($platform -eq 'dell') {
                            # Runs the ported, production-tested iDRAC baseline (see
                            # platforms\dell\Set-iDRAC-NTP-Syslog-Alerts.ps1). One row per step.
                            foreach ($st in (Invoke-DellBmcBaseline -IP $ip -Credential $cred -Baseline $bl)) {
                                $sym = switch ($st.Status) {
                                    'Success' { 'OK' } 'Partial' { 'WARN' } 'Skipped' { 'SKIP' } default { 'FAIL' }
                                }
                                $extra = if ($st.PSObject.Properties.Name -contains 'Verify') { " (verify=$($st.Verify))" } else { '' }
                                Write-Stage $ip "baseline:$($st.Step)" $sym "$($st.Detail)$extra"
                                Add-LogRow  $ip "baseline:$($st.Step)" $st.Status "$($st.Detail)$extra"
                            }
                        } else {
                            # Lenovo XCC3 baseline is IN DESIGN -- syslog attr mapping BLOCKING.
                            Write-Stage $ip 'bmc-baseline' 'WARN' 'XCC3 baseline pending (syslog attr mapping unconfirmed)'
                            Add-LogRow  $ip 'bmc-baseline' 'WARN' 'XCC3 baseline pending'
                        }
                    } else {
                        Write-Stage $ip 'bmc-baseline' 'SKIP' 'declined/whatif'
                        Add-LogRow  $ip 'bmc-baseline' 'SKIP' 'declined/whatif'
                    }
                }

                'install' {
                    # AHV is imaged by Foundation over IPMI, not via per-host virtual media.
                    if ($hyper -eq 'ahv') {
                        $msg = "Start Nutanix Foundation imaging for $ip (AHV)."
                        if (Confirm-Change -Summary "[$ip] $msg" -Force:$Force -WhatIf:$WhatIf) {
                            Write-Stage $ip 'install' 'WARN' 'stub -- call Start-FoundationImaging with Foundation URL'
                            Add-LogRow  $ip 'install' 'WARN' 'AHV Foundation imaging (stub)'
                        } else {
                            Write-Stage $ip 'install' 'SKIP' 'declined/whatif'
                            Add-LogRow  $ip 'install' 'SKIP' 'declined/whatif'
                        }
                    }
                    else {
                        $iso = if ($cfg.ContainsKey('Iso') -and $cfg.Iso.ContainsKey($hyper)) { $cfg.Iso[$hyper] } else { '<set config Iso.' + $hyper + '>' }
                        $msg = "Mount install ISO '$iso' via BMC virtual media, set one-time boot, power-cycle."
                        if (Confirm-Change -Summary "[$ip] $msg" -Force:$Force -WhatIf:$WhatIf) {
                            if ($platform -eq 'dell') {
                                $r = Set-iDRACBootToVirtualMedia -IP $ip -Credential $cred -IsoUrl $iso
                            } else {
                                $r = Set-XCC3BootToVirtualMedia -IP $ip -Credential $cred -IsoUrl $iso
                            }
                            if ($r.Ok) {
                                Write-Stage $ip 'install' 'OK' 'virtual media mounted + boot set'
                                Add-LogRow  $ip 'install' 'OK' 'virtual media mounted'
                            } else {
                                Write-Stage $ip 'install' 'FAIL' 'virtual media / boot set failed'
                                Add-LogRow  $ip 'install' 'FAIL' $r.Detail
                            }
                        } else {
                            Write-Stage $ip 'install' 'SKIP' 'declined/whatif'
                            Add-LogRow  $ip 'install' 'SKIP' 'declined/whatif'
                        }
                    }
                }

                'clusterjoin' {
                    $msg = "Wait for $hyper to come up, then join it to its cluster/manager (from config)."
                    if (Confirm-Change -Summary "[$ip] $msg" -Force:$Force -WhatIf:$WhatIf) {
                        # Each hypervisor module exposes a Test-*Installed poll + a join verb.
                        # TODO(live-hardware): pass real vCenter/Prism/cluster params from $cfg.
                        Write-Stage $ip 'clusterjoin' 'WARN' "stub -- call $hyper join verb once host is up"
                        Add-LogRow  $ip 'clusterjoin' 'WARN' "cluster join (stub) for $hyper"
                    } else {
                        Write-Stage $ip 'clusterjoin' 'SKIP' 'declined/whatif'
                        Add-LogRow  $ip 'clusterjoin' 'SKIP' 'declined/whatif'
                    }
                }
            }
        }
        catch {
            Write-Stage $ip $stage 'FAIL' $_.Exception.Message
            Add-LogRow  $ip $stage 'FAIL' $_.Exception.Message
        }
        if ($abortHost) { break }   # skip this host's remaining stages
    }
}

# --- Summary + CSV -----------------------------------------------------------
Write-Host ""
Write-Host "===== Deployment summary =====" -ForegroundColor Cyan
Get-DeploySummary | Format-Table -AutoSize
$logPath = Save-DeployLog
Write-Host "Log written: $logPath" -ForegroundColor DarkGray
