# BMC-to-Hypervisor Deploy

Automates server bring-up end to end -- from bare **IPMI/BMC** through firmware,
BIOS/RAID, BMC baseline, unattended **hypervisor install** (via BMC virtual
media), and **cluster join** -- driven from a Windows jumphost against a
CSV-defined server list.

This is the deployment layer that sits **on top of** the
[BMC Fleet Automation](../) baseline work (Dell iDRAC via `racadm`, Lenovo
XCC3 via `OneCLI`). It reuses the same conventions: CSV-driven per-host loop,
masked password prompt (never stored), timestamped per-host CSV logs,
**read-only audit first**, and confirm-before-change.

## Supported matrix

| BMC platform            | Tool     | Hypervisors                                  |
|-------------------------|----------|----------------------------------------------|
| Dell iDRAC              | `racadm` | ESXi, Proxmox VE, Azure Stack HCI / Hyper-V  |
| Lenovo ThinkAgile XCC3  | `OneCLI` | AHV (Foundation), ESXi, Proxmox, Hyper-V     |

## Pipeline stages

```
readiness  ->  firmware  ->  bios  ->  bmc-baseline  ->  install  ->  clusterjoin
(read-only)   (vendor fw)  (BIOS/RAID) (DNS/NTP/etc)   (virt media)  (join mgr)
```

- **readiness** -- read-only audit: reachability, BMC port, auth, firmware. Runs
  first and is also standalone (`stages\Test-DeployReadiness.ps1`). Touches nothing.
- **firmware** -- vendor firmware update (Dell catalog / Lenovo UXSP). *Stub -- wire to your repo.*
- **bios** -- apply BIOS/RAID profile (boot mode, power, virtual disk). *Stub.*
- **bmc-baseline** -- DNS/NTP/Timezone/Secure Syslog/Alerts. **Dell is
  production-tested** — the confirmed iDRAC logic is ported into the provider
  (`Invoke-DellBmcBaseline`) from `platforms/dell/Set-iDRAC-NTP-Syslog-Alerts.ps1`;
  see [`docs/README-iDRAC-Automation.md`](docs/README-iDRAC-Automation.md). XCC3
  baseline is still IN DESIGN (syslog attr mapping BLOCKING — see CLAUDE.md).
- **install** -- mount install ISO via BMC virtual media, set one-time boot,
  power-cycle. AHV instead triggers **Nutanix Foundation** imaging over IPMI.
- **clusterjoin** -- poll until the hypervisor is up, then join vCenter / Prism /
  Proxmox cluster / failover cluster. *Join verbs stubbed pending live hardware.*

## InfraServerSetup — web dashboard & launcher

[`InfraServerSetup\`](InfraServerSetup/) is a Foundation-style local web UI on
top of this pipeline: double-click `InfraServerSetup\InfraServerSetup.cmd` and
a browser opens on `http://localhost:8474/` with

- **live per-node stage progress** during a run (plus full run history,
  per-host timelines, and a failure-triage worklist),
- **Fleet Setup** — build `config\servers.csv` by pasting the server table
  straight from Excel (validated), and
- **Deploy** — pick hosts/stages and launch `Invoke-Deployment.ps1` from the
  browser (credentials go to the localhost server only and reach the pipeline
  via in-memory environment variables; web launches run `-Force`, with a
  two-step confirm in the UI instead of console gates).

See [`InfraServerSetup\README.md`](InfraServerSetup/README.md) for details and
the demo mode (`tools\New-SampleData.ps1`). The console workflow below works
unchanged with or without the dashboard.

## Quick start

```powershell
# 1. Copy and edit the inventory + config
Copy-Item .\config\servers.csv.example .\config\servers.csv
Copy-Item .\config\deploy.config.psd1  .\config\deploy.config.psd1   # edit values

# 2. ALWAYS run the read-only readiness audit first, every time
.\stages\Test-DeployReadiness.ps1 -ServerList .\config\servers.csv

# 3. Dry-run the whole pipeline (no changes anywhere)
.\Invoke-Deployment.ps1 -ServerList .\config\servers.csv -WhatIf

# 4. Run a specific range of stages (prompts to confirm each change)
.\Invoke-Deployment.ps1 -ServerList .\config\servers.csv -FromStage bmc-baseline -ToStage install

# 5. Run selected stages unattended (skips confirmation -- use with care)
.\Invoke-Deployment.ps1 -ServerList .\config\servers.csv -Stages readiness,install -Force
```

## Inventory (`config\servers.csv`)

Required columns: `IP, Hostname, Platform (dell|lenovo), Hypervisor (esxi|ahv|proxmox|hyperv)`.
Optional columns (`Rack`, `BiosProfile`, `Cluster`, ...) pass through untouched.
The real `servers.csv` is git-ignored; only `servers.csv.example` is committed.

## Layout

```
Invoke-Deployment.ps1          Master orchestrator (staged per-host pipeline)
config/
  servers.csv.example          Inventory template
  deploy.config.psd1           Global settings (DNS/NTP, ISOs, clusters, firmware)
stages/
  Test-DeployReadiness.ps1     READ-ONLY audit (run first, every time)
lib/
  Common.psm1                  Logging, masked creds, CSV loader, port checks, confirm gate
  Providers/                   BMC wrappers: Dell.iDRAC (racadm), Lenovo.XCC3 (onecli)
  Hypervisors/                 ESXi (PowerCLI), AHV (Foundation), Proxmox (API), AzureStackHCI (WinRM)
templates/                     Unattended install answer files (ks.cfg, answer.toml, ...)
docs/Pipeline-Design.md        Stage design, gating, and what needs live-hardware verification
logs/                          Timestamped per-run CSV logs (git-ignored)
```

## Status & safety

- Platform-independent plumbing (orchestrator, logging, readiness, CSV, confirm,
  virtual-media boot control) is **working**.
- **Dell iDRAC BMC baseline is production-tested** (DNS/NTP/Timezone/Secure
  Syslog + CA cert upload/Alerts), ported from the proven standalone scripts in
  `platforms/dell/`.
- Hardware-specific verbs marked `TODO(live-hardware)` or `stub` must be
  **verified against a single live host before fleet rollout** -- same discipline
  as the BMC Fleet Automation repo. Never trust an attribute path or vendor
  command until confirmed against real output.
- No secrets are committed. The BMC password is prompted once per run as a
  masked `SecureString` and decrypted only at the moment of a CLI call.

See [`docs/Pipeline-Design.md`](docs/Pipeline-Design.md) and `CLAUDE.md` for details.
