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

## Conventions (inherited -- apply to all new work)
- CSV-driven per-host loop (`config\servers.csv`), columns: IP, Hostname,
  Platform (dell|lenovo), Hypervisor (esxi|ahv|proxmox|hyperv), + optional pass-through.
- Masked password prompt, entered once per run, never stored (SecureString;
  decrypt only at the moment of a CLI call).
- Per-host status logged to a timestamped CSV (`logs\deploy_log_<timestamp>.csv`)
  plus a console summary table.
- **Always build/run the read-only audit first**, before any changing stage,
  every time.
- Changing stages show a summary of intended changes and confirm before touching
  hardware (`-Force` to skip, `-WhatIf` for a full dry run).
- Confirmed attribute names / gotchas get written into `docs\` -- don't re-derive
  things already solved.

## Hard-won gotchas to remember (from the Dell work; watch for XCC3 equivalents)
1. `--nocertwarn` on every racadm call -- cert banners break naive output parsing.
2. Some commands (e.g. `eventfilters`) return exit 0 while partially failing --
   inspect output TEXT for failure strings, never trust exit code alone.
3. Enum attributes often want string values (`Enabled`/`Disabled`), not `1`/`0` --
   check `get` / `config show` output format before assuming.
4. PowerShell: `"${status}: $cmd"` not `"$status: $cmd"` (colon breaks parsing);
   can't embed a second statement inside an if/else-as-expression.

## Status
**Working (platform-independent):** orchestrator + stage gating, masked creds,
CSV load/validate, read-only readiness (ping/port/auth), logging, confirm gate,
Dell virtual-media boot control.

**Needs live-hardware verification before fleet use** (search `TODO(live-hardware)`
and `stub`): firmware update, BIOS/RAID profile apply, XCC3 virtual-media +
boot-order syntax, Nutanix Foundation API payload, Proxmox/Azure Stack HCI
cluster-join verbs.

**Inherited BLOCKING item:** XCC3 syslog attribute mapping is unconfirmed -- likely
routes through `BMC.RemoteAlertRecipient*` rather than a dedicated `BMC.SysLog*`.
Confirm with `onecli config show BMC.RemoteAlertRecipientMethod_1` on real hardware
before wiring the XCC3 bmc-baseline path.

## Working style for this repo
- New platform/stage work: read-only path → verify against ONE live host →
  only then enable the changing step for the fleet.
- Iterate against a single live host before rollout.
- Document confirmed attribute names and fixes in `docs\` as they're found --
  treat these as load-bearing, not optional cleanup.

## Tools & environment
- `racadm` (Dell), `OneCLI` (Lenovo); PowerCLI (ESXi), REST/Foundation (AHV),
  PVE API (Proxmox), WinRM/FailoverClustering (Azure Stack HCI).
- Windows PowerShell on a Windows jumphost -- execution environment.
