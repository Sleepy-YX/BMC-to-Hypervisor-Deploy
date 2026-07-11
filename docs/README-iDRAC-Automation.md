# Dell iDRAC Automation — Confirmed Reference

Status: **production-tested** (test host 10.10.10.31, firmware 7.20.60.50, Enterprise).
Source of truth: [`platforms/dell/Set-iDRAC-NTP-Syslog-Alerts.ps1`](../platforms/dell/Set-iDRAC-NTP-Syslog-Alerts.ps1)
(config) and [`platforms/dell/Test-iDRACReadiness.ps1`](../platforms/dell/Test-iDRACReadiness.ps1)
(read-only audit). The same logic is ported into
[`lib/Providers/Dell.iDRAC.psm1`](../lib/Providers/Dell.iDRAC.psm1) so the pipeline
runs it per-host. **Keep the two in sync** — don't change an attribute name/value
in the module without re-confirming on hardware.

## Confirmed racadm attributes

| Setting | Attribute | Value format | Notes |
|---|---|---|---|
| DNS 1 / 2 | `idrac.IPv4.DNS1` / `.DNS2` | IPv4 | IPv4 group has DNS1/DNS2 only (no DNS3) |
| NTP enable | `idrac.NTPConfigGroup.NTPEnable` | **`1` / `0`** | integer, **not** Enabled/Disabled |
| NTP 1 / 2 | `idrac.NTPConfigGroup.NTP1` / `.NTP2` | IP or FQDN | NTP2 optional |
| Timezone | `idrac.Time.Timezone` | IANA string | e.g. `Asia/Singapore` |
| Master alert switch | `idrac.IPMILan.AlertEnable` | `Enabled`/`Disabled` | **gates ALL alerts** — set first |
| Basic syslog enable | `idrac.SysLog.SysLogEnable` | `Enabled`/`Disabled` | we **Disable** it (Secure mode used) |
| Basic syslog server | `idrac.SysLog.Server1` | IPv4 | not used when Secure is on |
| Secure syslog enable | `idrac.SysLog.SecureSysLogEnable` | `Enabled`/`Disabled` | string, not `1`/`0` |
| Secure syslog server | `idrac.SysLog.SecureServer1` | IPv4 | **single target only** (platform limit) |
| Secure syslog port | `idrac.SysLog.SecurePort` | int | default 6514, left as-is |

### Alerts (eventfilters)
```
eventfilters set -c idrac.alert.<category>.<severity> -a none -n snmp,remotesyslog
```
- Categories: `system`, `storage`, `updates`, `audit`, `config`
- Severities: `critical`, `warning`
- Notifications: `snmp,remotesyslog`

### CA certificate for Secure Syslog
```
racadm sslcertupload -t 12 -f <ca.pem>     # type 12 = Rsyslog Server CA Cert
```
Must be uploaded **before** enabling Secure Syslog. Type 8 is Telemetry's separate
Rsyslog CA (Datacenter license) — **not** this.

## Hard-won gotchas (do not relearn)
1. **`--nocertwarn` on every call** — cert banners otherwise break output parsing.
2. **`eventfilters` fails silently** — returns exit 0 while reporting "Few alert
   settings have failed" in text. Inspect output text; report PARTIAL, not FAIL.
   ("some events will not support a given notification type" is normal.)
3. **Enum values are not uniform** — most are `Enabled`/`Disabled`, but `NTPEnable`
   is `1`/`0`. Check `get` output format per attribute before assuming.
4. **RAC1019 on SecureSysLogEnable = missing CA cert**, not wrong firmware/license.
   Upload the type-12 CA cert first; cert upload can restart the cert store, so
   pause ~5s before the enable step. If cert upload fails, skip the enable to
   avoid a repeat RAC1019.
5. **Master alert switch** `idrac.IPMILan.AlertEnable` must be `Enabled` first — no
   eventfilter fires without it.
6. PowerShell: `"${status}: $cmd"` not `"$status: $cmd"` (colon breaks parsing).

## Ordering (as executed by `Invoke-DellBmcBaseline`)
1. DNS → 2. Master alert (Enabled) → 3. NTP → 4. Timezone →
5. Secure Syslog (cert upload → 5s → SecureServer1 → SecureSysLogEnable → disable Basic → verify) →
6. Alerts (eventfilters, all categories × critical/warning).

## Readiness reads (`Test-iDRACReadiness.ps1` / `Get-iDRACInfo`)
`getversion` (auth + firmware), `get idrac.Info.Product` (license/product),
`idrac.IPv4.DHCPEnable`, `DNS1/DNS2`, `NIC.DNSRegister`, `NTPConfigGroup.*`,
`SysLog.*` (full group dump), `SSH.Enable`, `Telnet.Enable`, `VNCServer.Enable`.
Makes **no** changes.
