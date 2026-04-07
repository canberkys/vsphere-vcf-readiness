function Invoke-StorageCheck {
    <#
    .SYNOPSIS
        VCF readiness storage checks: datastore capacity, snapshots, boot device, vSAN HCL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [psobject]$Config,

        [Parameter(Mandatory = $false)]
        [psobject]$Requirements,

        [Parameter()]
        [psobject[]]$MockDatastores,

        [Parameter()]
        [psobject[]]$MockSnapshots,

        [Parameter()]
        [psobject[]]$VMHosts
    )

    $req = if ($Requirements) { $Requirements.storage } else { $null }
    $results = [System.Collections.Generic.List[psobject]]::new()

    # Safe defaults when Requirements is null
    $blockPct      = if ($req -and $req.datastoreUsageBlockPct) { $req.datastoreUsageBlockPct } else { 85 }
    $warnPct       = if ($req -and $req.datastoreUsageWarnPct)  { $req.datastoreUsageWarnPct }  else { 75 }
    $snapBlockDays = if ($req -and $req.snapshotBlockDays)      { $req.snapshotBlockDays }      else { 30 }
    $snapWarnDays  = if ($req -and $req.snapshotWarnDays)       { $req.snapshotWarnDays }       else { 7 }

    # Datastore exclude patterns from config
    $excludePatterns = if ($Config.excludeDatastorePatterns) { $Config.excludeDatastorePatterns } else { @() }

    # ========== CHECK: Datastore Capacity Usage ==========
    Write-Progress -Activity "Storage Checks" -Status "Checking datastore capacity..."

    $datastores = if ($MockDatastores) {
        $MockDatastores
    } else {
        Get-Datastore | Where-Object { $_.Type -ne 'NFS' -or $Config.storageType -eq 'nfs' }
    }

    # Filter out excluded datastores
    if ($excludePatterns.Count -gt 0) {
        $datastores = $datastores | Where-Object {
            $dsName = $_.Name
            $excluded = $false
            foreach ($pattern in $excludePatterns) {
                if ($dsName -like $pattern) { $excluded = $true; break }
            }
            -not $excluded
        }
    }

    # Group results: collect all datastores then emit grouped results
    $dsBlock = @()
    $dsWarn  = @()
    $dsPass  = @()

    foreach ($ds in $datastores) {
        if ($ds.CapacityGB -le 0) { continue }
        $usedPct = [math]::Round((1 - ($ds.FreeSpaceGB / $ds.CapacityGB)) * 100, 1)

        if ($usedPct -gt $blockPct) {
            $dsBlock += "$($ds.Name): ${usedPct}%"
        } elseif ($usedPct -gt $warnPct) {
            $dsWarn += "$($ds.Name): ${usedPct}%"
        } else {
            $dsPass += "$($ds.Name): ${usedPct}%"
        }
    }

    if ($dsBlock.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Storage"
            CheckName       = "Datastore Capacity Usage"
            Status          = "BLOCK"
            Severity        = "BestPractice"
            Score           = 0
            AffectedObjects = $dsBlock
            Description     = "$($dsBlock.Count) datastore(s) above ${blockPct}% capacity threshold."
            Remediation     = "Free up space or add capacity before VCF migration. Migration requires temporary additional space. https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0"
        })
    }

    if ($dsWarn.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Storage"
            CheckName       = "Datastore Capacity Usage"
            Status          = "WARN"
            Severity        = "BestPractice"
            Score           = 50
            AffectedObjects = $dsWarn
            Description     = "$($dsWarn.Count) datastore(s) between ${warnPct}%-${blockPct}% capacity."
            Remediation     = "Plan capacity expansion — migration will require additional temporary space."
        })
    }

    if ($dsPass.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Storage"
            CheckName       = "Datastore Capacity Usage"
            Status          = "PASS"
            Severity        = "BestPractice"
            Score           = 100
            AffectedObjects = @("$($dsPass.Count) datastore(s) below ${warnPct}%")
            Description     = "$($dsPass.Count) datastore(s) have healthy capacity (below ${warnPct}%)."
            Remediation     = "None"
        })
    }

    # ========== CHECK: Snapshot Age Audit ==========
    Write-Progress -Activity "Storage Checks" -Status "Checking snapshot ages..."

    $snapshots = if ($MockSnapshots) {
        $MockSnapshots
    } else {
        try { Get-VM | Get-Snapshot | Select-Object VM, Name, Created, SizeGB } catch { @() }
    }

    $blockSnaps = @()
    $warnSnaps  = @()

    foreach ($snap in $snapshots) {
        $ageDays = ((Get-Date) - $snap.Created).Days
        $sizeGB  = [math]::Round($snap.SizeGB, 1)

        if ($ageDays -gt $snapBlockDays) {
            $blockSnaps += "$($snap.VM) (${ageDays}d, ${sizeGB}GB)"
        } elseif ($ageDays -gt $snapWarnDays) {
            $warnSnaps += "$($snap.VM) (${ageDays}d, ${sizeGB}GB)"
        }
    }

    if ($blockSnaps.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Storage"
            CheckName       = "Snapshot Age Audit"
            Status          = "BLOCK"
            Severity        = "BestPractice"
            Score           = 0
            AffectedObjects = $blockSnaps
            Description     = "$($blockSnaps.Count) VM(s) have snapshots older than $snapBlockDays days."
            Remediation     = "Consolidate or delete snapshots older than $snapBlockDays days before migration."
        })
    }

    if ($warnSnaps.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Storage"
            CheckName       = "Snapshot Age Audit"
            Status          = "WARN"
            Severity        = "BestPractice"
            Score           = 50
            AffectedObjects = $warnSnaps
            Description     = "$($warnSnaps.Count) VM(s) have snapshots between ${snapWarnDays}-${snapBlockDays} days old."
            Remediation     = "Review and consolidate snapshots before migration window."
        })
    }

    if ($blockSnaps.Count -eq 0 -and $warnSnaps.Count -eq 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Storage"
            CheckName       = "Snapshot Age Audit"
            Status          = "PASS"
            Severity        = "BestPractice"
            Score           = 100
            AffectedObjects = @()
            Description     = "No problematic snapshots found."
            Remediation     = "None"
        })
    }

    # ========== CHECK: USB/SD Boot Device ==========
    Write-Progress -Activity "Storage Checks" -Status "Checking boot devices..."

    $hosts = if ($VMHosts) { $VMHosts } else {
        try { Get-VMHost | Where-Object { $_.Name -notin $Config.excludeHosts } } catch { @() }
    }

    $usbBootHosts = @()
    foreach ($vmhost in $hosts) {
        $bootDevice = if ($vmhost._MockBootDevice) {
            $vmhost._MockBootDevice
        } else {
            try {
                $esxcli = Get-EsxCli -VMHost $vmhost -V2
                $bootInfo = $esxcli.system.boot.device.get.Invoke()
                $bootInfo.BootFilesystemType
            } catch { "Unknown" }
        }

        if ($bootDevice -match 'USB|SD|SDCARD') {
            $usbBootHosts += $vmhost.Name
        }
    }

    if ($usbBootHosts.Count -gt 0) {
        $results.Add([PSCustomObject]@{
            Category        = "Storage"
            CheckName       = "USB/SD Boot Device Detection"
            Status          = "WARN"
            Severity        = "Requirement"
            Score           = 50
            AffectedObjects = $usbBootHosts
            Description     = "$($usbBootHosts.Count) host(s) boot from USB/SD device. VCF 9.x deprecates USB/SD boot for ESX-OSData."
            Remediation     = "Migrate boot device to M.2 BOSS, SSD, or NVMe (min 32GB, recommended 128GB). https://knowledge.broadcom.com/external/article/317631"
        })
    } else {
        $results.Add([PSCustomObject]@{
            Category        = "Storage"
            CheckName       = "USB/SD Boot Device Detection"
            Status          = "PASS"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @()
            Description     = "All hosts use persistent boot devices (SSD/NVMe/M.2)."
            Remediation     = "None"
        })
    }

    # ========== CHECK: vSAN HCL Compliance ==========
    if (-not $Config.checkHcl) {
        $results.Add([PSCustomObject]@{
            Category        = "Storage"
            CheckName       = "vSAN HCL Compliance"
            Status          = "INFO"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @()
            Description     = "vSAN HCL check skipped (checkHcl: false in config)."
            Remediation     = "Enable checkHcl in config.json to validate storage controllers against VMware HCL."
        })
    } else {
        $results.Add([PSCustomObject]@{
            Category        = "Storage"
            CheckName       = "vSAN HCL Compliance"
            Status          = "INFO"
            Severity        = "Requirement"
            Score           = 100
            AffectedObjects = @()
            Description     = "vSAN HCL validation requires online connectivity. Manual check recommended."
            Remediation     = "Verify storage controllers at compatibility.broadcom.com/hcl/vsanhcl."
        })
    }

    Write-Progress -Activity "Storage Checks" -Completed
    return $results.ToArray()
}
