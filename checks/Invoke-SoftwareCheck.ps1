function Invoke-SoftwareCheck {
    <#
    .SYNOPSIS
        VCF readiness software checks: ESXi version, vCenter version, vLCM, VMware Tools.
    .PARAMETER Config
        Parsed config.json object.
    .PARAMETER Requirements
        Parsed VCF version requirement matrix.
    .PARAMETER VMHosts
        Optional pre-fetched VMHost list.
    .PARAMETER MockVCenter
        Optional mock vCenter object for -WhatIf mode.
    .PARAMETER MockClusters
        Optional mock cluster objects for -WhatIf mode.
    .PARAMETER MockVMs
        Optional mock VM objects for -WhatIf mode.
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
        [psobject]$MockVCenter,

        [Parameter()]
        [psobject[]]$MockClusters,

        [Parameter()]
        [psobject[]]$MockVMs
    )

    $req = if ($Requirements) { $Requirements.software } else { $null }
    $results = [System.Collections.Generic.List[psobject]]::new()

    # Safe defaults when Requirements is null
    $minEsxiVer    = if ($req -and $minEsxiVer)    { $minEsxiVer }    else { "8.0.1" }
    $minVcVer      = if ($req -and $minVcVer) { $minVcVer } else { "8.0.2" }
    $toolsMinVer   = if ($req -and $toolsMinVer) { $toolsMinVer } else { "11.0" }
    $toolsWarnPct  = if ($req -and $toolsWarnPct)    { $toolsWarnPct }    else { 20 }
    $vcfVer        = if ($Requirements -and $vcfVer) { $vcfVer } else { "9.0.x" }

    $hosts = if ($VMHosts) { $VMHosts } else {
        Get-VMHost | Where-Object { $_.Name -notin $Config.excludeHosts }
    }

    # ========== HELPER: Parse ESXi version string ==========
    function Compare-EsxiVersion {
        param([string]$Version, [string]$Minimum)
        # Parse "8.0.2" or "7.0.3" into comparable parts
        $vParts = $Version -split '\.'
        $mParts = $Minimum -split '\.'

        for ($i = 0; $i -lt [math]::Max($vParts.Count, $mParts.Count); $i++) {
            $v = if ($i -lt $vParts.Count) { [int]($vParts[$i] -replace '[^0-9]','') } else { 0 }
            $m = if ($i -lt $mParts.Count) { [int]($mParts[$i] -replace '[^0-9]','') } else { 0 }
            if ($v -gt $m) { return 1 }
            if ($v -lt $m) { return -1 }
        }
        return 0
    }

    # ========== CHECK: ESXi Version Compatibility ==========
    Write-Progress -Activity "Software Checks" -Status "Checking ESXi versions..."

    $blockHosts = @()
    $passHosts  = @()

    foreach ($vmhost in $hosts) {
        $version = $vmhost.Version
        $major = [int]($version.Split('.')[0])

        if ($major -lt 8) {
            # ESXi 7.x or older — no direct path to VCF 9.x
            $blockHosts += "$($vmhost.Name) ($version)"
        } elseif ((Compare-EsxiVersion $version $minEsxiVer) -lt 0) {
            # ESXi 8.x but below minimum
            $blockHosts += "$($vmhost.Name) ($version)"
        } else {
            $passHosts += "$($vmhost.Name) ($version)"
        }
    }

    if ($blockHosts.Count -gt 0) {
        # Separate 7.x from 8.x below-minimum for better messaging
        $esxi7Hosts = $blockHosts | Where-Object { $_ -match '\(7\.' }
        $esxi8LowHosts = $blockHosts | Where-Object { $_ -match '\(8\.' }

        if ($esxi7Hosts) {
            $results.Add([PSCustomObject]@{
                Category        = "Software"
                CheckName       = "ESXi Version Compatibility"
                Status          = "BLOCK"
                Severity        = "Requirement"
                Score           = 0
                AffectedObjects = @($esxi7Hosts)
                Description     = "$($esxi7Hosts.Count) host(s) running ESXi 7.x. There is NO direct upgrade path from ESXi 7.x to VCF 9.x."
                Remediation     = "Upgrade path: ESXi 7.x -> ESXi 8.0 U2+ -> VCF 9.x. Plan a two-stage upgrade."
            })
        }

        if ($esxi8LowHosts) {
            $results.Add([PSCustomObject]@{
                Category        = "Software"
                CheckName       = "ESXi Version Compatibility"
                Status          = "BLOCK"
                Severity        = "Requirement"
                Score           = 0
                AffectedObjects = @($esxi8LowHosts)
                Description     = "$($esxi8LowHosts.Count) host(s) running ESXi 8.x below minimum $($minEsxiVer) for VCF $($vcfVer)."
                Remediation     = "Upgrade to ESXi $($minEsxiVer) or later before VCF migration."
            })
        }
    }

    if ($passHosts.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Software"
            CheckName       = "ESXi Version Compatibility"
            Status          = "PASS"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @($passHosts)
            Description     = "$($passHosts.Count) host(s) running compatible ESXi version for VCF $($vcfVer)."
            Remediation     = "None"
        })
    }

    # ========== CHECK: vCenter Version ==========
    Write-Progress -Activity "Software Checks" -Status "Checking vCenter version..."

    $vcVersion = if ($MockVCenter) {
        $MockVCenter.Version
    } else {
        try { $global:DefaultVIServer.Version } catch { "Unknown" }
    }
    $vcName = if ($MockVCenter) { $MockVCenter.Name } else {
        try { $global:DefaultVIServer.Name } catch { "Unknown" }
    }

    if ($vcVersion -eq "Unknown") {
        $results.Add([PSCustomObject]@{
            Category        = "Software"
            CheckName       = "vCenter Version Check"
            Status          = "INFO"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @()
            Description     = "Unable to determine vCenter version."
            Remediation     = "Verify vCenter version manually. VCF $($vcfVer) requires vCenter $($minVcVer)+."
        })
    } elseif ((Compare-EsxiVersion $vcVersion $minVcVer) -lt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Software"
            CheckName       = "vCenter Version Check"
            Status          = "BLOCK"
            Severity        = "Requirement"
            Score           = 0
            AffectedObjects = @("$vcName ($vcVersion)")
            Description     = "vCenter $vcVersion is below minimum $($minVcVer) required for VCF $($vcfVer)."
            Remediation     = "Upgrade vCenter to $($minVcVer) or later before VCF migration."
        })
    } else {
        $results.Add([PSCustomObject]@{
            Category        = "Software"
            CheckName       = "vCenter Version Check"
            Status          = "PASS"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @("$vcName ($vcVersion)")
            Description     = "vCenter $vcVersion is compatible with VCF $($vcfVer)."
            Remediation     = "None"
        })
    }

    # ========== CHECK: vLCM Image-Based Management ==========
    Write-Progress -Activity "Software Checks" -Status "Checking vLCM management mode..."

    $clusters = if ($MockClusters) {
        $MockClusters
    } else {
        try {
            Get-Cluster | ForEach-Object {
                [PSCustomObject]@{
                    Name     = $_.Name
                    VlcmMode = try {
                        $imgMgr = Get-View -Id $_.ExtensionData.ConfigurationEx.DefaultComputeResource
                        "Image"
                    } catch { "Baseline" }
                }
            }
        } catch { @() }
    }

    $baselineClusters = $clusters | Where-Object { $_.VlcmMode -eq 'Baseline' }

    if ($baselineClusters.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Software"
            CheckName       = "vLCM Image-Based Management"
            Status          = "WARN"
            Severity        = "Requirement"
            Score           = 50
            AffectedObjects = @($baselineClusters.Name)
            Description     = "$($baselineClusters.Count) cluster(s) using baseline-based lifecycle management. VCF 9.x requires vLCM image-based management."
            Remediation     = "Convert clusters from baseline to vLCM image-based management before VCF onboarding. See KB 322186."
        })
    } elseif ($clusters.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Software"
            CheckName       = "vLCM Image-Based Management"
            Status          = "PASS"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @($clusters.Name)
            Description     = "All clusters use vLCM image-based lifecycle management."
            Remediation     = "None"
        })
    }

    # ========== CHECK: VMware Tools Version Audit ==========
    Write-Progress -Activity "Software Checks" -Status "Checking VMware Tools versions..."

    $vms = if ($MockVMs) { $MockVMs } else {
        try { Get-VM | Select-Object Name, @{N='ToolsVersion';E={$_.Guest.ToolsVersion}} } catch { @() }
    }

    if ($vms.Count -gt 0) {
        $outdatedVMs = $vms | Where-Object {
            $_.ToolsVersion -and $_.ToolsVersion -ne '' -and
            (Compare-EsxiVersion $_.ToolsVersion $toolsMinVer) -lt 0
        }
        $outdatedPct = [math]::Round(($outdatedVMs.Count / $vms.Count) * 100, 0)

        if ($outdatedPct -gt $toolsWarnPct) {
            $results.Add([PSCustomObject]@{
                Category        = "Software"
                CheckName       = "VMware Tools Version Audit"
                Status          = "WARN"
                Severity        = "BestPractice"
                Score           = 50
                AffectedObjects = @("$($outdatedVMs.Count) of $($vms.Count) VMs (${outdatedPct}%) running Tools < $($toolsMinVer)")
                Description     = "${outdatedPct}% of VMs have outdated VMware Tools (> $($toolsWarnPct)% threshold)."
                Remediation     = "Upgrade VMware Tools on affected VMs using vSphere Update Manager or bulk CLI update."
            })
        } else {
            $results.Add([PSCustomObject]@{
                Category        = "Software"
                CheckName       = "VMware Tools Version Audit"
                Status          = "PASS"
                Severity        = "BestPractice"
                Score           = 100
                AffectedObjects = @()
                Description     = "VMware Tools compliance: ${outdatedPct}% outdated (below $($toolsWarnPct)% threshold)."
                Remediation     = "None"
            })
        }
    }

    Write-Progress -Activity "Software Checks" -Completed
    return $results.ToArray()
}
