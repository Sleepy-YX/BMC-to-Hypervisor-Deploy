<#
.SYNOPSIS
    Nutanix AHV hypervisor module (ThinkAgile HX as Nutanix appliance).

    Imaging model differs from raw kickstart: AHV nodes are provisioned with
    Nutanix Foundation (bare-metal imaging over IPMI), not a per-host ISO+ks.cfg.
    This module drives Foundation via its REST API and then verifies Prism.

    Foundation exposes a REST API on the Foundation VM/CVM (default :8000). The
    pipeline hands Foundation the node's IPMI IP + creds and lets it image; the
    BMC virtual-media stage is therefore skipped for Hypervisor=ahv (see the
    orchestrator's stage gating).

    TODO(live-hardware): confirm Foundation API base path and image-node payload
    against the Foundation version in use before first fleet run.
#>

Set-StrictMode -Version Latest

function Test-PrismReachable {
    <# Poll Prism Element on the CVM/host until it answers on 9440. Read-only. #>
    param([string]$IP, [int]$TimeoutMinutes = 45)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -IP $IP -Port 9440) { return $true }
        Start-Sleep -Seconds 30
    }
    return $false
}

function Start-FoundationImaging {
    <#
        Kick off Foundation bare-metal imaging for a node.
        $FoundationUrl e.g. http://<foundation-vm>:8000
        TODO(live-hardware): finalize payload schema (blocks/nodes/hypervisor_iso)
        against Foundation API docs for the deployed version.
    #>
    param(
        [Parameter(Mandatory)][string]$FoundationUrl,
        [Parameter(Mandatory)][string]$IpmiIP,
        [Parameter(Mandatory)][pscredential]$IpmiCredential,
        [Parameter(Mandatory)][hashtable]$NodeSpec
    )
    Write-Warning "Start-FoundationImaging: Foundation API payload UNCONFIRMED -- verify before live use."
    $body = @{
        ipmi_ip       = $IpmiIP
        ipmi_user     = $IpmiCredential.UserName
        ipmi_password = (ConvertTo-PlainText -Secure $IpmiCredential.Password)
        node          = $NodeSpec
    } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$FoundationUrl/foundation/v1/image_nodes" `
                                  -ContentType 'application/json' -Body $body -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; SessionId = $resp.session_id; Message = 'Foundation imaging started.' }
    }
    catch { return [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message } }
    finally { $body = $null }
}

Export-ModuleMember -Function Test-PrismReachable, Start-FoundationImaging
