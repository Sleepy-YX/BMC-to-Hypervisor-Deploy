<#
.SYNOPSIS
    Azure Stack HCI / Hyper-V hypervisor module.

    Install path: unattended Windows install (AzSHCI OS or Windows Server + Hyper-V)
    via an autounattend.xml answer file, booted through BMC virtual media, then
    OS-level configuration over WinRM/PowerShell Remoting.

    Cluster join for Azure Stack HCI is a multi-step process (network intent,
    cluster validation, registration with Azure Arc). This module covers the
    on-prem cluster steps; Azure registration is intentionally out of scope here
    because it needs an Azure sign-in the pipeline should not perform unattended.
#>

Set-StrictMode -Version Latest

function Test-WinRmReachable {
    <# Poll the host until WinRM (5985/5986) answers. Read-only. #>
    param([string]$IP, [int]$TimeoutMinutes = 40, [switch]$Https)
    $port = if ($Https) { 5986 } else { 5985 }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -IP $IP -Port $port) { return $true }
        Start-Sleep -Seconds 30
    }
    return $false
}

function Enable-HyperVRole {
    <#
        Enable the Hyper-V role on a freshly installed Windows host over PS Remoting.
        Requires the host in TrustedHosts (or a domain) and reachable WinRM.
    #>
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][pscredential]$AdminCredential
    )
    try {
        $out = Invoke-Command -ComputerName $IP -Credential $AdminCredential -ErrorAction Stop -ScriptBlock {
            $r = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
            [pscustomobject]@{ Success = $r.Success; RestartNeeded = "$($r.RestartNeeded)" }
        }
        return [pscustomobject]@{ Ok = $out.Success; Message = "Hyper-V install: Success=$($out.Success), RestartNeeded=$($out.RestartNeeded)" }
    }
    catch { return [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message } }
}

function New-AzsHciCluster {
    <#
        Create the failover cluster from a set of validated nodes.
        TODO(live-hardware): run Test-Cluster first and confirm network ATC intent
        naming for your switches before enabling. Azure Arc registration is a
        separate, interactive step and is deliberately NOT automated here.
    #>
    param(
        [Parameter(Mandatory)][string[]]$NodeNames,
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$StaticIP,
        [Parameter(Mandatory)][pscredential]$AdminCredential
    )
    return [pscustomobject]@{
        Ok      = $false
        Message = "Not yet implemented -- run Test-Cluster on [$($NodeNames -join ', ')], then New-Cluster -Name $ClusterName -StaticAddress $StaticIP. Wire in after validation passes on live nodes."
    }
}

Export-ModuleMember -Function Test-WinRmReachable, Enable-HyperVRole, New-AzsHciCluster
