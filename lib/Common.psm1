<#
.SYNOPSIS
    Shared helpers for the BMC-to-Hypervisor deployment pipeline.

    These functions are platform-independent and fully working. Hardware-specific
    logic lives in lib\Providers\*.psm1 (BMC) and lib\Hypervisors\*.psm1.

    Conventions carried over from the BMC Fleet Automation repo:
      - CSV-driven per-host loop
      - Masked password prompt, entered once per run, never stored
      - Per-host status logged to a timestamped CSV + console summary
      - Read-only audit first; config steps confirm before touching hardware
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Logging -----------------------------------------------------------------

$script:LogRows = [System.Collections.Generic.List[object]]::new()

# Live write-through target: InfraServerSetup (and anything else) can tail an
# in-progress run here; Save-DeployLog removes it when the run is finalized.
$script:LiveLogPath = Join-Path $PSScriptRoot '..\logs\deploy_log_live.csv'

function Write-Stage {
    <# Console line with a consistent, greppable prefix. #>
    param(
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][ValidateSet('INFO', 'OK', 'WARN', 'FAIL', 'SKIP')][string]$Status,
        [string]$Message = ''
    )
    $color = switch ($Status) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'SKIP' { 'DarkGray' }
        default { 'Gray' }
    }
    # Note: braces around variable names before a colon -- colon otherwise breaks parsing.
    Write-Host ("[{0}] {1,-18} {2,-4} {3}" -f $Host_, $Stage, $Status, $Message) -ForegroundColor $color
}

function Add-LogRow {
    <# Append one row to the in-memory result table (flushed by Save-DeployLog). #>
    param(
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Status,
        [string]$Message = ''
    )
    $row = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('s')
        Host      = $Host_
        Stage     = $Stage
        Status    = $Status
        Message   = $Message
    }
    $script:LogRows.Add($row)

    # Write-through for live dashboards (InfraServerSetup). Must never break a run:
    # a full disk or locked file only costs the live view, not the deployment.
    try {
        $liveDir = Split-Path $script:LiveLogPath -Parent
        if (-not (Test-Path $liveDir)) { New-Item -ItemType Directory -Path $liveDir -Force | Out-Null }
        $csv = $row | ConvertTo-Csv -NoTypeInformation
        if (-not (Test-Path $script:LiveLogPath)) {
            $csv | Set-Content -Path $script:LiveLogPath -Encoding UTF8
        } else {
            $csv[1] | Add-Content -Path $script:LiveLogPath -Encoding UTF8
        }
    } catch { }
}

function Save-DeployLog {
    <# Write the accumulated rows to a timestamped CSV under logs\. Returns the path. #>
    param([string]$LogDir = (Join-Path $PSScriptRoot '..\logs'))
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path  = Join-Path $LogDir "deploy_log_$stamp.csv"
    $script:LogRows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
    # Run is finalized; drop the live write-through file (non-fatal if locked).
    try {
        if (Test-Path $script:LiveLogPath) { Remove-Item $script:LiveLogPath -Force -Confirm:$false }
    } catch { }
    return (Resolve-Path $path).Path
}

function Get-DeploySummary {
    <# Return the in-memory rows so the caller can render a summary table. #>
    return $script:LogRows
}

# --- Credentials -------------------------------------------------------------

function Read-BmcCredential {
    <#
        Prompt once for the BMC username/password. Password is masked and kept
        only as a SecureString inside the returned PSCredential -- never written
        to disk or the log.

        Non-interactive path: an InfraServerSetup web launch supplies credentials via the
        INFRASERVERSETUP_BMC_USER / INFRASERVERSETUP_BMC_PASS environment variables of THIS
        process only (set around the spawn, never on a command line or disk).
        They are consumed and cleared on first read.
    #>
    param([string]$DefaultUser = 'root')
    if ($env:INFRASERVERSETUP_BMC_PASS) {
        $user = if ($env:INFRASERVERSETUP_BMC_USER) { $env:INFRASERVERSETUP_BMC_USER } else { $DefaultUser }
        $pass = ConvertTo-SecureString -String $env:INFRASERVERSETUP_BMC_PASS -AsPlainText -Force
        Remove-Item Env:INFRASERVERSETUP_BMC_PASS -ErrorAction SilentlyContinue
        Remove-Item Env:INFRASERVERSETUP_BMC_USER -ErrorAction SilentlyContinue
        Write-Host "BMC credentials for '$user' supplied by InfraServerSetup launch." -ForegroundColor DarkGray
        return [System.Management.Automation.PSCredential]::new($user, $pass)
    }
    $user = Read-Host "BMC username [$DefaultUser]"
    if ([string]::IsNullOrWhiteSpace($user)) { $user = $DefaultUser }
    $pass = Read-Host "BMC password for '$user'" -AsSecureString
    return [System.Management.Automation.PSCredential]::new($user, $pass)
}

function ConvertTo-PlainText {
    <#
        Decrypt a SecureString to a plain string ONLY at the moment of handing it
        to an external CLI (racadm / onecli). Callers must null the result out of
        scope quickly; never log it.
    #>
    param([Parameter(Mandatory)][securestring]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# --- Inventory ---------------------------------------------------------------

function Import-ServerList {
    <#
        Load and validate the CSV inventory. Required columns:
          IP, Hostname, Platform (dell|lenovo), Hypervisor (esxi|ahv|proxmox|hyperv)
        Optional columns are passed through untouched (e.g. Rack, BiosProfile, Cluster).
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Server list not found: $Path" }
    $rows = Import-Csv -Path $Path

    $required = @('IP', 'Hostname', 'Platform', 'Hypervisor')
    $have = if ($rows) { $rows[0].psobject.Properties.Name } else { @() }
    $missing = $required | Where-Object { $_ -notin $have }
    if ($missing) { throw "Server list is missing required column(s): $($missing -join ', ')" }

    $validPlatform   = @('dell', 'lenovo')
    $validHypervisor = @('esxi', 'ahv', 'proxmox', 'hyperv')
    $n = 0
    foreach ($r in $rows) {
        $n++
        if ([string]::IsNullOrWhiteSpace($r.IP))       { throw "Row $n has an empty IP." }
        if ($r.Platform.ToLower()   -notin $validPlatform)   { throw "Row $n ($($r.IP)): Platform '$($r.Platform)' must be one of: $($validPlatform -join ', ')" }
        if ($r.Hypervisor.ToLower() -notin $validHypervisor) { throw "Row $n ($($r.IP)): Hypervisor '$($r.Hypervisor)' must be one of: $($validHypervisor -join ', ')" }
    }
    return $rows
}

# --- Reachability ------------------------------------------------------------

function Test-HostReachable {
    <# ICMP ping test. Returns $true/$false, never throws. #>
    param([Parameter(Mandatory)][string]$IP, [int]$Count = 2)
    try   { return Test-Connection -ComputerName $IP -Count $Count -Quiet -ErrorAction Stop }
    catch { return $false }
}

function Test-TcpPort {
    <# TCP connect test with timeout. Returns $true/$false, never throws. #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 3000
    )
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $iar = $client.BeginConnect($IP, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    }
    catch { return $false }
    finally { $client.Close() }
}

# --- Confirmation gate -------------------------------------------------------

function Confirm-Change {
    <#
        Show a summary of intended changes and require an explicit 'yes'.
        Honors -Force (skip prompt) and -WhatIf (never prompt, always decline).
    #>
    param(
        [Parameter(Mandatory)][string]$Summary,
        [switch]$Force,
        [switch]$WhatIf
    )
    Write-Host ""
    Write-Host "Intended changes:" -ForegroundColor Cyan
    Write-Host $Summary
    if ($WhatIf) { Write-Host "(-WhatIf) No changes will be made." -ForegroundColor DarkGray; return $false }
    if ($Force)  { return $true }
    $ans = Read-Host "Proceed? [y/N]"
    return ($ans -match '^(y|yes)$')
}

Export-ModuleMember -Function `
    Write-Stage, Add-LogRow, Save-DeployLog, Get-DeploySummary, `
    Read-BmcCredential, ConvertTo-PlainText, Import-ServerList, `
    Test-HostReachable, Test-TcpPort, Confirm-Change
