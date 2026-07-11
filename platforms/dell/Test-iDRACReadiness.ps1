<#
.SYNOPSIS
    Read-only iDRAC readiness check and inventory audit via racadm.
.DESCRIPTION
    Reads iDRAC IPs from a CSV, then queries (no changes made) each host for:
    reachability, racadm/firmware version, license level, current network/DNS,
    NTP, and Syslog settings. Outputs a CSV report you can review before
    running any configuration changes.
.NOTES
    This script makes NO changes to any iDRAC. It only runs racadm 'get' commands.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [string]$User = "root",

    [string]$ReportPath = ".\idrac_readiness_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

# --- Validate racadm is available ---
if (-not (Get-Command racadm -ErrorAction SilentlyContinue)) {
    Write-Error "racadm not found in PATH. Install Dell OpenManage / iDRAC tools on this jumphost first."
    exit 1
}

# --- Validate CSV exists ---
if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

$targets = Import-Csv -Path $CsvPath
if (-not $targets -or -not ($targets[0].PSObject.Properties.Name -contains "IP")) {
    Write-Error "CSV must contain a header column named 'IP'."
    exit 1
}

# --- Prompt for password securely ---
$securePass = Read-Host "Enter iDRAC password for user $User" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
$plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

function Invoke-RacadmGet {
    param(
        [string]$Ip,
        [string]$User,
        [string]$Pass,
        [string]$ArgString  # e.g. "get idrac.IPv4.DNS1"
    )
    # --nocertwarn suppresses the self-signed cert banner so output parsing
    # doesn't have to fight noise. It does NOT skip cert validation security -
    # it only suppresses the warning text in output; racadm still connects the same way.
    $racadmArgs = @("-r", $Ip, "-u", $User, "-p", $Pass, "--nocertwarn") + $ArgString.Split(" ")
    $output = & racadm @racadmArgs 2>&1
    $exitCode = $LASTEXITCODE
    return [PSCustomObject]@{
        Output   = ($output -join "`n")
        ExitCode = $exitCode
        Success  = ($exitCode -eq 0)
    }
}

# Pulls a single value out of racadm's "Group.Index#Attribute=Value" style output.
# Only looks at lines that match "Attribute=Value" - ignores warning banners,
# blank lines, and "[Key=...]" lines, which don't represent the actual setting.
function Get-RacadmValue {
    param([string]$RawOutput)

    $lines = $RawOutput -split "`r?`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^\[Key=') { continue }          # skip the [Key=...] header line
        if ($trimmed -match '^Security Alert') { continue }   # skip cert warning
        if ($trimmed -match '^Continuing execution') { continue }
        if ($trimmed -match '^\S+\s*=\s*(.*)$') {
            return $Matches[1].Trim()
        }
    }
    return "(no value found)"
}

$report = @()

foreach ($target in $targets) {
    $ip = $target.IP.Trim()
    if (-not $ip) { continue }

    Write-Host "`n==> Checking iDRAC at $ip ..." -ForegroundColor Cyan

    $row = [PSCustomObject]@{
        IP               = $ip
        Timestamp        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Reachable        = $false
        AuthOK           = $false
        FirmwareVersion  = ""
        LicenseLevel     = ""
        CurrentIPSource  = ""
        DNS1             = ""
        DNS2             = ""
        DNSRegister      = ""
        NTPEnabled       = ""
        NTP1             = ""
        NTP2             = ""
        SyslogEnabled    = ""
        SyslogServer1    = ""
        SecureSyslogGroupRaw = ""
        SSHEnabled       = ""
        TelnetEnabled    = ""
        VNCEnabled       = ""
        Notes            = ""
    }

    # --- Reachability ---
    if (-not (Test-Connection -ComputerName $ip -Count 1 -Quiet)) {
        Write-Warning "  $ip is unreachable (ping failed)."
        $row.Notes = "Ping failed - host unreachable, skipped further checks"
        $report += $row
        continue
    }
    $row.Reachable = $true

    # --- Auth / basic connectivity test ---
    $verCheck = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "getversion"
    if (-not $verCheck.Success) {
        Write-Warning "  $ip reachable but racadm auth/connection failed."
        $row.Notes = "racadm getversion failed: $($verCheck.Output)"
        $report += $row
        continue
    }
    $row.AuthOK = $true
    $verLines = ($verCheck.Output -split "`r?`n") | Where-Object {
        $_.Trim() -and $_ -notmatch '^Security Alert' -and $_ -notmatch '^Continuing execution'
    }
    $row.FirmwareVersion = if ($verLines) { $verLines[0].Trim() } else { "(no value found)" }

    # --- License level ---
    $lic = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.Info.Product"
    $row.LicenseLevel = if ($lic.Success) { Get-RacadmValue $lic.Output } else { "Unknown" }

    # --- Current IP config source (DHCP vs Static) ---
    $ipSrc = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.IPv4.DHCPEnable"
    $row.CurrentIPSource = if ($ipSrc.Success) {
        if ((Get-RacadmValue $ipSrc.Output) -eq "1") { "DHCP" } else { "Static" }
    } else { "Unknown" }

    # --- DNS ---
    $dns1 = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.IPv4.DNS1"
    $dns2 = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.IPv4.DNS2"
    $dnsReg = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.NIC.DNSRegister"
    $row.DNS1 = if ($dns1.Success) { Get-RacadmValue $dns1.Output } else { "Error" }
    $row.DNS2 = if ($dns2.Success) { Get-RacadmValue $dns2.Output } else { "Error" }
    $row.DNSRegister = if ($dnsReg.Success) { Get-RacadmValue $dnsReg.Output } else { "Error" }

    # --- NTP ---
    $ntpEn = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.NTPConfigGroup.NTPEnable"
    $ntp1  = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.NTPConfigGroup.NTP1"
    $ntp2  = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.NTPConfigGroup.NTP2"
    $row.NTPEnabled = if ($ntpEn.Success) { Get-RacadmValue $ntpEn.Output } else { "Error" }
    $row.NTP1 = if ($ntp1.Success) { Get-RacadmValue $ntp1.Output } else { "Error" }
    $row.NTP2 = if ($ntp2.Success) { Get-RacadmValue $ntp2.Output } else { "Error" }

    # --- Syslog (Basic) ---
    $sysEn = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.SysLog.SysLogEnable"
    $sys1  = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.SysLog.Server1"
    $row.SyslogEnabled = if ($sysEn.Success) { Get-RacadmValue $sysEn.Output } else { "Error" }
    $row.SyslogServer1 = if ($sys1.Success) { Get-RacadmValue $sys1.Output } else { "Error" }

    # --- Syslog (Secure / TLS) - attribute names vary by firmware, dumped raw for review ---
    $secureGroup = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.SysLog"
    $row.SecureSyslogGroupRaw = if ($secureGroup.Success) {
        ($secureGroup.Output -split "`r?`n" | Where-Object {
            $_.Trim() -and $_ -notmatch '^Security Alert' -and $_ -notmatch '^Continuing execution' -and $_ -notmatch '^\[Key='
        }) -join " | "
    } else { "Error" }

    # --- Remote access services (informational only, not changed) ---
    $ssh = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.SSH.Enable"
    $tel = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.Telnet.Enable"
    $vnc = Invoke-RacadmGet -Ip $ip -User $User -Pass $plainPass -ArgString "get idrac.VNCServer.Enable"
    $row.SSHEnabled    = if ($ssh.Success) { Get-RacadmValue $ssh.Output } else { "Error" }
    $row.TelnetEnabled = if ($tel.Success) { Get-RacadmValue $tel.Output } else { "Error" }
    $row.VNCEnabled    = if ($vnc.Success) { Get-RacadmValue $vnc.Output } else { "Error" }

    $row.Notes = "OK"
    $report += $row

    Write-Host "  Firmware: $($row.FirmwareVersion) | License: $($row.LicenseLevel) | IP mode: $($row.CurrentIPSource)" -ForegroundColor Green
    Write-Host "  DNS1: $($row.DNS1)  DNS2: $($row.DNS2)  NTP1: $($row.NTP1)  Syslog1: $($row.SyslogServer1)"
    Write-Host "-------------------------------------"
}

# --- Clean up plaintext password from memory ---
$plainPass = $null
[System.GC]::Collect()

# --- Export report ---
$report | Export-Csv -Path $ReportPath -NoTypeInformation
Write-Host "`nReadiness report written to: $ReportPath" -ForegroundColor Cyan

# --- Summary ---
$unreachable = $report | Where-Object { -not $_.Reachable }
$authFail    = $report | Where-Object { $_.Reachable -and -not $_.AuthOK }
$ok          = $report | Where-Object { $_.AuthOK }

Write-Host "`n--- Summary ---"
Write-Host "Total hosts checked : $($report.Count)"
Write-Host "Reachable & authenticated OK : $($ok.Count)" -ForegroundColor Green
if ($unreachable) {
    Write-Host "Unreachable : $($unreachable.Count)" -ForegroundColor Red
    $unreachable | Format-Table IP, Notes
}
if ($authFail) {
    Write-Host "Reachable but auth/racadm failed : $($authFail.Count)" -ForegroundColor Yellow
    $authFail | Format-Table IP, Notes
}
