<#
.SYNOPSIS
    VMware ESXi / vSphere hypervisor module.

    Install path: unattended ESXi via a kickstart (ks.cfg) served over HTTP and
    referenced by the installer boot options, booted through BMC virtual media.
    See templates\esxi-ks.cfg.example.

    Post-install / cluster-join uses PowerCLI (VMware.PowerCLI). It is an optional
    dependency -- the pipeline degrades gracefully with a WARN if it is absent.
#>

Set-StrictMode -Version Latest

function Test-EsxiInstalled {
    <# Poll the host until the ESXi management stack answers on 443. Read-only. #>
    param([string]$IP, [int]$TimeoutMinutes = 30)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -IP $IP -Port 443) { return $true }
        Start-Sleep -Seconds 30
    }
    return $false
}

function Join-EsxiToVcenter {
    <#
        Add a freshly installed ESXi host to a vCenter cluster via PowerCLI.
        Requires VMware.PowerCLI. $VcenterCredential and $HostCredential are
        separate (vCenter SSO vs the host root password).
    #>
    param(
        [Parameter(Mandatory)][string]$EsxiIP,
        [Parameter(Mandatory)][string]$VCenter,
        [Parameter(Mandatory)][pscredential]$VcenterCredential,
        [Parameter(Mandatory)][pscredential]$HostCredential,
        [Parameter(Mandatory)][string]$Cluster,
        [string]$Datacenter
    )
    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
        return [pscustomobject]@{ Ok = $false; Message = 'VMware.PowerCLI not installed (Install-Module VMware.PowerCLI).' }
    }
    Import-Module VMware.PowerCLI -ErrorAction Stop
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
    try {
        Connect-VIServer -Server $VCenter -Credential $VcenterCredential -ErrorAction Stop | Out-Null
        $added = Add-VMHost -Name $EsxiIP -Location $Cluster -Credential $HostCredential `
                            -Force -Confirm:$false -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Message = "Added $EsxiIP to cluster $Cluster." }
    }
    catch { return [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message } }
    finally { Disconnect-VIServer -Server $VCenter -Confirm:$false -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function Test-EsxiInstalled, Join-EsxiToVcenter
