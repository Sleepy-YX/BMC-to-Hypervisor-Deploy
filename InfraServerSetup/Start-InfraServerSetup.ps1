<#
.SYNOPSIS
    InfraServerSetup - Foundation-style local dashboard for the BMC-to-Hypervisor
    deployment pipeline.

    Serves a browser UI on http://localhost:<Port>/ that reads (read-only!)
    the pipeline's per-run CSV logs and fleet definition:
      <DeployRepo>\logs\deploy_log_*.csv
      <DeployRepo>\config\servers.csv

    Localhost-only HttpListener prefix: no admin URL ACL needed, nothing is
    exposed on the network. The server never touches hardware or pipeline
    state; its only write is config\servers.csv when the Fleet Setup screen
    saves (the previous file is kept as servers.csv.bak).

.PARAMETER DeployRepo
    Root of the deployment repo (or any folder with logs\ + config\servers.csv,
    e.g. the generated sample\ folder). Defaults to a sibling
    BMC-to-Hypervisor-Deploy checkout.

.EXAMPLE
    .\Start-InfraServerSetup.ps1
    .\Start-InfraServerSetup.ps1 -DeployRepo .\sample -Port 8474
#>
[CmdletBinding()]
param(
    [string]$DeployRepo = '',
    [int]$Port = 8474,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Auto-detect the deploy repo when not given: InfraServerSetup works either embedded
# inside the repo (repo\InfraServerSetup\) or as a sibling folder next to it.
if (-not $DeployRepo) {
    $parent = Split-Path $PSScriptRoot -Parent
    if (Test-Path (Join-Path $parent 'Invoke-Deployment.ps1')) {
        $DeployRepo = $parent
    } else {
        $DeployRepo = Join-Path $parent 'BMC-to-Hypervisor-Deploy'
    }
}
$DeployRepo = (Resolve-Path $DeployRepo).Path
$logsDir    = Join-Path $DeployRepo 'logs'
$serversCsv = Join-Path $DeployRepo 'config\servers.csv'
$webRoot    = Join-Path $PSScriptRoot 'web'
$livePath   = Join-Path $logsDir 'deploy_log_live.csv'

if (-not (Test-Path (Join-Path $webRoot 'index.html'))) {
    throw "web\index.html not found next to this script ($webRoot)."
}

# --- Data access (read-only) --------------------------------------------------

function Read-CsvSafe {
    <# Import a CSV that another process may be appending to; never throw.
       -RequireColumn drops trailing partial rows (e.g. no Timestamp yet in the
       live log); omit it for CSVs like servers.csv that lack that column. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RequireColumn
    )
    if (-not (Test-Path $Path)) { return @() }
    try {
        $rows = @(Import-Csv -Path $Path)
        if ($RequireColumn) {
            $rows = @($rows | Where-Object { $_.PSObject.Properties[$RequireColumn] -and $_.$RequireColumn })
        }
        # Plain return: a one-row result unwraps to a scalar, so EVERY call site
        # must wrap in @(). Do NOT "fix" this with the comma operator - combined
        # with @() at the call site that nests the array and breaks .Count/pipes.
        return $rows
    } catch {
        return @()
    }
}

function Save-FleetCsv {
    <# Validate and write the fleet posted by the Fleet Setup screen.
       Standard columns first, any pass-through columns preserved after them.
       Existing servers.csv is kept as servers.csv.bak. Returns a result object;
       throws with a message suitable for a 400 response on bad input. #>
    param([Parameter(Mandatory)][object[]]$Rows)

    if ($Rows.Count -eq 0) { throw 'fleet cannot be empty' }
    $std = 'IP', 'Hostname', 'Platform', 'Hypervisor', 'Rack', 'BiosProfile', 'Cluster'

    $prop = { param($Obj, $Name)
        $p = $Obj.PSObject.Properties[$Name]
        if ($null -ne $p -and $null -ne $p.Value) { [string]$p.Value } else { '' }
    }
    foreach ($r in $Rows) {
        $ip = (& $prop $r 'IP').Trim(); $hn = (& $prop $r 'Hostname').Trim()
        if (-not $ip -or -not $hn) { throw 'every host needs an IP and a Hostname' }
        $pf = (& $prop $r 'Platform').Trim().ToLower()
        if ($pf -and $pf -notin @('dell', 'lenovo')) { throw "unknown Platform '$pf' for $hn (expected dell or lenovo)" }
        $hv = (& $prop $r 'Hypervisor').Trim().ToLower()
        if ($hv -and $hv -notin @('esxi', 'ahv', 'proxmox', 'hyperv')) { throw "unknown Hypervisor '$hv' for $hn" }
    }

    $extra = @($Rows | ForEach-Object { $_.PSObject.Properties.Name } |
        Select-Object -Unique | Where-Object { $_ -notin $std })
    $cols = @($std) + $extra

    $out = foreach ($r in $Rows) {
        $o = [ordered]@{}
        foreach ($c in $cols) { $o[$c] = (& $prop $r $c).Trim() }
        $o['Platform']   = $o['Platform'].ToLower()
        $o['Hypervisor'] = $o['Hypervisor'].ToLower()
        [pscustomobject]$o
    }

    $configDir = Split-Path $serversCsv -Parent
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $backedUp = $false
    if (Test-Path $serversCsv) {
        Copy-Item $serversCsv "$serversCsv.bak" -Force
        $backedUp = $true
    }
    $out | Export-Csv -Path $serversCsv -NoTypeInformation -Encoding UTF8
    return [pscustomobject]@{ ok = $true; hosts = $Rows.Count; backup = $backedUp }
}

function Get-RunFiles {
    if (-not (Test-Path $logsDir)) { return @() }
    @(Get-ChildItem -Path $logsDir -Filter 'deploy_log_*.csv' |
        Where-Object { $_.Name -match '^deploy_log_(\d{8}-\d{6})\.csv$' } |
        Sort-Object Name -Descending)
}

function Get-RunSummaries {
    foreach ($f in Get-RunFiles) {
        $null = $f.Name -match '^deploy_log_(\d{8}-\d{6})\.csv$'
        $id   = $Matches[1]
        $rows = @(Read-CsvSafe -Path $f.FullName -RequireColumn 'Timestamp')
        if ($rows.Count -eq 0) { continue }
        $counts = @{ OK = 0; WARN = 0; FAIL = 0; SKIP = 0; INFO = 0 }
        foreach ($r in $rows) { if ($counts.ContainsKey($r.Status)) { $counts[$r.Status]++ } }
        [pscustomobject]@{
            id      = $id
            rows    = $rows.Count
            hosts   = @($rows | Select-Object -ExpandProperty Host -Unique)
            started = $rows[0].Timestamp
            ended   = $rows[-1].Timestamp
            counts  = [pscustomobject]$counts
        }
    }
}

$BaselineKeys = 'Dns1', 'Dns2', 'Ntp1', 'Ntp2', 'Timezone', 'SyslogServer', 'SyslogCaCertPath'

function Get-BaselineDefaults {
    <# Read the Baseline section of the repo's deploy.config.psd1 so the Deploy
       tab can prefill the BMC-baseline form. Always returns all seven keys;
       missing config (e.g. the sample data folder) just yields blanks. #>
    $defaults = [ordered]@{}
    foreach ($k in $BaselineKeys) { $defaults[$k] = '' }
    try {
        $cfgPath = Join-Path $DeployRepo 'config\deploy.config.psd1'
        if (Test-Path $cfgPath) {
            $c = Import-PowerShellDataFile -Path $cfgPath
            if ($c.ContainsKey('Baseline')) {
                foreach ($k in $BaselineKeys) {
                    if ($c.Baseline.ContainsKey($k) -and $null -ne $c.Baseline[$k]) { $defaults[$k] = [string]$c.Baseline[$k] }
                }
            }
        }
    } catch { }
    return [pscustomobject]$defaults
}

function Start-Deployment {
    <# Launch Invoke-Deployment.ps1 from a web request (Deploy tab).

       Safety model:
       - Selected hosts are written to config\servers.deploy.csv so the master
         servers.csv is never touched by a partial run.
       - Credentials travel to the child ONLY via process environment variables
         set around the spawn (never on the command line, never on disk); the
         pipeline's Read-BmcCredential consumes and clears them.
       - The child runs -Force (no console confirm gates) - the UI shows an
         explicit two-step confirmation instead.
       - The console window opens minimized so the engineer can restore it to
         watch raw output or Ctrl+C the run. #>
    param([Parameter(Mandatory)][string]$Body)

    $pipeline = Join-Path $DeployRepo 'Invoke-Deployment.ps1'
    if (-not (Test-Path $pipeline)) {
        throw "Invoke-Deployment.ps1 not found in $DeployRepo - web launch is unavailable for this data folder"
    }

    $req = ConvertFrom-Json $Body
    $sel_hosts = @($req.hosts | ForEach-Object { $_ })
    $stages    = @($req.stages | ForEach-Object { $_ })
    $allStages = 'readiness', 'firmware', 'bios', 'bmc-baseline', 'install', 'clusterjoin'
    if ($sel_hosts.Count -eq 0) { throw 'select at least one host' }
    if ($stages.Count -eq 0)    { throw 'select at least one stage' }
    foreach ($s in $stages) { if ($s -notin $allStages) { throw "unknown stage '$s'" } }

    $user = [string]$req.user
    $pass = [string]$req.pass
    if (-not $pass) { throw 'BMC password is required' }
    if (-not $user) { $user = 'root' }

    $fleet = @(Read-CsvSafe -Path $serversCsv)
    $selRows = @($fleet | Where-Object { $_.Hostname -in $sel_hosts })
    if ($selRows.Count -ne $sel_hosts.Count) { throw 'selection contains host(s) not present in servers.csv' }

    $deployCsv = Join-Path (Split-Path $serversCsv -Parent) 'servers.deploy.csv'
    $selRows | Export-Csv -Path $deployCsv -NoTypeInformation -Encoding UTF8

    # BMC baseline values from the Deploy tab form. Only meaningful when the
    # bmc-baseline stage is selected; written to config\baseline.web.json and
    # passed to the pipeline via -BaselineFile (no secrets in these values).
    $blArg = ''
    if ('bmc-baseline' -in $stages) {
        $blProp = if ($req.PSObject.Properties['baseline']) { $req.baseline } else { $null }
        if ($null -eq $blProp) { throw 'bmc-baseline stage selected but no baseline values were posted' }
        $bl = [ordered]@{}
        foreach ($k in $BaselineKeys) {
            $p = $blProp.PSObject.Properties[$k]
            $bl[$k] = if ($null -ne $p -and $null -ne $p.Value) { ([string]$p.Value).Trim() } else { '' }
        }
        # No per-key requirement: the Dell baseline path already skips each
        # sub-step (DNS / NTP / Timezone / SecureSyslog) with a clean Skipped
        # row when its inputs are blank, so users can edit just the field(s)
        # they want to change. Still refuse an entirely empty submission -
        # that would run bmc-baseline with nothing to do.
        if (-not ($BaselineKeys | Where-Object { $bl[$_] })) {
            throw 'bmc-baseline stage selected but every baseline value is blank; fill in at least one field'
        }
        $baselineJson = Join-Path (Split-Path $serversCsv -Parent) 'baseline.web.json'
        ([pscustomobject]$bl) | ConvertTo-Json -Compress | Set-Content -Path $baselineJson -Encoding UTF8
        $blArg = " -BaselineFile '{0}'" -f $baselineJson.Replace("'", "''")
    }

    # Wrap the run: transcript everything to logs\, and if the pipeline throws,
    # keep the window open showing the error instead of vanishing without a trace.
    $transcript = Join-Path $logsDir ("deploy_web_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $cmd = ('try {{ Start-Transcript -Path ''{3}'' | Out-Null }} catch {{ }}; ' +
            'try {{ & ''{0}'' -ServerList ''{1}'' -Stages {2}{5} -Force }} ' +
            'catch {{ Write-Host $_ -ForegroundColor Red; ' +
            'Read-Host ''Deployment failed - see the error above (also logged to {4}); press Enter to close'' }} ' +
            'finally {{ try {{ Stop-Transcript | Out-Null }} catch {{ }} }}') -f
        $pipeline.Replace("'", "''"), $deployCsv.Replace("'", "''"), ($stages -join ','),
        $transcript.Replace("'", "''"), (Split-Path $transcript -Leaf), $blArg

    try {
        $env:INFRASERVERSETUP_BMC_USER = $user
        $env:INFRASERVERSETUP_BMC_PASS = $pass
        $proc = Start-Process -FilePath 'powershell' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) `
            -WorkingDirectory $DeployRepo -WindowStyle Minimized -PassThru
    } finally {
        Remove-Item Env:INFRASERVERSETUP_BMC_USER -ErrorAction SilentlyContinue
        Remove-Item Env:INFRASERVERSETUP_BMC_PASS -ErrorAction SilentlyContinue
    }

    Write-Host ("Deployment launched: PID {0}, {1} host(s), stages: {2}" -f $proc.Id, $selRows.Count, ($stages -join ', '))
    return [pscustomobject]@{ ok = $true; pid = $proc.Id; hosts = $selRows.Count; stages = $stages }
}

# --- HTTP plumbing -------------------------------------------------------------

function Send-Bytes {
    param($Ctx, [byte[]]$Bytes, [string]$ContentType, [int]$Status = 200)
    $Ctx.Response.StatusCode = $Status
    $Ctx.Response.ContentType = $ContentType
    $Ctx.Response.Headers['Cache-Control'] = 'no-store'
    $Ctx.Response.ContentLength64 = $Bytes.Length
    $Ctx.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Ctx.Response.OutputStream.Close()
}

function Send-Json {
    param($Ctx, $Object, [int]$Status = 200)
    $json  = ConvertTo-Json -InputObject $Object -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Send-Bytes -Ctx $Ctx -Bytes $bytes -ContentType 'application/json; charset=utf-8' -Status $Status
}

function Send-Empty {
    param($Ctx, [int]$Status = 204)
    $Ctx.Response.StatusCode = $Status
    $Ctx.Response.Headers['Cache-Control'] = 'no-store'
    $Ctx.Response.OutputStream.Close()
}

function Invoke-Route {
    param($Ctx)
    $path = $Ctx.Request.Url.AbsolutePath

    # Health probes and preflights get headers only - writing a body to a HEAD
    # response makes HttpListener throw and strands the connection.
    if ($Ctx.Request.HttpMethod -in @('HEAD', 'OPTIONS')) {
        Send-Empty -Ctx $Ctx -Status 200
        return
    }

    # CSRF guard: browsers won't attach custom headers cross-origin without a
    # CORS preflight (which we never approve), so requiring one blocks malicious
    # web pages from POSTing to this localhost server. The InfraServerSetup UI always
    # sends it.
    if ($Ctx.Request.HttpMethod -eq 'POST' -and -not $Ctx.Request.Headers['X-InfraServerSetup']) {
        Send-Json -Ctx $Ctx -Object @{ error = 'missing X-InfraServerSetup header' } -Status 403
        return
    }

    switch -Regex ($path) {
        '^/(index\.html)?$' {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $webRoot 'index.html'))
            Send-Bytes -Ctx $Ctx -Bytes $bytes -ContentType 'text/html; charset=utf-8'
            return
        }
        '^/api/meta$' {
            Send-Json -Ctx $Ctx -Object ([pscustomobject]@{ deployRepo = $DeployRepo })
            return
        }
        '^/api/fleet$' {
            if ($Ctx.Request.HttpMethod -eq 'POST') {
                $reader = New-Object System.IO.StreamReader($Ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                try {
                    # PS 5.1: ConvertFrom-Json emits a JSON array as ONE Object[]
                    # item; pipe the value through ForEach-Object to enumerate it.
                    $parsed = ConvertFrom-Json $body
                    $rows = @($parsed | ForEach-Object { $_ })
                    Send-Json -Ctx $Ctx -Object (Save-FleetCsv -Rows $rows)
                } catch {
                    Send-Json -Ctx $Ctx -Object @{ error = "$($_.Exception.Message)" } -Status 400
                }
                return
            }
            Send-Json -Ctx $Ctx -Object @(Read-CsvSafe -Path $serversCsv)
            return
        }
        '^/api/baseline$' {
            Send-Json -Ctx $Ctx -Object (Get-BaselineDefaults)
            return
        }
        '^/api/runs$' {
            Send-Json -Ctx $Ctx -Object @(Get-RunSummaries)
            return
        }
        '^/api/runs/(\d{8}-\d{6})$' {
            $file = Join-Path $logsDir ("deploy_log_{0}.csv" -f $Matches[1])
            if (-not (Test-Path $file)) { Send-Json -Ctx $Ctx -Object @{ error = 'run not found' } -Status 404; return }
            Send-Json -Ctx $Ctx -Object @(Read-CsvSafe -Path $file -RequireColumn 'Timestamp')
            return
        }
        '^/api/live$' {
            if (-not (Test-Path $livePath)) { Send-Empty -Ctx $Ctx; return }
            $rows = @(Read-CsvSafe -Path $livePath -RequireColumn 'Timestamp')
            if ($rows.Count -eq 0) { Send-Empty -Ctx $Ctx; return }
            Send-Json -Ctx $Ctx -Object $rows
            return
        }
        '^/api/deploy$' {
            if ($Ctx.Request.HttpMethod -ne 'POST') {
                Send-Json -Ctx $Ctx -Object @{ error = 'POST only' } -Status 405
                return
            }
            $reader = New-Object System.IO.StreamReader($Ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd()
            try {
                Send-Json -Ctx $Ctx -Object (Start-Deployment -Body $body)
            } catch {
                Send-Json -Ctx $Ctx -Object @{ error = "$($_.Exception.Message)" } -Status 400
            }
            return
        }
        '^/favicon\.ico$' { Send-Empty -Ctx $Ctx; return }
        default {
            Send-Json -Ctx $Ctx -Object @{ error = 'not found' } -Status 404
        }
    }
}

# --- Main loop ------------------------------------------------------------------

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try {
    $listener.Start()
} catch {
    Write-Host ''
    Write-Host "  Port $Port is already in use (another InfraServerSetup or app is listening)." -ForegroundColor Red
    Write-Host '  Either close the other instance, or start on a different port:' -ForegroundColor Yellow
    Write-Host "    InfraServerSetup.cmd -Port $($Port + 1)" -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$url = "http://localhost:$Port/"
Write-Host ''
Write-Host '  InfraServerSetup' -ForegroundColor Cyan
Write-Host "  Serving:    $url"
Write-Host "  Deploy repo: $DeployRepo"
Write-Host "  Logs:        $logsDir"
Write-Host '  Ctrl+C to stop.'
Write-Host ''

if (-not $NoBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        $ctxTask = $listener.GetContextAsync()
        # Poll the wait handle so Ctrl+C stays responsive between requests.
        while (-not $ctxTask.AsyncWaitHandle.WaitOne(500)) { }
        $ctx = $ctxTask.GetAwaiter().GetResult()
        try {
            Invoke-Route -Ctx $ctx
        } catch {
            Write-Warning "Request $($ctx.Request.Url.AbsolutePath) failed: $_"
            try { Send-Json -Ctx $ctx -Object @{ error = "$_" } -Status 500 } catch { }
        } finally {
            # Never leave a connection half-open: a stranded response blocks the client.
            try { $ctx.Response.Close() } catch { }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    Write-Host 'InfraServerSetup stopped.'
}
