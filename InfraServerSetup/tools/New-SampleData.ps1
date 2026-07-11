<#
.SYNOPSIS
    Generates sample fleet + deployment logs for InfraServerSetup development and demos.

    Produces data in the exact shape the BMC-to-Hypervisor-Deploy pipeline writes:
      config\servers.csv                    - fleet definition
      logs\deploy_log_<yyyyMMdd-HHmmss>.csv - one CSV per run
                                              (Timestamp, Host, Stage, Status, Message)
      logs\deploy_log_live.csv              - in-progress run (Live mode only)

.PARAMETER Mode
    History - write servers.csv + 6 historical runs with a realistic mix of
              OK / WARN / FAIL / SKIP outcomes. Deterministic.
    Live    - simulate an in-progress run: appends one row every ~IntervalSeconds
              to deploy_log_live.csv, then finalizes it into a timestamped CSV
              (exactly what the patched Save-DeployLog does).

.EXAMPLE
    .\New-SampleData.ps1 -Mode History
    .\New-SampleData.ps1 -Mode Live -IntervalSeconds 2
#>
[CmdletBinding()]
param(
    [ValidateSet('History', 'Live')]
    [string]$Mode = 'History',
    [string]$TargetDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'sample'),
    [int]$IntervalSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configDir = Join-Path $TargetDir 'config'
$logsDir   = Join-Path $TargetDir 'logs'
foreach ($d in @($configDir, $logsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# --- Fleet definition ---------------------------------------------------------

$fleet = @(
    [pscustomobject]@{ IP = '10.0.10.11'; Hostname = 'esx-node-01'; Platform = 'dell';   Hypervisor = 'esxi';    Rack = 'R1'; BiosProfile = 'perf-uefi'; Cluster = 'PROD-CL01'  }
    [pscustomobject]@{ IP = '10.0.10.12'; Hostname = 'esx-node-02'; Platform = 'dell';   Hypervisor = 'esxi';    Rack = 'R1'; BiosProfile = 'perf-uefi'; Cluster = 'PROD-CL01'  }
    [pscustomobject]@{ IP = '10.0.10.13'; Hostname = 'esx-node-03'; Platform = 'dell';   Hypervisor = 'esxi';    Rack = 'R1'; BiosProfile = 'perf-uefi'; Cluster = 'PROD-CL01'  }
    [pscustomobject]@{ IP = '10.0.10.14'; Hostname = 'esx-node-04'; Platform = 'dell';   Hypervisor = 'esxi';    Rack = 'R2'; BiosProfile = 'perf-uefi'; Cluster = 'PROD-CL01'  }
    [pscustomobject]@{ IP = '10.0.20.21'; Hostname = 'ahv-node-01'; Platform = 'lenovo'; Hypervisor = 'ahv';     Rack = 'R2'; BiosProfile = '';          Cluster = 'PROD-NTX01' }
    [pscustomobject]@{ IP = '10.0.20.22'; Hostname = 'ahv-node-02'; Platform = 'lenovo'; Hypervisor = 'ahv';     Rack = 'R2'; BiosProfile = '';          Cluster = 'PROD-NTX01' }
    [pscustomobject]@{ IP = '10.0.20.23'; Hostname = 'ahv-node-03'; Platform = 'lenovo'; Hypervisor = 'ahv';     Rack = 'R3'; BiosProfile = '';          Cluster = 'PROD-NTX01' }
    [pscustomobject]@{ IP = '10.0.30.31'; Hostname = 'pve-node-01'; Platform = 'dell';   Hypervisor = 'proxmox'; Rack = 'R3'; BiosProfile = 'virt-uefi'; Cluster = 'PVE-CL01'   }
    [pscustomobject]@{ IP = '10.0.30.32'; Hostname = 'pve-node-02'; Platform = 'dell';   Hypervisor = 'proxmox'; Rack = 'R3'; BiosProfile = 'virt-uefi'; Cluster = 'PVE-CL01'   }
    [pscustomobject]@{ IP = '10.0.40.41'; Hostname = 'hci-node-01'; Platform = 'lenovo'; Hypervisor = 'hyperv';  Rack = 'R4'; BiosProfile = '';          Cluster = 'HCI-CL01'   }
    [pscustomobject]@{ IP = '10.0.40.42'; Hostname = 'hci-node-02'; Platform = 'lenovo'; Hypervisor = 'hyperv';  Rack = 'R4'; BiosProfile = '';          Cluster = 'HCI-CL01'   }
    [pscustomobject]@{ IP = '10.0.40.43'; Hostname = 'hci-node-03'; Platform = 'lenovo'; Hypervisor = 'hyperv';  Rack = 'R4'; BiosProfile = '';          Cluster = 'HCI-CL01'   }
)

$serversPath = Join-Path $configDir 'servers.csv'
$fleet | Export-Csv -Path $serversPath -NoTypeInformation -Encoding UTF8
Write-Host "Fleet written: $serversPath ($($fleet.Count) hosts)" -ForegroundColor Cyan

# --- Row helpers ---------------------------------------------------------------

function New-Run {
    <# Turn a list of @(Host, Stage, Status, Message) tuples into log rows with
       timestamps walking forward from the run's start time. #>
    param(
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][object[]]$Steps
    )
    $t = $Start
    $rows = foreach ($s in $Steps) {
        $t = $t.AddSeconds(35 + (Get-Random -Minimum 5 -Maximum 55))
        [pscustomobject]@{
            Timestamp = $t.ToString('s')
            Host      = $s[0]
            Stage     = $s[1]
            Status    = $s[2]
            Message   = $s[3]
        }
    }
    return $rows
}

function Save-Run {
    param([Parameter(Mandatory)][datetime]$Start, [Parameter(Mandatory)][object[]]$Rows)
    $path = Join-Path $logsDir ("deploy_log_{0}.csv" -f $Start.ToString('yyyyMMdd-HHmmss'))
    $Rows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
    Write-Host "Run written:   $path ($($Rows.Count) rows)" -ForegroundColor Green
}

# ==============================================================================
if ($Mode -eq 'History') {

    Get-Random -SetSeed 42 | Out-Null   # deterministic timestamps run-to-run

    # -- Run 1: readiness sweep across the whole fleet (2026-06-28) ------------
    $start = Get-Date '2026-06-28 09:30:12'
    $steps = @(
        @('esx-node-01', 'readiness', 'OK',   'ping ok; https 443 open; auth ok; iDRAC fw 7.10.30.00'),
        @('esx-node-02', 'readiness', 'OK',   'ping ok; https 443 open; auth ok; iDRAC fw 7.10.30.00'),
        @('esx-node-03', 'readiness', 'OK',   'ping ok; https 443 open; auth ok; iDRAC fw 7.00.60.00'),
        @('esx-node-04', 'readiness', 'OK',   'ping ok; https 443 open; auth ok; iDRAC fw 7.10.30.00'),
        @('ahv-node-01', 'readiness', 'OK',   'ping ok; https 443 open; auth ok; XCC3 fw 4.20'),
        @('ahv-node-02', 'readiness', 'FAIL', 'auth failed: invalid credentials (IPMI-over-LAN disabled?)'),
        @('ahv-node-03', 'readiness', 'OK',   'ping ok; https 443 open; auth ok; XCC3 fw 4.20'),
        @('pve-node-01', 'readiness', 'OK',   'ping ok; https 443 open; auth ok; iDRAC fw 7.10.30.00'),
        @('pve-node-02', 'readiness', 'OK',   'ping ok; https 443 open; auth ok; iDRAC fw 7.10.30.00'),
        @('hci-node-01', 'readiness', 'OK',   'ping ok; https 443 open; auth ok; XCC3 fw 4.20'),
        @('hci-node-02', 'readiness', 'OK',   'ping ok; https 443 open; auth ok; XCC3 fw 4.20'),
        @('hci-node-03', 'readiness', 'WARN', 'auth ok but XCC3 fw 3.10 below baseline 4.20 - update before install')
    )
    Save-Run -Start $start -Rows (New-Run -Start $start -Steps $steps)

    # -- Run 2: full pipeline, Dell ESXi nodes (2026-06-30) ---------------------
    $start = Get-Date '2026-06-30 14:15:23'
    $steps = @()
    foreach ($h in 'esx-node-01', 'esx-node-02', 'esx-node-03', 'esx-node-04') {
        $steps += , @($h, 'readiness', 'OK', 'ping ok; https 443 open; auth ok')
    }
    $steps += @(
        @('esx-node-01', 'firmware',     'OK',   'BIOS 2.21.2 / iDRAC 7.10.30.00 at catalog baseline'),
        @('esx-node-02', 'firmware',     'OK',   'BIOS 2.21.2 / iDRAC 7.10.30.00 at catalog baseline'),
        @('esx-node-03', 'firmware',     'WARN', 'iDRAC updated to 7.10.30.00; NIC fw update deferred - reboot pending'),
        @('esx-node-04', 'firmware',     'OK',   'BIOS 2.21.2 / iDRAC 7.10.30.00 at catalog baseline')
    )
    foreach ($h in 'esx-node-01', 'esx-node-02', 'esx-node-03', 'esx-node-04') {
        $steps += , @($h, 'bios',         'OK', "profile 'perf-uefi' applied; RAID1 vd0 ready")
        $steps += , @($h, 'bmc-baseline', 'OK', 'DNS/NTP/TZ/secure-syslog/alerts applied')
        $steps += , @($h, 'install',      'OK', 'esxi-8.0u3 ISO mounted via vmedia; one-time boot set; power cycled')
        $steps += , @($h, 'clusterjoin',  'OK', 'ESXi up; joined PROD-CL01 in vCenter')
    }
    Save-Run -Start $start -Rows (New-Run -Start $start -Steps $steps)

    # -- Run 3: AHV nodes; ahv-node-02 fails install (2026-07-02) ---------------
    $start = Get-Date '2026-07-02 10:12:45'
    $steps = @(
        @('ahv-node-01', 'readiness',    'OK',   'ping ok; auth ok (creds fixed)'),
        @('ahv-node-02', 'readiness',    'OK',   'ping ok; auth ok (IPMI-over-LAN enabled)'),
        @('ahv-node-03', 'readiness',    'OK',   'ping ok; auth ok'),
        @('ahv-node-01', 'firmware',     'OK',   'UXSP applied; XCC3 4.20'),
        @('ahv-node-02', 'firmware',     'OK',   'UXSP applied; XCC3 4.20'),
        @('ahv-node-03', 'firmware',     'OK',   'UXSP applied; XCC3 4.20'),
        @('ahv-node-01', 'bios',         'SKIP', 'no BiosProfile defined for host'),
        @('ahv-node-02', 'bios',         'SKIP', 'no BiosProfile defined for host'),
        @('ahv-node-03', 'bios',         'SKIP', 'no BiosProfile defined for host'),
        @('ahv-node-01', 'bmc-baseline', 'OK',   'DNS/NTP/TZ/alerts applied'),
        @('ahv-node-02', 'bmc-baseline', 'OK',   'DNS/NTP/TZ/alerts applied'),
        @('ahv-node-03', 'bmc-baseline', 'OK',   'DNS/NTP/TZ/alerts applied'),
        @('ahv-node-01', 'install',      'OK',   'Foundation imaging complete (AOS 6.8 / AHV bundled)'),
        @('ahv-node-02', 'install',      'FAIL', 'Foundation node imaging timed out at 34%'),
        @('ahv-node-03', 'install',      'OK',   'Foundation imaging complete (AOS 6.8 / AHV bundled)'),
        @('ahv-node-01', 'clusterjoin',  'OK',   'joined PROD-NTX01 in Prism'),
        @('ahv-node-02', 'clusterjoin',  'SKIP', 'skipped: install stage failed'),
        @('ahv-node-03', 'clusterjoin',  'OK',   'joined PROD-NTX01 in Prism')
    )
    Save-Run -Start $start -Rows (New-Run -Start $start -Steps $steps)

    # -- Run 4: Proxmox nodes, clean run (2026-07-05) ---------------------------
    $start = Get-Date '2026-07-05 16:00:34'
    $steps = @()
    foreach ($h in 'pve-node-01', 'pve-node-02') {
        $steps += , @($h, 'readiness',    'OK', 'ping ok; https 443 open; auth ok')
        $steps += , @($h, 'firmware',     'OK', 'BIOS 2.21.2 / iDRAC 7.10.30.00 at catalog baseline')
        $steps += , @($h, 'bios',         'OK', "profile 'virt-uefi' applied; RAID1 vd0 ready")
        $steps += , @($h, 'bmc-baseline', 'OK', 'DNS/NTP/TZ/secure-syslog/alerts applied')
        $steps += , @($h, 'install',      'OK', 'proxmox-ve-8.2 ISO mounted via vmedia; unattended answer file staged')
        $steps += , @($h, 'clusterjoin',  'OK', 'PVE up; joined PVE-CL01 via pvecm')
    }
    Save-Run -Start $start -Rows (New-Run -Start $start -Steps $steps)

    # -- Run 5: Hyper-V nodes; XCC3 syslog warning, node-03 join fails (2026-07-08)
    $start = Get-Date '2026-07-08 13:34:10'
    $steps = @(
        @('hci-node-01', 'readiness',    'OK',   'ping ok; auth ok; XCC3 fw 4.20'),
        @('hci-node-02', 'readiness',    'OK',   'ping ok; auth ok; XCC3 fw 4.20'),
        @('hci-node-03', 'readiness',    'OK',   'ping ok; auth ok; XCC3 updated to 4.20'),
        @('hci-node-01', 'firmware',     'OK',   'UXSP applied'),
        @('hci-node-02', 'firmware',     'OK',   'UXSP applied'),
        @('hci-node-03', 'firmware',     'OK',   'UXSP applied (fw brought up from 3.10)'),
        @('hci-node-01', 'bios',         'SKIP', 'no BiosProfile defined for host'),
        @('hci-node-02', 'bios',         'SKIP', 'no BiosProfile defined for host'),
        @('hci-node-03', 'bios',         'SKIP', 'no BiosProfile defined for host'),
        @('hci-node-01', 'bmc-baseline', 'WARN', 'DNS/NTP/TZ/alerts applied; XCC3 syslog attr mapping unconfirmed - syslog step skipped'),
        @('hci-node-02', 'bmc-baseline', 'WARN', 'DNS/NTP/TZ/alerts applied; XCC3 syslog attr mapping unconfirmed - syslog step skipped'),
        @('hci-node-03', 'bmc-baseline', 'WARN', 'DNS/NTP/TZ/alerts applied; XCC3 syslog attr mapping unconfirmed - syslog step skipped'),
        @('hci-node-01', 'install',      'OK',   'Azure Stack HCI ISO mounted; unattend.xml staged; power cycled'),
        @('hci-node-02', 'install',      'OK',   'Azure Stack HCI ISO mounted; unattend.xml staged; power cycled'),
        @('hci-node-03', 'install',      'OK',   'Azure Stack HCI ISO mounted; unattend.xml staged; power cycled'),
        @('hci-node-01', 'clusterjoin',  'OK',   'joined HCI-CL01 failover cluster'),
        @('hci-node-02', 'clusterjoin',  'OK',   'joined HCI-CL01 failover cluster'),
        @('hci-node-03', 'clusterjoin',  'FAIL', 'failover cluster join failed: node unreachable on mgmt VLAN')
    )
    Save-Run -Start $start -Rows (New-Run -Start $start -Steps $steps)

    # -- Run 6: targeted retries (2026-07-10) -----------------------------------
    $start = Get-Date '2026-07-10 09:18:01'
    $steps = @(
        @('ahv-node-02', 'readiness',   'OK',   'ping ok; auth ok'),
        @('ahv-node-02', 'install',     'FAIL', 'Foundation imaging timed out at 41% - suspect cabling on 10G port'),
        @('ahv-node-02', 'clusterjoin', 'SKIP', 'skipped: install stage failed'),
        @('hci-node-03', 'readiness',   'OK',   'ping ok; auth ok; mgmt VLAN reachable after switchport fix'),
        @('hci-node-03', 'clusterjoin', 'OK',   'joined HCI-CL01 failover cluster')
    )
    Save-Run -Start $start -Rows (New-Run -Start $start -Steps $steps)

    Write-Host "`nHistory generated. Point the dashboard at it with:" -ForegroundColor Cyan
    Write-Host "  .\Start-InfraServerSetup.ps1 -DeployRepo `"$TargetDir`"" -ForegroundColor Yellow
}

# ==============================================================================
if ($Mode -eq 'Live') {

    $livePath = Join-Path $logsDir 'deploy_log_live.csv'
    if (Test-Path $livePath) { Remove-Item $livePath -Force -Confirm:$false }

    $hosts  = 'esx-node-01', 'esx-node-02', 'esx-node-03', 'esx-node-04'
    $stages = 'readiness', 'firmware', 'bios', 'bmc-baseline', 'install', 'clusterjoin'
    $msg = @{
        'readiness'    = 'ping ok; https 443 open; auth ok'
        'firmware'     = 'BIOS 2.21.2 / iDRAC 7.10.30.00 at catalog baseline'
        'bios'         = "profile 'perf-uefi' applied; RAID1 vd0 ready"
        'bmc-baseline' = 'DNS/NTP/TZ/secure-syslog/alerts applied'
        'install'      = 'esxi-8.0u3 ISO mounted via vmedia; one-time boot set; power cycled'
        'clusterjoin'  = 'ESXi up; joined PROD-CL01 in vCenter'
    }

    $runStart = Get-Date
    $allRows  = [System.Collections.Generic.List[object]]::new()

    function Add-LiveRow {
        param($H, $Stage, $Status, $Message)
        $row = [pscustomobject]@{
            Timestamp = (Get-Date).ToString('s')
            Host      = $H
            Stage     = $Stage
            Status    = $Status
            Message   = $Message
        }
        $allRows.Add($row)
        $csv = $row | ConvertTo-Csv -NoTypeInformation
        if (-not (Test-Path $livePath)) { $csv | Set-Content -Path $livePath -Encoding UTF8 }
        else { $csv[1] | Add-Content -Path $livePath -Encoding UTF8 }
        Write-Host ("[{0}] {1,-18} {2,-4} {3}" -f $H, $Stage, $Status, $Message)
    }

    Write-Host "Simulating a live run against $livePath (Ctrl+C aborts mid-run)...`n" -ForegroundColor Cyan

    foreach ($stage in $stages) {
        foreach ($h in $hosts) {
            Start-Sleep -Seconds (Get-Random -Minimum ([Math]::Max(1, $IntervalSeconds - 1)) -Maximum ($IntervalSeconds + 2))
            if ($h -eq 'esx-node-02' -and $stage -eq 'firmware') {
                Add-LiveRow $h $stage 'WARN' 'iDRAC updated; NIC fw update deferred - reboot pending'
            } else {
                Add-LiveRow $h $stage 'OK' $msg[$stage]
            }
        }
    }

    # Finalize exactly like the patched Save-DeployLog: timestamped CSV, live file removed.
    $finalPath = Join-Path $logsDir ("deploy_log_{0}.csv" -f $runStart.ToString('yyyyMMdd-HHmmss'))
    $allRows | Export-Csv -Path $finalPath -NoTypeInformation -Encoding UTF8
    Remove-Item $livePath -Force -Confirm:$false
    Write-Host "`nRun finalized: $finalPath" -ForegroundColor Green
}
