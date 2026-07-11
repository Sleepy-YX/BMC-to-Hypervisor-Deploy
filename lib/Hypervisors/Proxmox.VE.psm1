<#
.SYNOPSIS
    Proxmox VE hypervisor module.

    Install path: automated install using the Proxmox "answer file" (answer.toml)
    with the auto-install-assistant, baked into the ISO or served via a fetch URL,
    booted through BMC virtual media. See templates\proxmox-answer.toml.example.

    Post-install / cluster-join uses the Proxmox REST API (pvesh over HTTPS :8006).
#>

Set-StrictMode -Version Latest

function Test-ProxmoxInstalled {
    <# Poll the PVE web/API until it answers on 8006. Read-only. #>
    param([string]$IP, [int]$TimeoutMinutes = 30)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -IP $IP -Port 8006) { return $true }
        Start-Sleep -Seconds 30
    }
    return $false
}

function Get-ProxmoxTicket {
    <# Authenticate to the PVE API and return the ticket + CSRF token. #>
    param([string]$IP, [pscredential]$Credential, [string]$Realm = 'pam')
    $pass = ConvertTo-PlainText -Secure $Credential.Password
    try {
        $body = @{ username = "$($Credential.UserName)@$Realm"; password = $pass }
        # Note: self-signed cert on a fresh node -- caller runs on PS7 (-SkipCertificateCheck)
        # or PS5.1 with a session cert-callback. Handled by the orchestrator's HTTPS helper.
        $resp = Invoke-RestMethod -Method Post -Uri "https://$IP`:8006/api2/json/access/ticket" `
                                  -Body $body -ErrorAction Stop
        return [pscustomobject]@{
            Ticket = $resp.data.ticket
            CSRF   = $resp.data.CSRFPreventionToken
        }
    }
    finally { $pass = $null }
}

function Join-ProxmoxCluster {
    <#
        Join a fresh node to an existing Proxmox cluster.
        TODO(live-hardware): joining a cluster is typically done over SSH with
        `pvecm add <existing-node>` and the cluster join info/fingerprint, because
        the API join flow needs the peer's join token. Confirm the chosen flow
        (SSH pvecm vs API /cluster/config/join) for your environment.
    #>
    param(
        [Parameter(Mandatory)][string]$NewNodeIP,
        [Parameter(Mandatory)][string]$ClusterPeerIP,
        [Parameter(Mandatory)][pscredential]$RootCredential
    )
    return [pscustomobject]@{
        Ok      = $false
        Message = "Not yet implemented -- choose SSH `pvecm add $ClusterPeerIP` on $NewNodeIP or the API join flow, then wire it here."
    }
}

Export-ModuleMember -Function Test-ProxmoxInstalled, Get-ProxmoxTicket, Join-ProxmoxCluster
