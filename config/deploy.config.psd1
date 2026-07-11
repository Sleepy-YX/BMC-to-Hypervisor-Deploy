@{
    # Global deployment settings. No secrets here -- the BMC password is prompted
    # once per run and never stored. Edit paths/values for your environment.

    # BMC baseline -- consumed by Invoke-DellBmcBaseline (bmc-baseline stage).
    # Keys map 1:1 to the confirmed iDRAC operations ported from
    # platforms\dell\Set-iDRAC-NTP-Syslog-Alerts.ps1.
    Baseline = @{
        Dns1             = '10.0.0.1'
        Dns2             = '10.0.0.2'                 # optional; iDRAC IPv4 has DNS1/DNS2 only
        Ntp1             = '10.0.0.1'
        Ntp2             = 'pool.ntp.org'             # NTP2 may be an FQDN
        Timezone         = 'Asia/Singapore'          # IANA format (idrac.Time.Timezone)
        SyslogServer     = '10.0.0.50'               # SECURE syslog, single target (platform limit)
        SyslogCaCertPath = '.\config\syslog-ca.pem'  # REQUIRED for Dell Secure Syslog (sslcertupload -t 12)
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
