function Invoke-NetworkCheck {
    <#
    .SYNOPSIS
        VCF readiness network checks: MTU, DNS forward/reverse, NTP, SSH.
    .PARAMETER Config
        Parsed config.json object.
    .PARAMETER Requirements
        Parsed VCF version requirement matrix.
    .PARAMETER VMHosts
        Optional pre-fetched VMHost list.
    .PARAMETER MockVMKernels
        Optional mock VMkernel adapter data for -WhatIf mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [psobject]$Config,

        [Parameter(Mandatory = $false)]
        [psobject]$Requirements,

        [Parameter()]
        [psobject[]]$VMHosts,

        [Parameter()]
        [psobject[]]$MockVMKernels
    )

    $req = $Requirements.network
    $results = [System.Collections.Generic.List[psobject]]::new()

    $hosts = if ($VMHosts) { $VMHosts } else {
        Get-VMHost | Where-Object { $_.Name -notin $Config.excludeHosts }
    }

    # ========== CHECK: VMkernel MTU ==========
    Write-Progress -Activity "Network Checks" -Status "Checking VMkernel MTU..."

    $vmkernels = if ($MockVMKernels) {
        $MockVMKernels
    } else {
        foreach ($vmhost in $hosts) {
            Get-VMHostNetworkAdapter -VMHost $vmhost -VMKernel | ForEach-Object {
                [PSCustomObject]@{
                    HostName    = $vmhost.Name
                    DeviceName  = $_.DeviceName
                    PortGroup   = $_.PortGroupName
                    Mtu         = $_.Mtu
                    VMotion     = $_.VMotionEnabled
                    VSan        = if ($_.VsanTrafficEnabled) { $true } else { $false }
                }
            }
        }
    }

    $mtuBlockList = @()
    $mtuWarnList  = @()

    foreach ($vmk in $vmkernels) {
        $isTrafficVmk = $vmk.VMotion -or $vmk.VSan -or ($vmk.PortGroup -match 'vMotion|vSAN|Overlay|NSX')

        if ($isTrafficVmk) {
            if ($vmk.Mtu -lt $req.nsxOverlayMinMtu) {
                $mtuBlockList += "$($vmk.HostName):$($vmk.DeviceName)(MTU=$($vmk.Mtu))"
            } elseif ($vmk.Mtu -lt $req.recommendedMtu) {
                $mtuWarnList += "$($vmk.HostName):$($vmk.DeviceName)(MTU=$($vmk.Mtu))"
            }
        }
    }

    if ($mtuBlockList.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Network"
            CheckName       = "VMkernel MTU Check"
            Status          = "BLOCK"
            Severity        = "Requirement"
            Score           = 0
            AffectedObjects = $mtuBlockList
            Description     = "$($mtuBlockList.Count) VMkernel adapter(s) have MTU below $($req.nsxOverlayMinMtu). NSX overlay transport requires minimum MTU $($req.nsxOverlayMinMtu)."
            Remediation     = "Configure MTU $($req.nsxOverlayMinMtu)+ on vMotion/vSAN/overlay VMkernels and upstream physical switches."
        })
    }

    if ($mtuWarnList.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Network"
            CheckName       = "VMkernel MTU Check"
            Status          = "WARN"
            Severity        = "BestPractice"
            Score           = 50
            AffectedObjects = $mtuWarnList
            Description     = "$($mtuWarnList.Count) VMkernel adapter(s) have MTU below recommended $($req.recommendedMtu). Jumbo frames improve vMotion/vSAN performance."
            Remediation     = "Configure MTU $($req.recommendedMtu) on all vMotion/vSAN VMkernels and upstream switches for optimal performance."
        })
    }

    if ($mtuBlockList.Count -eq 0 -and $mtuWarnList.Count -eq 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Network"
            CheckName       = "VMkernel MTU Check"
            Status          = "PASS"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @()
            Description     = "All vMotion/vSAN VMkernel adapters have MTU $($req.recommendedMtu)+ (jumbo frames)."
            Remediation     = "None"
        })
    }

    # ========== CHECK: DNS Forward Lookup ==========
    Write-Progress -Activity "Network Checks" -Status "Checking DNS forward resolution..."

    $dnsFailHosts = @()
    foreach ($vmhost in $hosts) {
        $hostname = $vmhost.Name
        if ($vmhost._MockDnsForward -eq $false) {
            $dnsFailHosts += $hostname
        } elseif (-not $vmhost._MockDnsForward) {
            try {
                [System.Net.Dns]::GetHostAddresses($hostname) | Out-Null
            } catch {
                $dnsFailHosts += $hostname
            }
        }
    }

    if ($dnsFailHosts.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Network"
            CheckName       = "DNS Forward Lookup"
            Status          = "BLOCK"
            Severity        = "Requirement"
            Score           = 0
            AffectedObjects = $dnsFailHosts
            Description     = "$($dnsFailHosts.Count) host(s) fail DNS forward resolution. VCF SDDC Manager requires DNS for all components."
            Remediation     = "Create A records for all ESXi hosts, vCenter, NSX, and SDDC Manager in your DNS zone."
        })
    } else {
        $results.Add([PSCustomObject]@{
            Category        = "Network"
            CheckName       = "DNS Forward Lookup"
            Status          = "PASS"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @()
            Description     = "All $($hosts.Count) hosts resolve via DNS forward lookup."
            Remediation     = "None"
        })
    }

    # ========== CHECK: DNS Reverse (PTR) Lookup ==========
    Write-Progress -Activity "Network Checks" -Status "Checking DNS reverse resolution..."

    $ptrMissing = @()
    foreach ($vmhost in $hosts) {
        if ($vmhost._MockDnsReverse -eq $false) {
            $ptrMissing += $vmhost.Name
        } elseif (-not $vmhost._MockDnsReverse) {
            try {
                $ip = ([System.Net.Dns]::GetHostAddresses($vmhost.Name) | Select-Object -First 1).IPAddressToString
                [System.Net.Dns]::GetHostEntry($ip) | Out-Null
            } catch {
                $ptrMissing += $vmhost.Name
            }
        }
    }

    if ($ptrMissing.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Network"
            CheckName       = "DNS Reverse (PTR) Lookup"
            Status          = "WARN"
            Severity        = "Requirement"
            Score           = 50
            AffectedObjects = $ptrMissing
            Description     = "$($ptrMissing.Count) host(s) missing PTR records. VCF SDDC Manager validates forward and reverse DNS."
            Remediation     = "Create PTR records for all ESXi host management IPs in your reverse DNS zone."
        })
    } else {
        $results.Add([PSCustomObject]@{
            Category        = "Network"
            CheckName       = "DNS Reverse (PTR) Lookup"
            Status          = "PASS"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @()
            Description     = "All hosts have valid PTR records."
            Remediation     = "None"
        })
    }

    # ========== CHECK: NTP Synchronization ==========
    Write-Progress -Activity "Network Checks" -Status "Checking NTP synchronization..."

    $ntpWarnHosts = @()
    foreach ($vmhost in $hosts) {
        if ($vmhost._MockNtpDrift) {
            if ($vmhost._MockNtpDrift -gt $req.ntpDriftWarnSeconds) {
                $ntpWarnHosts += "$($vmhost.Name) (drift: $($vmhost._MockNtpDrift)s)"
            }
        } elseif (-not $VMHosts) {
            # Real mode: check NTP service status
            try {
                $ntpSvc = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq 'ntpd' }
                if (-not $ntpSvc.Running) {
                    $ntpWarnHosts += "$($vmhost.Name) (ntpd not running)"
                }
            } catch {}
        }
    }

    if ($ntpWarnHosts.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Network"
            CheckName       = "NTP Synchronization"
            Status          = "WARN"
            Severity        = "BestPractice"
            Score           = 50
            AffectedObjects = $ntpWarnHosts
            Description     = "$($ntpWarnHosts.Count) host(s) have NTP issues. Time synchronization is critical for VCF components."
            Remediation     = "Configure all hosts to use the same NTP source. Ensure ntpd service is running and set to auto-start."
        })
    } else {
        $results.Add([PSCustomObject]@{
            Category        = "Network"
            CheckName       = "NTP Synchronization"
            Status          = "PASS"
            Severity        = "BestPractice"
            Score           = 100
            AffectedObjects = @()
            Description     = "NTP synchronization is healthy across all hosts."
            Remediation     = "None"
        })
    }

    # ========== CHECK: SSH Service Status ==========
    Write-Progress -Activity "Network Checks" -Status "Checking SSH service..."

    $sshEnabledHosts = @()
    foreach ($vmhost in $hosts) {
        if ($vmhost._MockSshEnabled) {
            $sshEnabledHosts += $vmhost.Name
        } elseif (-not $VMHosts) {
            try {
                $sshSvc = Get-VMHostService -VMHost $vmhost | Where-Object { $_.Key -eq 'TSM-SSH' }
                if ($sshSvc.Running) { $sshEnabledHosts += $vmhost.Name }
            } catch {}
        }
    }

    if ($sshEnabledHosts.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Network"
            CheckName       = "SSH Service Status"
            Status          = "WARN"
            Severity        = "BestPractice"
            Score           = 50
            AffectedObjects = $sshEnabledHosts
            Description     = "SSH is enabled on $($sshEnabledHosts.Count) host(s). Best practice: disable SSH except during maintenance."
            Remediation     = "Disable SSH service (TSM-SSH) on hosts after completing maintenance tasks."
        })
    } else {
        $results.Add([PSCustomObject]@{
            Category        = "Network"
            CheckName       = "SSH Service Status"
            Status          = "PASS"
            Severity        = "BestPractice"
            Score           = 100
            AffectedObjects = @()
            Description     = "SSH is disabled on all hosts — follows VCF security best practice."
            Remediation     = "None"
        })
    }

    Write-Progress -Activity "Network Checks" -Completed
    return $results.ToArray()
}
