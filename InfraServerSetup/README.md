# InfraServerSetup

Foundation-style local dashboard for the **BMC-to-Hypervisor-Deploy** pipeline.
Launch one script, a browser opens on `http://localhost:8474/`, and you watch
nodes progress through the deployment stages (`readiness → firmware → bios →
bmc-baseline → install → clusterjoin`) — live during a run, plus full
historical review afterwards.

InfraServerSetup is **read-only** over the deploy repo: it parses
`config\servers.csv` and `logs\deploy_log_*.csv` and never touches hardware or
pipeline state. The server binds to `localhost` only.

InfraServerSetup never touches hardware. Its only write is `config\servers.csv`
when you save from the Fleet Setup screen (the previous file is kept as
`servers.csv.bak`).

## Quick start (against the real deploy repo)

Double-click **`InfraServerSetup.cmd`**. The deploy repo is auto-detected: InfraServerSetup
works either embedded inside it (`BMC-to-Hypervisor-Deploy\InfraServerSetup\`) or as
a sibling folder next to it. Or from PowerShell:

```powershell
.\Start-InfraServerSetup.ps1
```

Options: `-DeployRepo <path>` (any folder containing `logs\` +
`config\servers.csv`), `-Port <n>` (default 8474), `-NoBrowser`.
The `.cmd` passes arguments through: `InfraServerSetup.cmd -DeployRepo .\sample`.

## Demo with sample data (no hardware needed)

```powershell
.\tools\New-SampleData.ps1 -Mode History   # writes .\sample\ with a fleet + 6 runs
.\Start-InfraServerSetup.ps1 -DeployRepo .\sample

# In a second console - simulate an in-progress run and watch the live view:
.\tools\New-SampleData.ps1 -Mode Live
```

## Views

- **Fleet Grid** — hosts × stages matrix with the latest status per cell
  (✓ OK / ! WARN / ✕ FAIL / » SKIP), per-host progress bar, filters by
  platform / hypervisor / cluster / rack. Click a cell for the full message;
  hover a stage column header for what that stage does. Under each hostname
  the grid shows the inventory captured by the readiness stage (model, serial,
  BIOS, BMC firmware — logged as `fact:*` INFO rows), newest run wins.
- **Run History** — every run with OK/WARN/FAIL/SKIP counts; click to expand
  the full row log. Includes "failures by stage" and "repeat-offender hosts"
  stats across all runs.
- **Host Timeline** — one host's complete history across all runs,
  chronologically. Click any hostname anywhere to jump here.
- **Triage** — all current FAIL/WARN cells grouped by stage: the
  "fix this before re-running" worklist.
- **Fleet Setup** — edit the fleet in a table, or paste rows straight from
  Excel (header names like "iDRAC IP" / "Vendor" are matched automatically;
  without a header row the standard column order is assumed). Validates IPs,
  duplicates, and platform/hypervisor values, then saves `config\servers.csv`.
- **Deploy** — pick hosts and stages (each with a one-line description), enter
  the BMC credentials, and launch `Invoke-Deployment.ps1` with one click
  (two-step confirm). Selecting the bmc-baseline stage opens a form for the
  DNS / NTP / timezone / syslog values, prefilled from the repo's
  `deploy.config.psd1`; your edits apply to that run only — they are written
  to `config\baseline.web.json` and passed via `-BaselineFile` (the config
  file itself is never modified). The host selection is written to
  `config\servers.deploy.csv` so the master `servers.csv` is never touched by
  a partial run; a minimized PowerShell window opens for the run (restore it
  to watch raw output or Ctrl+C to abort).

## Deploy-from-web security model

- Credentials post only to this localhost server and reach the pipeline via
  process-scoped environment variables around the spawn — never a command
  line, never a file, never a log. `Read-BmcCredential` consumes and clears
  them on first read.
- Web launches run `-Force` (no console confirm gates); the UI's explicit
  two-step confirmation replaces them. If you want the console confirmations
  back, launch from PowerShell instead — both paths coexist.
- All POSTs require the `X-InfraServerSetup` header, which browsers refuse to attach
  cross-origin without a CORS preflight (never granted) — so a malicious web
  page cannot fire deployments at your localhost server.

## Live monitoring

The dashboard polls `logs\deploy_log_live.csv` every 3 seconds. That file is
written by a small write-through patch in the deploy repo's `lib\Common.psm1`:
`Add-LogRow` appends each row to it as it happens (non-fatal on error), and
`Save-DeployLog` removes it once the run's timestamped CSV is finalized. If the
patch isn't present, everything still works — you just see runs when they
finish instead of as they happen.

## API (all read-only JSON)

| Endpoint | Returns |
|---|---|
| `GET /api/fleet` | parsed `servers.csv` |
| `GET /api/baseline` | Baseline section of `deploy.config.psd1` (blank fields if absent) |
| `POST /api/fleet` | validate + save fleet to `servers.csv` (backs up previous) |
| `POST /api/deploy` | launch `Invoke-Deployment.ps1` for selected hosts/stages |
| `GET /api/runs` | run summaries (id, counts, hosts, start/end) |
| `GET /api/runs/{id}` | all rows of one run |
| `GET /api/live` | rows of the in-progress run, or `204` if none |

## Out of scope (deliberately)

- Remote access / auth — localhost only by design. Never expose this server
  beyond localhost: the Deploy tab accepts BMC credentials.
