# Pipeline Design

## Goal
One repeatable, auditable path that takes a rack of servers from powered-on BMCs
to hypervisors joined to their clusters -- across two BMC platforms (Dell iDRAC,
Lenovo XCC3) and four hypervisors (ESXi, AHV, Proxmox, Azure Stack HCI/Hyper-V).

## Stage order and why

| # | Stage         | Changes HW? | Notes |
|---|---------------|-------------|-------|
| 1 | readiness     | No          | Gate. Reachability/auth/firmware. Abort host on FAIL. |
| 2 | firmware      | Yes         | Do firmware before BIOS so new BIOS options exist. |
| 3 | bios          | Yes         | Boot mode (UEFI), power profile, RAID/virtual disk. |
| 4 | bmc-baseline  | Yes         | DNS/NTP/Timezone/Syslog/Alerts. Independent of OS. |
| 5 | install       | Yes         | Virtual-media unattended install (or Foundation for AHV). |
| 6 | clusterjoin   | Yes         | Poll until up, then join manager/cluster. |

Rationale: firmware first (unlocks BIOS settings and fixes known IPMI bugs),
then persistent hardware config, then OS. BMC baseline is slotted before install
so a half-deployed host still has correct DNS/NTP/syslog for troubleshooting.

## Stage gating by hypervisor

- **AHV** skips the virtual-media `install` path. Nutanix Foundation images nodes
  over IPMI directly, so the orchestrator branches to `Start-FoundationImaging`
  instead of `Set-*BootToVirtualMedia`.
- **ESXi / Proxmox / Hyper-V** use per-host ISO + answer file via BMC virtual
  media (`templates/`).

## Install mechanism per hypervisor

| Hypervisor | Answer file        | Delivery                              | Join                         |
|------------|--------------------|---------------------------------------|------------------------------|
| ESXi       | `ks.cfg`           | HTTP `ks=` boot option, virtual media | PowerCLI `Add-VMHost`        |
| Proxmox    | `answer.toml`      | auto-install-assistant ISO/fetch      | `pvecm add` (SSH) or API     |
| Hyper-V    | `autounattend.xml` | Windows unattend, virtual media       | `New-Cluster` (WinRM)        |
| AHV        | Foundation config  | Foundation bare-metal imaging (IPMI)  | Prism cluster create         |

## What is working vs. what needs live hardware

**Working now (platform-independent):**
- Orchestrator stage sequencing, `-WhatIf`, `-Force`, `-FromStage/-ToStage/-Stages`
- Masked credential handling (SecureString, decrypt only at CLI call)
- CSV inventory load + validation
- Read-only readiness: ping, TCP port probe, BMC auth read
- Timestamped CSV logging + console summary
- Confirm-before-change gate
- Dell virtual-media boot control (racadm remoteimage + one-time boot)

**Needs verification against a single live host before fleet use (`TODO(live-hardware)` / `stub`):**
- Firmware update commands (Dell catalog update, Lenovo UXSP flash)
- BIOS/RAID profile application (SCP import / onecli config set)
- XCC3 virtual-media + boot-order OneCLI syntax (attribute paths UNCONFIRMED)
- XCC3 BMC baseline syslog mapping -- BLOCKING open question inherited from the
  BMC Fleet Automation repo (`onecli config show BMC.RemoteAlertRecipientMethod_1`)
- Nutanix Foundation API payload schema
- Cluster-join verbs for Proxmox and Azure Stack HCI

## Hard-won rules carried over (do not relearn)
1. `--nocertwarn` on every racadm call -- cert banners break output parsing.
2. Some vendor commands return exit 0 while partially failing -- inspect output
   TEXT for failure strings, never trust exit code alone.
3. Enum attributes often take string values (`Enabled`/`Disabled`), not `1`/`0` --
   check `get`/`config show` output format before assuming.
4. PowerShell: brace variable names before a colon (`"${status}: $cmd"`), and
   don't embed a second statement inside an if/else-as-expression.

## Rollout discipline
1. Run `Test-DeployReadiness.ps1` against the whole batch.
2. Prove each changing stage against ONE live host of each platform/hypervisor.
3. Only then run the batch, stage by stage, watching the summary table + CSV log.
