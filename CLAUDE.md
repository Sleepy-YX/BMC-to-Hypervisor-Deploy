# BMC-to-Hypervisor Deploy -- Project Context

## Purpose
End-to-end server deployment automation: from bare **IPMI/BMC** up to a running,
cluster-joined **hypervisor**, run from a Windows jumphost against a CSV-defined
server list. This is the deployment layer built on top of the **BMC Fleet
Automation** repo (which stops at BMC baseline config).

- **BMC platforms:** Dell iDRAC (`racadm`), Lenovo ThinkAgile HX650 V3 / XCC3 (`OneCLI`)
- **Hypervisors:** VMware ESXi/vSphere, Nutanix AHV, Proxmox VE, Azure Stack HCI/Hyper-V

## Pipeline
`readiness -> firmware -> bios -> bmc-baseline -> install -> clusterjoin`
Driven by `Invoke-Deployment.ps1`. Read-only audit is `stages\Test-DeployReadiness.ps1`.

Log contract the dashboard depends on: readiness logs ONE consolidated
`readiness` row per host plus `fact:<Name>` rows (Status `INFO`, read-only
inventory); the fleet grid joins on lowercase stage names and INFO rows never
affect stage status cells. `Invoke-Deployment.ps1 -BaselineFile <json>`
overrides the config's Baseline section for one run (the web Deploy tab writes
it to `config\baseline.web.json`; no secrets in it).

## Conventions (apply to all new work)
- CSV-driven per-host loop (`config\servers.csv`), columns: IP, Hostname,
  Platform (dell|lenovo), Hypervisor (esxi|ahv|proxmox|hyperv), + optional pass-through.
- Masked password prompt, entered once per run, never stored (SecureString;
  decrypt only at the moment of a CLI call).
- Per-host status to a timestamped CSV (`logs\deploy_log_<timestamp>.csv`) plus
  a console summary table.
- **Always run the read-only audit first**, before any changing stage; verify
  new platform/stage work against ONE live host before enabling it for the fleet.
- Changing stages show a summary of intended changes and confirm before touching
  hardware (`-Force` to skip, `-WhatIf` for a full dry run).
- Confirmed attribute names / gotchas get written into `docs\` as they're found
  (load-bearing, don't re-derive). Dell/racadm specifics live in
  `docs/README-iDRAC-Automation.md`. One principle worth keeping inline: BMC
  CLIs can return exit 0 while partially failing -- inspect output TEXT for
  failure strings, never trust exit code alone.

## Status
**Dell BMC baseline: production-tested** -- `lib/Providers/Dell.iDRAC.psm1`
(`Invoke-DellBmcBaseline`), confirmed attributes in
`docs/README-iDRAC-Automation.md`. Also working: orchestrator + stage gating,
masked creds, CSV load/validate, readiness, logging, confirm gate, Dell
virtual-media boot control.

**Needs live-hardware verification before fleet use** (search `TODO(live-hardware)`
and `stub`): firmware update, BIOS/RAID profile apply, XCC3 virtual-media +
boot-order syntax, Nutanix Foundation API payload, Proxmox/Azure Stack HCI
cluster-join verbs.

**Inherited BLOCKING item:** XCC3 syslog attribute mapping is unconfirmed -- likely
routes through `BMC.RemoteAlertRecipient*` rather than a dedicated `BMC.SysLog*`.
Confirm with `onecli config show BMC.RemoteAlertRecipientMethod_1` on real hardware
before wiring the XCC3 bmc-baseline path.

## InfraServerSetup dashboard (InfraServerSetup\)
Local web UI over this pipeline (PowerShell 5.1 HttpListener + self-contained
vanilla-JS SPA, localhost-only, port 8474). Reads servers.csv + deploy_log CSVs +
deploy.config.psd1 Baseline (GET /api/baseline prefills the Deploy tab's
BMC-baseline form); its only writes are config\servers.csv (Fleet Setup, with
.bak), config\servers.deploy.csv (web-launched host subset), and
config\baseline.web.json (per-run baseline override, passed via -BaselineFile).
Coupled to this repo in two places in lib\Common.psm1 -- keep them in sync with
the dashboard:
- Add-LogRow write-through to logs\deploy_log_live.csv (live view); removed by
  Save-DeployLog on finalize. Must stay non-fatal.
- Read-BmcCredential consumes INFRASERVERSETUP_BMC_USER/PASS env vars (web-launch
  credential path; consumed and cleared on first read, never on command line/disk).
Web launches run Invoke-Deployment with -Force; the UI has a two-step confirm.

## Tools & environment
- `racadm` (Dell), `OneCLI` (Lenovo); PowerCLI (ESXi), REST/Foundation (AHV),
  PVE API (Proxmox), WinRM/FailoverClustering (Azure Stack HCI).
- Windows PowerShell on a Windows jumphost -- execution environment.
