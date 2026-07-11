<#
.SYNOPSIS
    Configure DNS, NTP, Secure Syslog, and Alert notifications (SNMP + Remote
    Syslog for Critical/Warning, across all alert categories) on iDRACs via racadm.
.DESCRIPTION
    Reads iDRAC IPs from a CSV. Prompts interactively for DNS, NTP server(s),
    and the secure syslog server. Applies settings, then reads values back to verify.

    CONFIRMED FROM TESTING + DELL DOCS:

    1. ALERTS HAVE A MASTER ON/OFF SWITCH separate from eventfilters.
       Even with eventfilters configured correctly, NO alerts fire unless
       idrac.IPMILan.AlertEnable is also set to Enabled. This script sets
       this first, before configuring eventfilters.

    2. eventfilters CAN PARTIALLY FAIL SILENTLY. Dell's own support guidance
       confirms: "You will get error message saying 'Few alert settings have
       failed'. This is normal as some events will not support [a given
       notification type]." This script checks output text for failure
       indicators per call, not just exit code, and reports PARTIAL status
       separately from FAIL so you can see exactly which category/severity
       combos didn't take.

    3. SECURE SYSLOG ATTRIBUTES - CONFIRMED via live `racadm get idrac.SysLog`
       dump from test host (10.10.10.31):
           securesyslogenable = Enabled/Disabled  (the GUI "Security" dropdown)
           secureserver1      = single secure syslog target
           secureport         = 6514 (left at default, not changed by this script)
           secureclientauth   = Anonymous/... (the GUI "Authentication" dropdown,
                                 left at default, not changed by this script)
       This script ENABLES Secure mode (securesyslogenable=1) and explicitly
       DISABLES Basic mode (SysLogEnable=0), since Dell's GUI note states
       enabling Secure causes iDRAC to ignore the Basic Server1 setting anyway -
       disabling Basic explicitly avoids ambiguity about which mode is active.
    4. SECURE SYSLOG ROOT CAUSE - CONFIRMED via testing + Dell community/docs:
       RAC1019 ("object not supported for current system configuration") when
       setting SecureSysLogEnable was caused by a MISSING CA CERTIFICATE, not
       a wrong attribute name or value. Confirmed firmware (7.20.60.50) and
       license (Enterprise) both support the feature - they were not the issue.

       Dell's official sslcertupload reference confirms: type 12 = "Rsyslog
       Server CA Cert" (the correct type for non-telemetry Secure Syslog).
       NOTE: type 8 is for TELEMETRY's separate Rsyslog CA cert (requires
       Datacenter license) - NOT what this script uses.

       This script now uploads the CA cert via:
           racadm sslcertupload -t 12 -f <path>
       BEFORE attempting to set SecureSysLogEnable. A short delay/retry is
       included since cert upload can trigger an internal service restart.
.EXAMPLE
    .\Set-iDRAC-NTP-Syslog-Alerts.ps1 -CsvPath ".\idrac_list.csv" -SyslogCaCertPath ".\syslog-ca.pem"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $true)]
    [string]$SyslogCaCertPath,

    [string]$User = "root",

    [string]$LogPath = ".\idrac_ntp_syslog_alerts_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

# ============================================================
# ATTRIBUTE NAMES - VERIFY AGAINST YOUR FIRMWARE BEFORE USE
# ============================================================
# Confirmed from Dell docs / Ansible Redfish module mappings:
$ntpEnableAttr   = "idrac.NTPConfigGroup.NTPEnable"
$ntp1Attr        = "idrac.NTPConfigGroup.NTP1"
$ntp2Attr        = "idrac.NTPConfigGroup.NTP2"

# Master alert switch - gates ALL alerts regardless of eventfilters settings.
# Confirmed via Dell support: racadm set iDRAC.IPMILan.AlertEnable Enabled
$alertMasterAttr = "idrac.IPMILan.AlertEnable"

# Secure Syslog (confirmed via live `racadm get idrac.SysLog` dump from test host):
#   securesyslogenable = Enabled/Disabled  (this is the "Security" dropdown in GUI)
#   secureserver1       = the single secure syslog target
#   secureport          = defaults to 6514, normally left as-is
#   secureclientauth    = Anonymous/... (this is the "Authentication" dropdown)
# NOTE: Basic (SysLogEnable/Server1) and Secure (securesyslogenable/secureserver1)
# are SEPARATE attributes that can coexist in the property database, but per
# Dell's docs only ONE mode is actually active at a time - enabling Secure
# causes iDRAC to ignore the Basic Server1 setting (note text in GUI confirms this).
$syslogEnableAttr       = "idrac.SysLog.SysLogEnable"
$syslogServerAttr       = "idrac.SysLog.Server1"
$secureSyslogEnableAttr = "idrac.SysLog.SecureSysLogEnable"
$secureSyslogServerAttr = "idrac.SysLog.SecureServer1"

# DNS (carried over from earlier script)
$dns1Attr = "idrac.IPv4.DNS1"
$dns2Attr = "idrac.IPv4.DNS2"

# Timezone (IANA-style string format, e.g. Europe/Paris, Asia/Singapore)
$timezoneAttr = "idrac.Time.Timezone"

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

# --- Validate CA cert file exists ---
if (-not (Test-Path $SyslogCaCertPath)) {
    Write-Error "Syslog CA certificate file not found: $SyslogCaCertPath"
    exit 1
}
$syslogCaCertFullPath = (Resolve-Path $SyslogCaCertPath).Path

function Read-ValidIp {
    param([string]$Prompt, [switch]$AllowBlank)
    do {
        $val = Read-Host $Prompt
        if ($AllowBlank -and -not $val) { return $null }
        $isValid = $val -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'
        if (-not $isValid) { Write-Warning "'$val' doesn't look like a valid IPv4 address. Try again." }
    } while (-not $isValid)
    return $val
}

# --- Prompt: DNS (up to 2 - iDRAC's IPv4 group only supports DNS1/DNS2, no DNS3) ---
Write-Host "`n--- DNS Configuration ---" -ForegroundColor Cyan
$dns1 = Read-ValidIp -Prompt "Enter DNS1 (required)"
$dns2 = Read-ValidIp -Prompt "Enter DNS2 (optional, press Enter to skip)" -AllowBlank

# --- Prompt: NTP servers (up to 2, second optional) ---
Write-Host "`n--- NTP Configuration ---" -ForegroundColor Cyan
$ntpServer1 = Read-ValidIp -Prompt "Enter NTP Server 1 (required)"
$ntpServer2 = Read-ValidIp -Prompt "Enter NTP Server 2 (optional, press Enter to skip)" -AllowBlank

# --- Prompt: Syslog server (single, required) - SECURE mode ---
Write-Host "`n--- Secure Syslog Configuration ---" -ForegroundColor Cyan
$syslogServer = Read-ValidIp -Prompt "Enter Secure Syslog Server IP (required)"

# --- Prompt: Timezone (defaults to Singapore, IANA format) ---
Write-Host "`n--- Timezone Configuration ---" -ForegroundColor Cyan
$tzInput = Read-Host "Enter IANA timezone [default: Asia/Singapore]"
$timezone = if ($tzInput) { $tzInput } else { "Asia/Singapore" }

Write-Host "`nSummary of values to apply:" -ForegroundColor Yellow
Write-Host "  DNS1          : $dns1"
Write-Host "  DNS2          : $(if ($dns2) { $dns2 } else { '(not set)' })"
Write-Host "  NTP1          : $ntpServer1"
Write-Host "  NTP2          : $(if ($ntpServer2) { $ntpServer2 } else { '(not set)' })"
Write-Host "  Syslog Server : $syslogServer (Secure mode, port 6514, Basic mode will be disabled)"
Write-Host "  CA Cert       : $syslogCaCertFullPath (type 12 - Rsyslog Server CA Cert)"
Write-Host "  Timezone      : $timezone"
Write-Host "  Master Alerts : Will be enabled (idrac.IPMILan.AlertEnable)"
Write-Host "  Alerts        : SNMP + Remote Syslog enabled for Critical & Warning, all categories"
$confirm = Read-Host "`nProceed with these values on $($targets.Count) host(s)? (y/n)"
if ($confirm -ne "y") {
    Write-Host "Aborted by user." -ForegroundColor Yellow
    exit 0
}

# --- Prompt for password securely ---
$securePass = Read-Host "`nEnter iDRAC password for user $User" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
$plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

function Invoke-Racadm {
    param([string]$Ip, [string]$User, [string]$Pass, [string]$ArgString)
    $racadmArgs = @("-r", $Ip, "-u", $User, "-p", $Pass, "--nocertwarn") + $ArgString.Split(" ")
    $output = & racadm @racadmArgs 2>&1
    $exitCode = $LASTEXITCODE
    return [PSCustomObject]@{
        Output   = ($output -join "`n")
        ExitCode = $exitCode
        Success  = ($exitCode -eq 0)
    }
}

function Get-RacadmValue {
    param([string]$RawOutput)
    $lines = $RawOutput -split "`r?`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^\[Key=') { continue }
        if ($trimmed -match '^Security Alert') { continue }
        if ($trimmed -match '^Continuing execution') { continue }
        if ($trimmed -match '^\S+\s*=\s*(.*)$') { return $Matches[1].Trim() }
    }
    return "(no value found)"
}

# Alert categories shown in the iDRAC "Alert Configuration" screen.
# "all" applies to every category in one call where supported; listed
# individually here too so partial firmware support doesn't silently skip categories.
$alertCategories = @(
    "idrac.alert.system",
    "idrac.alert.storage",
    "idrac.alert.updates",
    "idrac.alert.audit",
    "idrac.alert.config"
)
$alertSeverities  = @("critical", "warning")
$alertNotifications = "snmp,remotesyslog"

$results = @()

foreach ($target in $targets) {
    $ip = $target.IP.Trim()
    if (-not $ip) { continue }

    Write-Host "`n==> Configuring $ip ..." -ForegroundColor Cyan

    $row = [PSCustomObject]@{
        IP                  = $ip
        Timestamp           = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        DNS_Status          = "Unknown"
        NTP_Status          = "Unknown"
        Timezone_Status     = "Unknown"
        CertUpload_Status   = "Unknown"
        Syslog_Status       = "Unknown"
        SecureSyslog_Verify = "Unknown"
        AlertsMaster_Status = "Unknown"
        Alerts_Status       = "Unknown"
        Details             = ""
    }

    if (-not (Test-Connection -ComputerName $ip -Count 1 -Quiet)) {
        Write-Warning "  $ip is unreachable. Skipping."
        $row.DNS_Status = $row.NTP_Status = $row.Timezone_Status = $row.CertUpload_Status = $row.Syslog_Status = $row.AlertsMaster_Status = $row.Alerts_Status = "Unreachable"
        $row.SecureSyslog_Verify = "Unreachable"
        $row.Details = "Ping failed"
        $results += $row
        continue
    }

    $detailLines = @()

    # --- DNS ---
    Write-Host "  Setting DNS..."
    $dnsOk = $true
    $dnsCmds = @("set $dns1Attr $dns1")
    if ($dns2) { $dnsCmds += "set $dns2Attr $dns2" }

    foreach ($cmd in $dnsCmds) {
        $r = Invoke-Racadm -Ip $ip -User $User -Pass $plainPass -ArgString $cmd
        if ($r.Success) {
            $status = "OK"
        } else {
            $status = "FAIL"
            $dnsOk = $false
        }
        Write-Host "    [$status] $cmd"
        $detailLines += "${status}: $cmd"
    }
    $row.DNS_Status = if ($dnsOk) { "Success" } else { "Failed" }

    # --- Master Alert Switch (must be on for ANY alert to fire) ---
    Write-Host "  Enabling master Alerts switch..."
    $masterCmd = "set $alertMasterAttr Enabled"
    $r = Invoke-Racadm -Ip $ip -User $User -Pass $plainPass -ArgString $masterCmd
    if ($r.Success) {
        $row.AlertsMaster_Status = "Success"
        Write-Host "    [OK] $masterCmd"
    } else {
        $row.AlertsMaster_Status = "Failed"
        Write-Host "    [FAIL] $masterCmd -> $($r.Output)"
    }
    $detailLines += "$($row.AlertsMaster_Status): $masterCmd"

    # --- NTP ---
    Write-Host "  Setting NTP..."
    $ntpOk = $true
    $cmds = @(
        "set $ntpEnableAttr 1",
        "set $ntp1Attr $ntpServer1"
    )
    if ($ntpServer2) { $cmds += "set $ntp2Attr $ntpServer2" }

    foreach ($cmd in $cmds) {
        $r = Invoke-Racadm -Ip $ip -User $User -Pass $plainPass -ArgString $cmd
        if ($r.Success) {
            $status = "OK"
        } else {
            $status = "FAIL"
            $ntpOk = $false
        }
        Write-Host "    [$status] $cmd"
        $detailLines += "${status}: $cmd"
    }
    $row.NTP_Status = if ($ntpOk) { "Success" } else { "Failed" }

    # --- Timezone ---
    Write-Host "  Setting Timezone..."
    $tzCmd = "set $timezoneAttr $timezone"
    $r = Invoke-Racadm -Ip $ip -User $User -Pass $plainPass -ArgString $tzCmd
    if ($r.Success) {
        $row.Timezone_Status = "Success"
        Write-Host "    [OK] $tzCmd"
    } else {
        $row.Timezone_Status = "Failed"
        Write-Host "    [FAIL] $tzCmd -> $($r.Output)"
    }
    $detailLines += "$($row.Timezone_Status): $tzCmd"

    # --- Upload Secure Syslog CA Certificate (must happen BEFORE enabling) ---
    # Confirmed root cause of RAC1019: SecureSysLogEnable cannot be set until
    # a CA cert is uploaded. Type 12 = "Rsyslog Server CA Cert" per Dell's
    # official sslcertupload reference (NOT type 8, which is for Telemetry).
    Write-Host "  Uploading Secure Syslog CA certificate..."
    $certArgs = @("-r", $ip, "-u", $User, "-p", $plainPass, "--nocertwarn", "sslcertupload", "-t", "12", "-f", $syslogCaCertFullPath)
    $certOutput = & racadm @certArgs 2>&1
    $certExitCode = $LASTEXITCODE
    $certSuccess = ($certExitCode -eq 0)
    if ($certSuccess) {
        $row.CertUpload_Status = "Success"
        Write-Host "    [OK] sslcertupload -t 12 -f $syslogCaCertFullPath"
    } else {
        $row.CertUpload_Status = "Failed"
        Write-Host "    [FAIL] sslcertupload -t 12 -f $syslogCaCertFullPath"
        Write-Host "      -> $($certOutput -join ' ')" -ForegroundColor Yellow
    }
    $detailLines += "$($row.CertUpload_Status): sslcertupload -t 12"

    # Cert upload can trigger an internal cert-store restart on some firmware -
    # brief pause before proceeding to the enable step to avoid a race.
    if ($certSuccess) { Start-Sleep -Seconds 5 }

    # --- Syslog (Secure mode) ---
    Write-Host "  Setting Secure Syslog..."
    $syslogOk = $true
    if (-not $certSuccess) {
        Write-Host "    [SKIPPED] CA cert upload failed - skipping Secure Syslog enable to avoid repeat RAC1019" -ForegroundColor Yellow
        $syslogOk = $false
        $detailLines += "SKIPPED: Secure Syslog set commands (cert upload failed)"
    } else {
        $syslogCmds = @(
            "set $secureSyslogServerAttr $syslogServer",
            "set $secureSyslogEnableAttr Enabled",
            "set $syslogEnableAttr Disabled"    # explicitly disable Basic mode to avoid ambiguity
        )
        foreach ($cmd in $syslogCmds) {
            $r = Invoke-Racadm -Ip $ip -User $User -Pass $plainPass -ArgString $cmd
            if ($r.Success) {
                $status = "OK"
            } else {
                $status = "FAIL"
                $syslogOk = $false
            }
            Write-Host "    [$status] $cmd"
            if ($status -eq "FAIL") {
                Write-Host "      -> $($r.Output)" -ForegroundColor Yellow
            }
            $detailLines += "${status}: $cmd"
        }
    }
    $row.Syslog_Status = if ($syslogOk) { "Success" } else { "Failed" }
    if (-not $syslogOk) {
        $row.Details = "Secure Syslog: one or more commands failed - check Details column"
    }

    # Verify what value actually landed for the Security toggle - this is the
    # specific field that wasn't sticking, so confirm post-set rather than
    # trusting the set command's exit code alone.
    $verify = Invoke-Racadm -Ip $ip -User $User -Pass $plainPass -ArgString "get $secureSyslogEnableAttr"
    $row.SecureSyslog_Verify = if ($verify.Success) { Get-RacadmValue $verify.Output } else { "(read failed)" }
    Write-Host "    Verify: $secureSyslogEnableAttr = $($row.SecureSyslog_Verify)"

    # --- Alerts: SNMP + Remote Syslog for Critical & Warning, all categories ---
    Write-Host "  Setting Alert notifications (SNMP + Remote Syslog, Critical+Warning, all categories)..."
    $alertsOk = $true
    foreach ($category in $alertCategories) {
        foreach ($severity in $alertSeverities) {
            $cmd = "eventfilters set -c $category.$severity -a none -n $alertNotifications"
            $r = Invoke-Racadm -Ip $ip -User $User -Pass $plainPass -ArgString $cmd

            # Dell's own support guidance confirms eventfilters can return a
            # non-fatal exit code while still reporting "Few alert settings
            # have failed" in the output text - so check text, not just ExitCode.
            $partialFailureText = $r.Output -match 'failed'

            if ($r.Success -and -not $partialFailureText) {
                $status = "OK"
            } elseif ($r.Success -and $partialFailureText) {
                $status = "PARTIAL"
                $alertsOk = $false
            } else {
                $status = "FAIL"
                $alertsOk = $false
            }
            Write-Host "    [$status] ${category}.${severity}"
            $detailLines += "${status}: eventfilters ${category}.${severity} -> $alertNotifications"
            if ($status -ne "OK") {
                $detailLines += "      -> $($r.Output)"
            }
        }
    }
    $row.Alerts_Status = if ($alertsOk) { "Success" } else { "PartialFailure" }

    $row.Details = ($detailLines -join " | ")
    $results += $row

    $overallOk = ($row.DNS_Status -eq "Success") -and ($row.NTP_Status -eq "Success") -and ($row.Timezone_Status -eq "Success") -and ($row.CertUpload_Status -eq "Success") -and ($row.Syslog_Status -eq "Success") -and ($row.AlertsMaster_Status -eq "Success") -and ($row.Alerts_Status -eq "Success")
    Write-Host "  Finished $ip" -ForegroundColor $(if ($overallOk) { "Green" } else { "Red" })
    Write-Host "-------------------------------------"
}

# --- Clean up plaintext password from memory ---
$plainPass = $null
[System.GC]::Collect()

# --- Export results log ---
$results | Export-Csv -Path $LogPath -NoTypeInformation
Write-Host "`nDone. Results log written to: $LogPath" -ForegroundColor Cyan

Write-Host "`n--- Summary ---"
$results | Select-Object IP, DNS_Status, NTP_Status, Timezone_Status, CertUpload_Status, Syslog_Status, SecureSyslog_Verify, AlertsMaster_Status, Alerts_Status | Format-Table -AutoSize
