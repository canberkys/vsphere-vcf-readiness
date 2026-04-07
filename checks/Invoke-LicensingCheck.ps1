function Invoke-LicensingCheck {
    <#
    .SYNOPSIS
        VCF readiness licensing checks: core count, license expiry, vSAN entitlement.
    .PARAMETER Config
        Parsed config.json object.
    .PARAMETER Requirements
        Parsed VCF version requirement matrix.
    .PARAMETER VMHosts
        Optional pre-fetched VMHost list.
    .PARAMETER MockLicenses
        Optional mock license data for -WhatIf mode.
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
        [psobject[]]$MockLicenses
    )

    $req = if ($Requirements) { $Requirements.licensing } else { $null }
    $results = [System.Collections.Generic.List[psobject]]::new()

    # Safe defaults when Requirements is null
    $coreMinPerSocket = if ($req -and $coreMinPerSocket) { $coreMinPerSocket } else { 16 }
    $vsanTibPerCore   = if ($req -and $vsanTibPerCore)   { $vsanTibPerCore }   else { 1 }
    $vcfVer           = if ($Requirements -and $vcfVer) { $vcfVer } else { "9.0.x" }

    $hosts = if ($VMHosts) { $VMHosts } else {
        Get-VMHost | Where-Object { $_.Name -notin $Config.excludeHosts }
    }

    # ========== CHECK: Physical Core Count Estimate ==========
    Write-Progress -Activity "Licensing Checks" -Status "Calculating core count..."

    $totalCores   = 0
    $totalSockets = 0

    foreach ($vmhost in $hosts) {
        $sockets = if ($vmhost.CpuSockets) { $vmhost.CpuSockets } else {
            try { $vmhost.ExtensionData.Hardware.CpuInfo.NumCpuPackages } catch { 2 }
        }
        $coresPerSocket = if ($vmhost.CoresPerSocket) { $vmhost.CoresPerSocket } else {
            try {
                $vmhost.ExtensionData.Hardware.CpuInfo.NumCpuCores / $sockets
            } catch { 16 }
        }

        $licensedCores = [math]::Max($coresPerSocket, $coreMinPerSocket) * $sockets
        $totalCores   += $licensedCores
        $totalSockets += $sockets
    }

    $results.Add([PSCustomObject]@{
        Category        = "Licensing"
        CheckName       = "Physical Core Count Estimate"
        Status          = "INFO"
        Severity        = "Requirement"
        Score           = 100
        AffectedObjects = @()
        Description     = "Total licensable cores: $totalCores across $($hosts.Count) hosts ($totalSockets sockets). Formula: max(actual_cores, $($coreMinPerSocket)) x sockets per host."
        Remediation     = "Contact VMware/Broadcom sales for VCF $($vcfVer) core-based licensing quote. https://knowledge.broadcom.com/external/article/313548"
    })

    # ========== CHECK: Current License Expiry ==========
    Write-Progress -Activity "Licensing Checks" -Status "Checking license expiry..."

    $licenses = if ($MockLicenses) {
        $MockLicenses
    } else {
        try {
            $licMgr = Get-View (Get-View ServiceInstance).Content.LicenseManager
            $licMgr.Licenses | ForEach-Object {
                $expiry = ($_.Properties | Where-Object { $_.Key -eq 'expirationDate' }).Value
                [PSCustomObject]@{
                    Name       = $_.Name
                    LicenseKey = $_.LicenseKey
                    ExpiryDate = $expiry
                    CostUnit   = $_.CostUnit
                }
            }
        } catch { @() }
    }

    $expiringLicenses = @()
    foreach ($lic in $licenses) {
        if ($lic.ExpiryDate) {
            $daysLeft = ((Get-Date $lic.ExpiryDate) - (Get-Date)).Days
            if ($daysLeft -le 90 -and $daysLeft -gt 0) {
                $expiringLicenses += "$($lic.Name) (expires: $(Get-Date $lic.ExpiryDate -Format 'yyyy-MM-dd'), ${daysLeft}d remaining)"
            } elseif ($daysLeft -le 0) {
                $expiringLicenses += "$($lic.Name) (EXPIRED: $(Get-Date $lic.ExpiryDate -Format 'yyyy-MM-dd'))"
            }
        }
    }

    if ($expiringLicenses.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Licensing"
            CheckName       = "Current License Expiry"
            Status          = "BLOCK"
            Severity        = "Requirement"
            Score           = 0
            AffectedObjects = $expiringLicenses
            Description     = "$($expiringLicenses.Count) license(s) expiring within 90 days or already expired. VCF migration requires valid licensing."
            Remediation     = "Coordinate with procurement: complete VCF migration (includes new licenses) or renew existing licenses as a bridge. https://knowledge.broadcom.com/external/article/313548"
        })
    } elseif ($licenses.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Licensing"
            CheckName       = "Current License Expiry"
            Status          = "PASS"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @()
            Description     = "All licenses are valid with more than 90 days remaining."
            Remediation     = "None"
        })
    } else {
        $results.Add([PSCustomObject]@{
            Category        = "Licensing"
            CheckName       = "Current License Expiry"
            Status          = "INFO"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @()
            Description     = "Unable to retrieve license information. Manual verification required."
            Remediation     = "Check license status in vSphere Client under Administration > Licensing."
        })
    }

    # ========== CHECK: vSAN Capacity vs VCF Entitlement ==========
    Write-Progress -Activity "Licensing Checks" -Status "Calculating vSAN entitlement..."

    $isVsan = $Config.storageType -match '^vsan'

    if ($isVsan) {
        $vsanUsageTiB = 0
        foreach ($vmhost in $hosts) {
            if ($vmhost._MockVsanUsageTiB) {
                $vsanUsageTiB += $vmhost._MockVsanUsageTiB
            }
        }

        # If no mock data and no real data, estimate from datastore
        if ($vsanUsageTiB -eq 0 -and -not $VMHosts) {
            try {
                $vsanDs = Get-Datastore | Where-Object { $_.Type -eq 'vsan' }
                $vsanUsageTiB = [math]::Round(($vsanDs | Measure-Object -Property CapacityGB -Sum).Sum / 1024, 1)
            } catch {}
        }

        $entitlementTiB = $totalCores * $vsanTibPerCore

        $results.Add([PSCustomObject]@{
            Category        = "Licensing"
            CheckName       = "vSAN Capacity vs VCF Entitlement"
            Status          = "INFO"
            Severity        = "BestPractice"
            Score           = 100
            AffectedObjects = @("Current usage: $vsanUsageTiB TiB", "VCF entitlement: $entitlementTiB TiB ($($vsanTibPerCore) TiB/core x $totalCores cores)")
            Description     = if ($vsanUsageTiB -le $entitlementTiB) {
                "Current vSAN capacity ($vsanUsageTiB TiB) is within VCF included entitlement ($entitlementTiB TiB)."
            } else {
                "Current vSAN capacity ($vsanUsageTiB TiB) exceeds VCF included entitlement ($entitlementTiB TiB). Additional vSAN add-on licenses required."
            }
            Remediation     = if ($vsanUsageTiB -le $entitlementTiB) {
                "No additional vSAN licensing required. Monitor growth -exceeding $entitlementTiB TiB will require add-on capacity licenses."
            } else {
                "Procure additional vSAN capacity licenses for the excess $([math]::Round($vsanUsageTiB - $entitlementTiB, 1)) TiB."
            }
        })
    }

    Write-Progress -Activity "Licensing Checks" -Completed
    return $results.ToArray()
}
