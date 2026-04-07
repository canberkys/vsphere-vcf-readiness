function Invoke-ComputeCheck {
    <#
    .SYNOPSIS
        VCF readiness compute checks: CPU generation, NIC count, RAM, host count.
    .PARAMETER Config
        Parsed config.json object.
    .PARAMETER Requirements
        Parsed VCF version requirement matrix.
    .PARAMETER VMHosts
        Optional pre-fetched VMHost list (used by -WhatIf mock path).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [psobject]$Config,

        [Parameter(Mandatory = $false)]
        [psobject]$Requirements,

        [Parameter()]
        [psobject[]]$VMHosts
    )

    $req = if ($Requirements) { $Requirements.compute } else { $null }
    $results = [System.Collections.Generic.List[psobject]]::new()

    # Safe defaults when Requirements is null
    $minRamReq  = if ($req -and $req.minimumRamGB_requirement)   { $req.minimumRamGB_requirement }   else { 128 }
    $minRamBp   = if ($req -and $req.minimumRamGB_bestPractice)  { $req.minimumRamGB_bestPractice }  else { 256 }
    $minNicReq  = if ($req -and $req.minimumNicCount_requirement)  { $req.minimumNicCount_requirement }  else { 2 }
    $minNicBp   = if ($req -and $req.minimumNicCount_bestPractice) { $req.minimumNicCount_bestPractice } else { 4 }
    $minHostCnt = if ($req -and $req.minimumHostCount) { $req.minimumHostCount } else { 3 }

    if (-not $VMHosts) {
        $VMHosts = Get-VMHost | Where-Object {
            $_.Name -notin $Config.excludeHosts
        }
    }

    $totalHosts = $VMHosts.Count

    # ========== CHECK: Host Count ==========
    $minHosts = if ($Config.minimumHostCount) { $Config.minimumHostCount } else { $minHostCnt }
    $isVsan   = $Config.storageType -match '^vsan'

    if ($isVsan -and $totalHosts -lt $minHosts) {
        $results.Add([PSCustomObject]@{
            Category        = "Compute"
            CheckName       = "Minimum Host Count"
            Status          = "BLOCK"
            Severity        = "Requirement"
            Score           = 0
            AffectedObjects = @("Current: $totalHosts, Required: $minHosts")
            Description     = "vSAN requires at least $minHosts hosts. Only $totalHosts found."
            Remediation     = "Add hosts to the cluster to meet the minimum vSAN requirement."
        })
    } else {
        $results.Add([PSCustomObject]@{
            Category        = "Compute"
            CheckName       = "Minimum Host Count"
            Status          = "PASS"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @()
            Description     = "Host count ($totalHosts) meets minimum requirement."
            Remediation     = "None"
        })
    }

    # ========== Per-host checks ==========
    $hostIndex = 0
    foreach ($vmhost in $VMHosts) {
        $hostIndex++
        Write-Progress -Activity "Compute Checks" -Status $vmhost.Name `
            -PercentComplete (($hostIndex / $totalHosts) * 100)

        # --- CPU Generation ---
        $cpuModel = if ($vmhost.ProcessorType) { $vmhost.ProcessorType } else { $vmhost.CpuModel }

        $cpuStatus      = "PASS"
        $cpuSeverity    = "Requirement"
        $cpuDescription = "CPU is Ice Lake or newer -fully VCF compatible."
        $cpuRemediation = "None"
        $cpuScore       = 100

        # Legacy patterns: Haswell (v3), Broadwell (v4), Skylake (1st gen Scalable xx00)
        $legacyPatterns = @(
            'E5-[24][0-9]',          # E5-2xxx, E5-4xxx (Haswell/Broadwell)
            'E3-1[0-9]',             # E3-1xxx
            'v3\b',                  # Haswell
            'v4\b',                  # Broadwell
            'Gold [56]1[0-9]{2}\b',  # Skylake Gold 51xx, 61xx
            'Silver 41[0-9]{2}\b',   # Skylake Silver 41xx
            'Platinum 81[0-9]{2}\b', # Skylake Platinum 81xx
            'Bronze 31[0-9]{2}\b'    # Skylake Bronze 31xx
        )

        # Cascade Lake: 2nd gen Scalable (xx00 series, different from Skylake by model numbers)
        $cascadePatterns = @(
            'Gold 52[0-9]{2}\b',     # Gold 52xx
            'Gold 62[0-9]{2}',       # Gold 62xx (R variants too)
            'Silver 42[0-9]{2}\b',   # Silver 42xx
            'Platinum 82[0-9]{2}\b', # Platinum 82xx
            'Bronze 32[0-9]{2}\b'    # Bronze 32xx
        )

        # Ice Lake+ patterns: 3rd gen and newer
        $icelakePlusPatterns = @(
            'Gold 5[3-9][0-9]{2}',      # Gold 53xx+ (Ice Lake)
            'Gold 6[3-9][0-9]{2}',      # Gold 63xx+ (Ice Lake / Sapphire Rapids)
            'Silver 4[3-9][0-9]{2}',    # Silver 43xx+
            'Platinum 8[3-9][0-9]{2}',  # Platinum 83xx+
            'w[3579]-[0-9]{4}',         # Xeon W series (newer)
            'Bronze 3[3-9][0-9]{2}'     # Bronze 33xx+
        )

        $isLegacy  = $false
        $isCascade = $false
        $isIceLake = $false

        foreach ($p in $icelakePlusPatterns) {
            if ($cpuModel -match $p) { $isIceLake = $true; break }
        }
        if (-not $isIceLake) {
            foreach ($p in $cascadePatterns) {
                if ($cpuModel -match $p) { $isCascade = $true; break }
            }
        }
        if (-not $isIceLake -and -not $isCascade) {
            foreach ($p in $legacyPatterns) {
                if ($cpuModel -match $p) { $isLegacy = $true; break }
            }
        }

        if ($isLegacy) {
            $cpuStatus      = "BLOCK"
            $cpuSeverity    = "Requirement"
            $cpuScore       = 0
            $cpuDescription = "CPU ($cpuModel) is Haswell/Broadwell/Skylake era -discontinued for VCF 9.x. Installation is blocked."
            $cpuRemediation = "Replace host hardware with Ice Lake (3rd Gen Scalable) or newer CPUs. https://knowledge.broadcom.com/external/article/318697"
        } elseif ($isCascade) {
            $cpuStatus      = "WARN"
            $cpuSeverity    = "BestPractice"
            $cpuScore       = 50
            $cpuDescription = "CPU ($cpuModel) is Cascade Lake -deprecated for VCF 9.x. Supported but nearing end of general support."
            $cpuRemediation = "Plan hardware refresh to Ice Lake+ within next upgrade cycle. Cascade Lake is fully functional including vSAN ESA. https://knowledge.broadcom.com/external/article/318697"
        }

        $results.Add([PSCustomObject]@{
            Category        = "Compute"
            CheckName       = "CPU Generation Compatibility"
            Status          = $cpuStatus
            Severity        = $cpuSeverity
            Score           = $cpuScore
            AffectedObjects = @($vmhost.Name)
            Description     = $cpuDescription
            Remediation     = $cpuRemediation
        })

        # --- NIC Count ---
        $nicCount = if ($vmhost._MockNicCount) {
            $vmhost._MockNicCount
        } else {
            (Get-VMHostNetworkAdapter -VMHost $vmhost -Physical | Measure-Object).Count
        }

        # $minNicReq and $minNicBp set at function top with safe defaults

        if ($nicCount -lt $minNicReq) {
            $results.Add([PSCustomObject]@{
                Category        = "Compute"
                CheckName       = "Physical NIC Count"
                Status          = "BLOCK"
                Severity        = "Requirement"
                Score           = 0
                AffectedObjects = @($vmhost.Name)
                Description     = "Host $($vmhost.Name) has $nicCount physical NIC(s). VCF requires minimum $minNicReq x 10GbE."
                Remediation     = "Add 10GbE or faster NICs. VCF requires at least $minNicReq physical NICs. https://knowledge.broadcom.com/external/article/318697"
            })
        } elseif ($nicCount -lt $minNicBp) {
            $results.Add([PSCustomObject]@{
                Category        = "Compute"
                CheckName       = "Physical NIC Count"
                Status          = "WARN"
                Severity        = "BestPractice"
                Score           = 50
                AffectedObjects = @($vmhost.Name)
                Description     = "Host $($vmhost.Name) has $nicCount physical NIC(s). Best practice: ${minNicBp}+ for traffic separation."
                Remediation     = "Consider adding NICs for dedicated vMotion, vSAN, and NSX overlay traffic. https://knowledge.broadcom.com/external/article/318697"
            })
        } else {
            $results.Add([PSCustomObject]@{
                Category        = "Compute"
                CheckName       = "Physical NIC Count"
                Status          = "PASS"
                Severity        = "Requirement"
                Score           = 100
                AffectedObjects = @($vmhost.Name)
                Description     = "Host $($vmhost.Name) has $nicCount physical NIC(s) -meets requirement."
                Remediation     = "None"
            })
        }

        # --- RAM ---
        $ramGB = [math]::Round($vmhost.MemoryTotalGB, 0)
        # $minRamReq and $minRamBp set at function top with safe defaults

        if ($ramGB -lt $minRamReq) {
            $results.Add([PSCustomObject]@{
                Category        = "Compute"
                CheckName       = "RAM Capacity"
                Status          = "BLOCK"
                Severity        = "Requirement"
                Score           = 0
                AffectedObjects = @($vmhost.Name)
                Description     = "Host $($vmhost.Name) has ${ramGB}GB RAM. VCF/vSAN ESA requires minimum ${minRamReq}GB."
                Remediation     = "Upgrade RAM to at least ${minRamReq}GB (requirement). ${minRamBp}GB+ recommended for production. https://knowledge.broadcom.com/external/article/318697"
            })
        } elseif ($ramGB -lt $minRamBp) {
            $results.Add([PSCustomObject]@{
                Category        = "Compute"
                CheckName       = "RAM Capacity"
                Status          = "WARN"
                Severity        = "BestPractice"
                Score           = 50
                AffectedObjects = @($vmhost.Name)
                Description     = "Host $($vmhost.Name) has ${ramGB}GB RAM. Meets minimum (${minRamReq}GB) but below recommended ${minRamBp}GB."
                Remediation     = "Consider upgrading to ${minRamBp}GB+ for production VCF workloads."
            })
        } else {
            $results.Add([PSCustomObject]@{
                Category        = "Compute"
                CheckName       = "RAM Capacity"
                Status          = "PASS"
                Severity        = "Requirement"
                Score           = 100
                AffectedObjects = @($vmhost.Name)
                Description     = "Host $($vmhost.Name) has ${ramGB}GB RAM -meets requirement."
                Remediation     = "None"
            })
        }
    }

    Write-Progress -Activity "Compute Checks" -Completed
    return $results.ToArray()
}
