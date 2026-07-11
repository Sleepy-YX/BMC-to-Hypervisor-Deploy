@{
    # Global deployment settings. No secrets here -- the BMC password is prompted
    # once per run and never stored. Edit paths/values for your environment.

    # BMC baseline (consumed by the bmc-baseline stage / existing iDRAC scripts)
    Baseline = @{
        Dns      = @('10.0.0.1', '10.0.0.2')
        Ntp      = @('10.0.0.1', 'pool.ntp.org')
        Timezone = 'Asia/Singapore'         # IANA format (iDRAC.Time.Timezone)
        Syslog   = @('10.0.0.50')           # remote syslog target(s)
    }

    # Install ISOs per hypervisor. Must be reachable by the BMC as virtual media
    # (SMB/NFS/HTTP depending on platform). AHV is imaged by Foundation instead.
    Iso = @{
        esxi    = 'https://deploy.local/iso/VMware-ESXi-8.0U2-custom.iso'
        proxmox = 'https://deploy.local/iso/proxmox-ve_8.2-auto.iso'
        hyperv  = 'https://deploy.local/iso/AzureStackHCI-23H2.iso'
    }

    # Unattended answer files (served over HTTP and referenced by the installer)
    AnswerFiles = @{
        esxi    = 'https://deploy.local/answer/ks.cfg'
        proxmox = 'https://deploy.local/answer/answer.toml'
        hyperv  = 'https://deploy.local/answer/autounattend.xml'
    }

    # Cluster / manager endpoints for the clusterjoin stage
    Clusters = @{
        VCenter    = 'vcenter.local'
        Foundation = 'http://foundation.local:8000'
        ProxmoxPeer = '10.0.30.30'
    }

    # Firmware repositories for the firmware stage
    Firmware = @{
        DellCatalog   = 'https://deploy.local/dell/catalog.xml'
        LenovoBundle  = 'https://deploy.local/lenovo/uxsp/'
    }
}
