<#
.SYNOPSIS
    VCF Readiness Assessment Tool — analyzes vSphere environments for VCF 9.0.x migration.
.DESCRIPTION
    Connects to a vCenter Server, runs a suite of readiness checks (compute, storage,
    network, software, licensing) and produces a scored report.
.PARAMETER VCenterServer
    FQDN or IP of the target vCenter Server. Falls back to config.json vcenterServer.
.PARAMETER Credential
    PSCredential for vCenter authentication (read-only role sufficient).
    Falls back to saved credential file or interactive prompt.
.PARAMETER ConfigFile
    Path to config.json. Defaults to ./config.json.
.PARAMETER OutputPath
    Directory for report output. Defaults to ./output.
.PARAMETER ReportFormat
    Output format: HTML, JSON, CSV, or All.
.PARAMETER WhatIf
    Run with mock data — no vCenter connection required.
.EXAMPLE
    .\vsphere-vcf-readiness.ps1
    # Reads vCenter from config.json, uses saved credential or prompts
.EXAMPLE
    .\vsphere-vcf-readiness.ps1 -VCenterServer vcsa.lab.local -Credential (Get-Credential)
.EXAMPLE
    .\vsphere-vcf-readiness.ps1 -WhatIf
#>
#Requires -Version 7.2

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$VCenterServer,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter()]
    [string]$ConfigFile = (Join-Path $PSScriptRoot "config.json"),

    [Parameter()]
    [string]$OutputPath = (Join-Path $PSScriptRoot "output"),

    [Parameter()]
    [ValidateSet("HTML","JSON","CSV","All")]
    [string]$ReportFormat = "HTML"
)

# ── PS 5.1 re-launch guard: if opened with Windows PowerShell, restart in pwsh ──
if ($PSVersionTable.PSVersion.Major -lt 7) {
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        Write-Host "Relaunching in PowerShell 7..." -ForegroundColor Yellow
        Start-Process pwsh -ArgumentList "-File `"$PSCommandPath`"" -NoNewWindow -Wait
        exit
    } else {
        Write-Error "PowerShell 7.2+ is required. Install from https://github.com/PowerShell/PowerShell"
        Read-Host "Press Enter to exit"
        exit 1
    }
}

$ErrorActionPreference = "Stop"
$script:ToolVersion = "0.6.0"
$script:CredentialFile = Join-Path $HOME ".vcf-readiness-cred.xml"

# Resolve script root reliably (handles interactive/dot-source/double-click cases)
if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path -ErrorAction SilentlyContinue) -ErrorAction SilentlyContinue
}
if (-not $PSScriptRoot) {
    $PSScriptRoot = $PWD.Path
}

# Fix param defaults if PSScriptRoot was empty at parse time
if (-not $ConfigFile -or -not (Test-Path $ConfigFile)) {
    $ConfigFile = Join-Path $PSScriptRoot "config.json"
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "output"
}

# ── Banner ──
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║   vsphere-vcf-readiness v$script:ToolVersion                  ║" -ForegroundColor Cyan
Write-Host "  ║   VCF Migration Readiness Assessment             ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── Load Config ──
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    return
}
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
Write-Host "[*] Config loaded: VCF target $($config.targetVcfVersion), storage: $($config.storageType)" -ForegroundColor Green

# ══════════════════════════════════════════════════════════════
# Resolve vCenter Server (priority: param > config > prompt)
# ══════════════════════════════════════════════════════════════

if (-not $VCenterServer -and -not $WhatIfPreference) {
    $configDefault = if ($config.vcenterServer) { $config.vcenterServer } else { $null }

    if ($configDefault) {
        $input = Read-Host "  [?] vCenter Server address (Enter for $configDefault)"
        $VCenterServer = if ($input.Trim()) { $input.Trim() } else { $configDefault }
    } else {
        $VCenterServer = Read-Host "  [?] vCenter Server address"
    }

    Write-Host "[*] vCenter: $VCenterServer" -ForegroundColor Green

    # Offer to save to config if entered a new/different value
    if ($VCenterServer -ne $configDefault) {
        $saveVc = Read-Host "  [?] Save to config.json? [Y/N]"
        if ($saveVc -match '^[Yy]') {
            $config.vcenterServer = $VCenterServer
            $config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
            Write-Host "[*] config.json updated: vcenterServer = $VCenterServer" -ForegroundColor Green
        }
    }
}

# ══════════════════════════════════════════════════════════════
# Resolve Credential (priority: param > saved file > prompt)
# ══════════════════════════════════════════════════════════════

if (-not $Credential -and -not $WhatIfPreference) {
    # Try saved credential file
    if (Test-Path $script:CredentialFile) {
        try {
            $savedCred = Import-Clixml -Path $script:CredentialFile
            $savedUser = $savedCred.UserName
            Write-Host ""
            $useSaved = Read-Host "  Saved credential found for [$savedUser], use it? [Y/N]"
            if ($useSaved -match '^[Yy]') {
                $Credential = $savedCred
                Write-Host "[*] Using saved credential: $savedUser" -ForegroundColor Green
            }
        } catch {
            Write-Warning "Failed to load saved credential: $_"
        }
    }

    # If still no credential, prompt and offer to save
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter vCenter credentials for $VCenterServer"
        if ($Credential) {
            Write-Host ""
            $saveIt = Read-Host "  Save credential for next time? [Y/N]"
            if ($saveIt -match '^[Yy]') {
                $Credential | Export-Clixml -Path $script:CredentialFile -Force
                Write-Host "[*] Credential saved to $script:CredentialFile" -ForegroundColor Green
            }
        }
    }
}

# ── Load Requirements Matrix ──
$reqFile = Join-Path $PSScriptRoot "checks" "requirements" "vcf-$($config.targetVcfVersion).json"
if (-not (Test-Path $reqFile)) {
    Write-Error "Requirements matrix not found for VCF $($config.targetVcfVersion): $reqFile"
    return
}
$requirements = Get-Content $reqFile -Raw | ConvertFrom-Json
if (-not $requirements) {
    Write-Error "Failed to parse requirements matrix: $reqFile"
    return
}
Write-Host "[*] Requirements loaded: VCF $($requirements.vcfVersion)" -ForegroundColor Green

# ── Load Check Modules ──
$checksDir = Join-Path $PSScriptRoot "checks"
$checkModules = @(
    "Invoke-ComputeCheck"
    "Invoke-StorageCheck"
    "Invoke-NetworkCheck"
    "Invoke-SoftwareCheck"
    "Invoke-LicensingCheck"
)

foreach ($mod in $checkModules) {
    $modPath = Join-Path $checksDir "$mod.ps1"
    if (Test-Path $modPath) {
        . $modPath
        Write-Host "[*] Loaded: $mod" -ForegroundColor DarkGray
    } else {
        Write-Warning "Module not found, skipping: $modPath"
    }
}

# ── Ensure output directory ──
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# ══════════════════════════════════════════════════════════════
# WhatIf Mock Data Generators
# ══════════════════════════════════════════════════════════════

function New-MockHosts {
    param([int]$Count = 10)

    $cpuModels = @(
        "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz",      # Ice Lake
        "Intel(R) Xeon(R) Gold 6348 CPU @ 2.60GHz",      # Ice Lake
        "Intel(R) Xeon(R) Platinum 8380 CPU @ 2.30GHz",  # Ice Lake
        "Intel(R) Xeon(R) Gold 6248R CPU @ 3.00GHz",     # Cascade Lake
        "Intel(R) Xeon(R) Gold 5218 CPU @ 2.30GHz",      # Cascade Lake
        "Intel(R) Xeon(R) Silver 4210 CPU @ 2.20GHz",    # Cascade Lake
        "Intel(R) Xeon(R) E5-2680 v4 @ 2.40GHz",        # Broadwell
        "Intel(R) Xeon(R) E5-2690 v3 @ 2.60GHz",        # Haswell
        "Intel(R) Xeon(R) Gold 6430 CPU @ 2.10GHz",      # Sapphire Rapids
        "Intel(R) Xeon(R) Platinum 8490H CPU @ 1.90GHz"  # Sapphire Rapids
    )

    $versions      = @("8.0.2","8.0.2","8.0.2","7.0.3","7.0.3","7.0.3","8.0.2","7.0.2","8.0.2","8.0.1")
    $ramOptions    = @(512, 512, 768, 384, 256, 192, 256, 128, 384, 1024)
    $nicOptions    = @(4, 4, 6, 4, 2, 2, 4, 2, 4, 6)
    $cpuSockets    = @(2, 2, 2, 2, 2, 2, 2, 2, 2, 2)
    $coresPerSock  = @(32, 28, 40, 24, 16, 10, 14, 12, 32, 60)
    $bootDevices   = @("SSD","SSD","NVMe","SSD","SSD","SSD","SSD","USB","NVMe","NVMe")

    $hosts = for ($i = 0; $i -lt $Count; $i++) {
        $prefix = switch ($i) { {$_ -le 5}{"prod"} {$_ -in 6,7}{"mgmt"} default{"edge"} }
        $num = switch ($i) { {$_ -le 5}{$i+1} {$_ -eq 6}{1} {$_ -eq 7}{2} {$_ -eq 8}{1} {$_ -eq 9}{2} }

        $cluster = switch ($prefix) { "prod"{"Cluster-Prod"} "mgmt"{"Cluster-Mgmt"} "edge"{"Cluster-Edge"} }
        [PSCustomObject]@{
            Name            = "esx-${prefix}{0:D2}.megacorp.local" -f $num
            Cluster         = $cluster
            ProcessorType   = $cpuModels[$i]
            CpuModel        = $cpuModels[$i]
            MemoryTotalGB   = $ramOptions[$i]
            _MockNicCount   = $nicOptions[$i]
            _MockBootDevice = $bootDevices[$i]
            _MockDnsForward = $true
            _MockDnsReverse = if ($i -in 8,9) { $false } else { $true }
            _MockNtpDrift   = if ($i -eq 3) { 3.2 } elseif ($i -eq 7) { 8.7 } else { 0.1 }
            _MockSshEnabled = if ($i -in 3,6,7) { $true } else { $false }
            _MockVsanUsageTiB = if ($i -le 5) { 8.0 } else { 0 }
            ConnectionState = "Connected"
            Version         = $versions[$i]
            Build           = "22380479"
            CpuSockets      = $cpuSockets[$i]
            CoresPerSocket  = $coresPerSock[$i]
        }
    }
    return $hosts
}

function New-MockDatastores {
    @(
        [PSCustomObject]@{ Name = "vsanDatastore-Prod"; CapacityGB = 20480; FreeSpaceGB = 2458; Type = "vsan" }
        [PSCustomObject]@{ Name = "vsanDatastore-Mgmt"; CapacityGB = 5120;  FreeSpaceGB = 1126; Type = "vsan" }
        [PSCustomObject]@{ Name = "vsanDatastore-Edge"; CapacityGB = 10240; FreeSpaceGB = 5939; Type = "vsan" }
    )
}

function New-MockSnapshots {
    @(
        [PSCustomObject]@{ VM = "vm-oracle-db01";     Name = "pre-patch-jan";  Created = (Get-Date).AddDays(-45); SizeGB = 320 }
        [PSCustomObject]@{ VM = "vm-legacy-app03";    Name = "backup-old";     Created = (Get-Date).AddDays(-62); SizeGB = 89 }
        [PSCustomObject]@{ VM = "vm-web-frontend02";  Name = "test-snap";      Created = (Get-Date).AddDays(-12); SizeGB = 15 }
        [PSCustomObject]@{ VM = "vm-dev-test01";      Name = "before-update";  Created = (Get-Date).AddDays(-9);  SizeGB = 8 }
    )
}

function New-MockVCenter {
    [PSCustomObject]@{ Name = "vcsa-prod.megacorp.local"; Version = "8.0.3" }
}

function New-MockClusters {
    @(
        [PSCustomObject]@{ Name = "Cluster-Prod"; VlcmMode = "Image" }
        [PSCustomObject]@{ Name = "Cluster-Mgmt"; VlcmMode = "Baseline" }
        [PSCustomObject]@{ Name = "Cluster-Edge"; VlcmMode = "Baseline" }
    )
}

function New-MockVMs {
    $vms = [System.Collections.Generic.List[psobject]]::new()
    for ($i = 1; $i -le 142; $i++) {
        $toolsVer = if ($i -le 34) { "10.3.5" } else { "12.1.0" }
        $vms.Add([PSCustomObject]@{ Name = "vm-mock-$i"; ToolsVersion = $toolsVer })
    }
    return $vms.ToArray()
}

function New-MockLicenses {
    @(
        [PSCustomObject]@{ Name = "vSphere Enterprise Plus"; LicenseKey = "XXXXX-XXXXX-XXXXX"; ExpiryDate = (Get-Date).AddDays(84).ToString("yyyy-MM-dd"); CostUnit = "cpuPackage" }
        [PSCustomObject]@{ Name = "vSAN Enterprise";         LicenseKey = "YYYYY-YYYYY-YYYYY"; ExpiryDate = (Get-Date).AddDays(84).ToString("yyyy-MM-dd"); CostUnit = "cpuPackage" }
    )
}

# ══════════════════════════════════════════════════════════════
# Main Execution
# ══════════════════════════════════════════════════════════════

$allResults = [System.Collections.Generic.List[psobject]]::new()

if ($WhatIfPreference) {
    Write-Host ""
    Write-Host "[!] WhatIf mode — using mock data (no vCenter connection)" -ForegroundColor Yellow
    Write-Host ""

    $mockHosts      = New-MockHosts -Count 10
    $mockDatastores = New-MockDatastores
    $mockSnapshots  = New-MockSnapshots
    $mockVCenter    = New-MockVCenter
    $mockClusters   = New-MockClusters
    $mockVMs        = New-MockVMs
    $mockLicenses   = New-MockLicenses

    Write-Host "[*] Generated $($mockHosts.Count) mock hosts:" -ForegroundColor Cyan
    foreach ($h in $mockHosts) {
        $cpuShort = $h.ProcessorType -replace 'Intel\(R\) Xeon\(R\) ','' -replace ' CPU',''
        Write-Host ("    - {0,-38} ESXi {1}  CPU: {2}" -f $h.Name, $h.Version, $cpuShort) -ForegroundColor DarkGray
    }
    Write-Host ""

    # Run all check modules with mock data
    if (Get-Command Invoke-ComputeCheck -ErrorAction SilentlyContinue) {
        Write-Host "[>] Running Compute checks..." -ForegroundColor Cyan
        $r = Invoke-ComputeCheck -Config $config -Requirements $requirements -VMHosts $mockHosts
        $r | ForEach-Object { $allResults.Add($_) }
    }

    if (Get-Command Invoke-StorageCheck -ErrorAction SilentlyContinue) {
        Write-Host "[>] Running Storage checks..." -ForegroundColor Cyan
        $r = Invoke-StorageCheck -Config $config -Requirements $requirements -VMHosts $mockHosts -MockDatastores $mockDatastores -MockSnapshots $mockSnapshots
        $r | ForEach-Object { $allResults.Add($_) }
    }

    if (Get-Command Invoke-NetworkCheck -ErrorAction SilentlyContinue) {
        Write-Host "[>] Running Network checks..." -ForegroundColor Cyan
        $r = Invoke-NetworkCheck -Config $config -Requirements $requirements -VMHosts $mockHosts
        $r | ForEach-Object { $allResults.Add($_) }
    }

    if (Get-Command Invoke-SoftwareCheck -ErrorAction SilentlyContinue) {
        Write-Host "[>] Running Software checks..." -ForegroundColor Cyan
        $r = Invoke-SoftwareCheck -Config $config -Requirements $requirements -VMHosts $mockHosts -MockVCenter $mockVCenter -MockClusters $mockClusters -MockVMs $mockVMs
        $r | ForEach-Object { $allResults.Add($_) }
    }

    if (Get-Command Invoke-LicensingCheck -ErrorAction SilentlyContinue) {
        Write-Host "[>] Running Licensing checks..." -ForegroundColor Cyan
        $r = Invoke-LicensingCheck -Config $config -Requirements $requirements -VMHosts $mockHosts -MockLicenses $mockLicenses
        $r | ForEach-Object { $allResults.Add($_) }
    }

} else {
    # ── Real connection ──
    if (-not $VCenterServer) {
        Write-Error "VCenterServer is required. Set it via -VCenterServer parameter, vcenterServer in config.json, or enter it when prompted."
        return
    }

    Write-Host "[*] Connecting to $VCenterServer ..." -ForegroundColor Cyan

    try {
        if ($Credential) {
            Connect-VIServer -Server $VCenterServer -Credential $Credential | Out-Null
        } else {
            Connect-VIServer -Server $VCenterServer | Out-Null
        }
        Write-Host "[*] Connected to $VCenterServer" -ForegroundColor Green
    } catch {
        Write-Error "Failed to connect to $VCenterServer : $_"
        return
    }

    # Run all check modules
    $moduleRuns = @(
        @{ Name = "Compute";   Cmd = "Invoke-ComputeCheck";   Args = @{ Config = $config; Requirements = $requirements } }
        @{ Name = "Storage";   Cmd = "Invoke-StorageCheck";   Args = @{ Config = $config; Requirements = $requirements } }
        @{ Name = "Network";   Cmd = "Invoke-NetworkCheck";   Args = @{ Config = $config; Requirements = $requirements } }
        @{ Name = "Software";  Cmd = "Invoke-SoftwareCheck";  Args = @{ Config = $config; Requirements = $requirements } }
        @{ Name = "Licensing"; Cmd = "Invoke-LicensingCheck"; Args = @{ Config = $config; Requirements = $requirements } }
    )

    foreach ($run in $moduleRuns) {
        if (Get-Command $run.Cmd -ErrorAction SilentlyContinue) {
            Write-Host "[>] Running $($run.Name) checks..." -ForegroundColor Cyan
            try {
                $r = & $run.Cmd @($run.Args)
                $r | ForEach-Object { $allResults.Add($_) }
            } catch {
                Write-Warning "$($run.Name) check failed: $_"
                $allResults.Add([PSCustomObject]@{
                    Category        = $run.Name
                    CheckName       = "Module Error"
                    Status          = "INFO"
                    Severity        = "Requirement"
                    Score           = 0
                    AffectedObjects = @()
                    Description     = "Check module failed: $_"
                    Remediation     = "Review error and retry."
                })
            }
        }
    }

    try { Disconnect-VIServer -Server $VCenterServer -Confirm:$false } catch {}
}

# ══════════════════════════════════════════════════════════════
# Scoring Engine (Severity-weighted)
# ══════════════════════════════════════════════════════════════

$baseScore    = 100
$totalPenalty = 0

foreach ($result in $allResults) {
    $penalty = switch ("$($result.Status)_$($result.Severity)") {
        "BLOCK_Requirement"   { -20 }
        "BLOCK_BestPractice"  { -10 }
        "WARN_Requirement"    { -5 }
        "WARN_BestPractice"   { -2 }
        default               { 0 }
    }
    $totalPenalty += $penalty
}

$penaltyScore = [math]::Max(0, $baseScore + $totalPenalty)

# Overall score = weighted average of category scores (more representative than raw penalty)
# Falls back to penalty score if no categories

# ── Category Scores ──
$categories = $allResults | Select-Object -ExpandProperty Category -Unique
$categoryScores = @{}
foreach ($cat in $categories) {
    $catResults = $allResults | Where-Object { $_.Category -eq $cat }
    $catPenalty = 0
    foreach ($r in $catResults) {
        $catPenalty += switch ("$($r.Status)_$($r.Severity)") {
            "BLOCK_Requirement"   { -20 }
            "BLOCK_BestPractice"  { -10 }
            "WARN_Requirement"    { -5 }
            "WARN_BestPractice"   { -2 }
            default               { 0 }
        }
    }
    $categoryScores[$cat] = [math]::Max(0, 100 + $catPenalty)
}

# Overall score = average of category scores (capped by blocker presence)
if ($categoryScores.Count -gt 0) {
    $avgCatScore = [math]::Round(($categoryScores.Values | Measure-Object -Average).Average, 0)
    $finalScore = $avgCatScore
} else {
    $finalScore = $penaltyScore
}

# ── Summary Counts ──
$blocks   = ($allResults | Where-Object { $_.Status -eq "BLOCK" }).Count
$warnings = ($allResults | Where-Object { $_.Status -eq "WARN" }).Count
$passes   = ($allResults | Where-Object { $_.Status -eq "PASS" }).Count
$infos    = ($allResults | Where-Object { $_.Status -eq "INFO" }).Count

# ══════════════════════════════════════════════════════════════
# Console Output
# ══════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ┌─────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  │         READINESS SUMMARY            │" -ForegroundColor Cyan
Write-Host "  ├─────────────────────────────────────┤" -ForegroundColor Cyan
Write-Host ("  │  Overall Score : {0,3}/100              │" -f $finalScore) -ForegroundColor $(
    if ($finalScore -ge 80) { "Green" } elseif ($finalScore -ge 50) { "Yellow" } else { "Red" }
)
Write-Host ("  │  Blockers      : {0,3}                   │" -f $blocks) -ForegroundColor $(if ($blocks -gt 0) { "Red" } else { "Green" })
Write-Host ("  │  Warnings      : {0,3}                   │" -f $warnings) -ForegroundColor $(if ($warnings -gt 0) { "Yellow" } else { "Green" })
Write-Host ("  │  Passed        : {0,3}                   │" -f $passes) -ForegroundColor Green
Write-Host ("  │  Info          : {0,3}                   │" -f $infos) -ForegroundColor Cyan
Write-Host "  └─────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

# Category breakdown
Write-Host "  CATEGORY SCORES:" -ForegroundColor Cyan
foreach ($cat in ($categoryScores.GetEnumerator() | Sort-Object Key)) {
    $color = if ($cat.Value -ge 80) { "Green" } elseif ($cat.Value -ge 50) { "Yellow" } else { "Red" }
    $bar = ("█" * [math]::Floor($cat.Value / 5)) + ("░" * (20 - [math]::Floor($cat.Value / 5)))
    Write-Host ("  {0,-12} {1} {2,3}/100" -f $cat.Key, $bar, $cat.Value) -ForegroundColor $color
}
Write-Host ""

# Issues detail
if ($blocks -gt 0 -or $warnings -gt 0) {
    Write-Host "  ISSUES FOUND:" -ForegroundColor Yellow
    Write-Host "  ─────────────" -ForegroundColor Yellow

    foreach ($r in ($allResults | Where-Object { $_.Status -in @("BLOCK","WARN") } | Sort-Object @{E={if($_.Status -eq "BLOCK"){0}else{1}}}, Category)) {
        $color = if ($r.Status -eq "BLOCK") { "Red" } else { "Yellow" }
        $icon  = if ($r.Status -eq "BLOCK") { "■" } else { "▲" }
        $sev   = if ($r.Severity -eq "Requirement") { "REQ" } else { "BP" }
        Write-Host "  $icon [$($r.Status)][$sev] $($r.CheckName) ($($r.Category))" -ForegroundColor $color
        Write-Host "    $($r.Description)" -ForegroundColor Gray
        Write-Host "    Fix: $($r.Remediation)" -ForegroundColor DarkGray
        Write-Host ""
    }
}

# ══════════════════════════════════════════════════════════════
# Build Results Object
# ══════════════════════════════════════════════════════════════

$hostInventory = if ($WhatIfPreference) {
    $mockHosts
} else {
    try {
        Get-VMHost | Where-Object { $_.Name -notin $config.excludeHosts } | ForEach-Object {
            $nicCount   = try { (Get-VMHostNetworkAdapter -VMHost $_ -Physical | Measure-Object).Count } catch { 0 }
            $sockets    = try { $_.ExtensionData.Hardware.CpuInfo.NumCpuPackages } catch { 0 }
            $coresTotal = try { $_.ExtensionData.Hardware.CpuInfo.NumCpuCores } catch { 0 }
            $coresPerS  = if ($sockets -gt 0) { [math]::Floor($coresTotal / $sockets) } else { 0 }
            $clusterName = try { (Get-Cluster -VMHost $_).Name } catch { "Unknown" }
            [PSCustomObject]@{
                Name           = $_.Name
                Cluster        = $clusterName
                Version        = $_.Version
                Build          = $_.Build
                ProcessorType  = $_.ProcessorType
                MemoryTotalGB  = [math]::Round($_.MemoryTotalGB, 0)
                CpuSockets     = $sockets
                CoresPerSocket = $coresPerS
                _MockNicCount  = $nicCount
            }
        }
    } catch { @() }
}

$script:ReadinessResults = [PSCustomObject]@{
    Score          = $finalScore
    BaseScore      = $baseScore
    TotalPenalty   = $totalPenalty
    TotalChecks    = $allResults.Count
    Blockers       = $blocks
    Warnings       = $warnings
    Passed         = $passes
    Info           = $infos
    CategoryScores = $categoryScores
    Results        = $allResults.ToArray()
    Hosts          = $hostInventory
    Timestamp      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    VCenter        = if ($WhatIfPreference) { "WhatIf-Mock" } else { $VCenterServer }
    VCenterVersion = if ($WhatIfPreference -and $mockVCenter) { $mockVCenter.Version } else { "" }
    TargetVcf      = $config.targetVcfVersion
    StorageType    = $config.storageType
    ToolVersion    = $script:ToolVersion
}

# ── Report Generation ──
$reportModulePath = Join-Path $PSScriptRoot "report" "New-HtmlReport.ps1"
$reportFile = $null
if (Test-Path $reportModulePath) {
    . $reportModulePath
    if (Get-Command New-HtmlReport -ErrorAction SilentlyContinue) {
        $reportFile = New-HtmlReport -ReadinessResults $script:ReadinessResults -OutputPath $OutputPath -Format $ReportFormat
        Write-Host "[*] Report saved: $reportFile" -ForegroundColor Green
    }
}

Write-Host "[*] Assessment complete. $($allResults.Count) checks evaluated." -ForegroundColor Green

# ── Open HTML report in browser ──
if ($reportFile) {
    $htmlReport = if ($reportFile -match ',') {
        # Multiple formats — find the HTML one
        ($reportFile -split ',\s*') | Where-Object { $_ -match '\.html$' } | Select-Object -First 1
    } else { $reportFile }

    if ($htmlReport -and (Test-Path $htmlReport)) {
        Write-Host "[*] Opening report in browser..." -ForegroundColor DarkGray
        try { Invoke-Item $htmlReport } catch {}
    }
}

# ── Keep window open if launched by double-click ──
if ($Host.Name -eq 'ConsoleHost' -and -not $WhatIfPreference) {
    # Detect if running interactively (double-click scenario)
    $parentProcess = try { (Get-Process -Id $PID).Parent.ProcessName } catch { "" }
    if ($parentProcess -in @("explorer","cmd","powershell","pwsh")) {
        Write-Host ""
        Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}
