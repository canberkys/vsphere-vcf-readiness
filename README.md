# vsphere-vcf-readiness

Open-source PowerShell tool that analyzes existing vSphere 7/8 environments and generates a scored readiness report for VMware Cloud Foundation (VCF) 9.0.x migration.

**[View Live Demo Report](https://canberkys.github.io/vsphere-vcf-readiness/)**

## Why This Tool?

VCF Import Tool only validates brownfield import. VCF Diagnostic Tool (VDT) is for troubleshooting. **vsphere-vcf-readiness** fills the gap: a holistic pre-migration assessment that covers compute, storage, network, software, and licensing with actionable remediation guidance and direct links to official Broadcom documentation.

## Requirements

- PowerShell 7.2+ (script auto-relaunches in pwsh if opened with PS 5.1)
- VMware.PowerCLI module (`Install-Module VMware.PowerCLI`)
- Read-only vCenter credentials (sufficient for all checks)

## Quick Start

### 1. Install Prerequisites

```powershell
# PowerShell 7.2+ required (script auto-relaunches if opened with PS 5.1)
# Download: https://github.com/PowerShell/PowerShell

# Install VMware PowerCLI
Install-Module VMware.PowerCLI -Scope CurrentUser -AllowClobber
```

### 2. Download the Tool

```powershell
git clone https://github.com/canberkys/vsphere-vcf-readiness.git
cd vsphere-vcf-readiness
```

### 3. Configure

Edit `config.json` with your environment details:

```json
{
    "vcenterServer": "vcsa.corp.local",
    "targetVcfVersion": "9.0.1",
    "storageType": "vsan-esa",
    "excludeHosts": ["esx-witness01.corp.local"],
    "excludeDatastorePatterns": ["x_localdisk_*"]
}
```

### 4. Run

```powershell
# Simplest - vCenter from config, credential prompted (saved for next time)
.\vsphere-vcf-readiness.ps1

# Explicit parameters
.\vsphere-vcf-readiness.ps1 -VCenterServer vcsa.corp.local -Credential (Get-Credential)

# Test without vCenter (mock data)
.\vsphere-vcf-readiness.ps1 -WhatIf

# Export all formats (HTML + JSON + CSV)
.\vsphere-vcf-readiness.ps1 -ReportFormat All
```

The HTML report opens automatically in your browser when the assessment completes.

## Credential Management

The script resolves credentials in this order:

| Priority | Source | When |
|----------|--------|------|
| 1 | `-Credential` parameter | Explicitly passed on command line |
| 2 | Saved credential file | `~/.vcf-readiness-cred.xml` exists |
| 3 | Interactive prompt | No saved credential found |

### First Run

On first run, after entering credentials you will be asked:

```
Save credential for next time? [Y/N]
```

If you choose **Y**, the credential is saved as an encrypted XML file at `~/.vcf-readiness-cred.xml` using PowerShell's `Export-Clixml` (encrypted with the current user's Windows DPAPI key - only readable by the same user on the same machine).

### Subsequent Runs

```
Saved credential found for [admin@vsphere.local], use it? [Y/N]
```

Choose **Y** to use the saved credential, or **N** to enter a new one.

### Delete Saved Credential

```powershell
Remove-Item ~/.vcf-readiness-cred.xml
```

## Configuration (config.json)

| Key | Description | Values |
|-----|-------------|--------|
| `vcenterServer` | vCenter FQDN/IP (used if `-VCenterServer` param not given) | `"vcsa.lab.local"` |
| `targetVcfVersion` | Target VCF version | `"9.0.0"`, `"9.0.1"` |
| `storageType` | Storage architecture | `"vsan-osa"`, `"vsan-esa"`, `"fc-vmfs"`, `"nfs"` |
| `checkHcl` | Query vSAN HCL online | `true` / `false` |
| `excludeHosts` | Hosts to skip | `["witness01.lab.local"]` |
| `excludeDatastorePatterns` | Datastore name patterns to skip (wildcard) | `["x_localdisk_*"]` |

## Project Structure

```
vsphere-vcf-readiness/
├── vsphere-vcf-readiness.ps1          # Main entry point
├── config.json                         # User configuration
├── checks/
│   ├── Invoke-ComputeCheck.ps1        # CPU, NIC, RAM, host count
│   ├── Invoke-StorageCheck.ps1        # Datastore, snapshots, boot device
│   ├── Invoke-NetworkCheck.ps1        # MTU, DNS, NTP, SSH
│   ├── Invoke-SoftwareCheck.ps1       # ESXi, vCenter, vLCM, VMware Tools
│   ├── Invoke-LicensingCheck.ps1      # Core count, license expiry, vSAN
│   └── requirements/
│       ├── vcf-9.0.0.json             # VCF 9.0.0 requirement matrix
│       └── vcf-9.0.1.json             # VCF 9.0.1 requirement matrix
├── report/
│   └── New-HtmlReport.ps1            # HTML/JSON/CSV report engine
├── docs/
│   └── index.html                     # GitHub Pages live demo
└── output/                            # Generated reports (per-run)
```

## Check Categories

| Category | Checks | Reference |
|----------|--------|-----------|
| **Compute** | CPU generation (blocked/deprecated), NIC count, RAM capacity, host count | [KB 318697](https://knowledge.broadcom.com/external/article/318697) |
| **Storage** | Datastore usage, snapshot age, USB/SD boot, vSAN HCL | [KB 317631](https://knowledge.broadcom.com/external/article/317631) |
| **Network** | VMkernel MTU (1600 req / 9000 rec), DNS fwd/rev, NTP, SSH | [KB 318697](https://knowledge.broadcom.com/external/article/318697) |
| **Software** | ESXi version (8.0+ required), vCenter version, vLCM image mode, VMware Tools | [KB 322186](https://knowledge.broadcom.com/external/article/322186) |
| **Licensing** | Core count (max(cores,16) x sockets), license expiry, vSAN entitlement | [KB 313548](https://knowledge.broadcom.com/external/article/313548) |

## Severity Levels

Each check result includes both a **Status** and a **Severity**:

| Severity | Meaning | Scoring Impact |
|----------|---------|---------------|
| **REQ** (Requirement) | Official VCF gate - must be resolved | BLOCK: -20, WARN: -5 |
| **BP** (Best Practice) | Recommended but not mandatory | BLOCK: -10, WARN: -2 |

## Scoring

Overall score is the average of all category scores. Each category starts at 100 and applies penalties per issue.

| Score | Verdict |
|-------|---------|
| 80-100 | Ready |
| 60-79 | Needs Work |
| 40-59 | At Risk |
| 0-39 | Not Ready |

## Report Features

Reports are generated in `output/` directory and automatically opened in browser.

| Format | Use Case |
|--------|----------|
| **HTML** | Standalone dark-theme report - no dependencies, works offline |
| **JSON** | Machine-readable results for automation/CI |
| **CSV** | Flat export for spreadsheet analysis |

### HTML Report Highlights

- Animated score ring with category breakdown bars
- Per-category filter buttons: **[All] [Block] [Warn] [Pass]** (color-coded)
- Results grouped by check type (e.g. "CPU Generation - 8x" instead of 8 separate rows)
- PASS/INFO rows hidden by default with expandable toggle
- Clickable "+N more" on affected objects - expands inline
- Host inventory cards with red/amber/green status dots
- Prioritized remediation roadmap with direct Broadcom KB links
- Fully standalone (inline CSS/JS, no external dependencies except Google Fonts)

### Sample Report

**[View Live Demo](https://canberkys.github.io/vsphere-vcf-readiness/)** - 16 mock hosts, 50 checks, all UI features demonstrated.

## Data Sources

All thresholds are driven by version-specific requirement matrices (`checks/requirements/vcf-*.json`), sourced from official Broadcom documentation:

- [CPU Deprecation & Discontinuation (KB 318697)](https://knowledge.broadcom.com/external/article/318697)
- [Deprecated CPU Systems in ESXi 9.0 (KB 428874)](https://knowledge.broadcom.com/external/article/428874)
- [USB/SD Boot Guidance (KB 317631)](https://knowledge.broadcom.com/external/article/317631)
- [vLCM Image Requirement (KB 322186)](https://knowledge.broadcom.com/external/article/322186)
- [Core-Based Licensing (KB 313548)](https://knowledge.broadcom.com/external/article/313548)

## Changelog

### v0.6.0
- **feat:** Cluster-based host grouping - hosts displayed under cluster headers with status indicators
- **feat:** Executive Summary - print-friendly overview with score, top 3 blockers, environment info
- **feat:** Dark/Light theme toggle button in header
- **feat:** Save as PDF button (browser print with optimized CSS, zero dependency)
- **feat:** Cluster data collected in both real mode (Get-Cluster) and WhatIf mock

### v0.5.2
- **feat:** Clickable Broadcom KB links in all BLOCK/WARN remediation text
- **feat:** GitHub Pages live demo - example report viewable in browser
- **fix:** Replaced broken `techdocs.broadcom.com` URLs (403) with accessible KB articles
- **fix:** All em dashes replaced with regular dashes for consistency
- **fix:** Overall score now uses category average instead of raw penalty (prevents misleading 0/100 when most categories score well)

### v0.5.1
- **feat:** "+N more" is now clickable - expands to show all objects, click again to collapse
- **feat:** Score ring animates on page load (counter + ring fill)
- **feat:** Filter buttons color-coded per status (red/amber/green when active)
- **feat:** Host cards: status dot indicator, CPU tooltip on hover, cores/sockets info
- **feat:** Roadmap cards show affected object count badge
- **fix:** Long hostnames no longer overflow table columns
- **fix:** try/catch inside hashtable literal caused PowerShell parse error in host inventory builder

### v0.5.0
- **fix:** Datastore threshold null bug - all datastores showed as BLOCK when Requirements matrix wasn't loaded
- **fix:** All 5 check modules now use null-safe defaults when Requirements is null
- **fix:** Host Inventory now populated in real mode (was hardcoded empty)
- **feat:** Report results grouped by CheckName+Status (24 identical rows become 1 with count badge)
- **feat:** PASS/INFO rows hidden by default with "Show X passed" toggle
- **feat:** Filter buttons per category table: [All] [Block] [Warn] [Pass]
- **feat:** `excludeDatastorePatterns` in config.json to skip local/scratch disks

### v0.4.2
- **feat:** Interactive vCenter prompt shows config default: `(Enter for vcsa.lab.local)`
- **feat:** New/changed vCenter address can be saved back to config.json

### v0.4.1
- **fix:** `[CmdletBinding]` + `param()` moved before PS 5.1 guard

### v0.4.0
- **feat:** Credential auto-management with `Export-Clixml` / `Import-Clixml`
- **feat:** PS 5.1 auto-relaunch in pwsh
- **feat:** Auto-open HTML report in browser after assessment
- **feat:** "Press any key to exit" for double-click scenarios

### v0.3.0
- **feat:** `vcenterServer` in config.json
- **fix:** `$PSScriptRoot` fallback for interactive/dot-source sessions

### v0.2.0
- **feat:** 5 check modules (Compute, Storage, Network, Software, Licensing)
- **feat:** Severity-weighted scoring (Requirement vs Best Practice)
- **feat:** Version-specific requirement matrices
- **feat:** Dynamic HTML report engine with dark theme
- **feat:** Multi-format export (HTML, JSON, CSV)
- **feat:** WhatIf mode with mock environment
- **fix:** Cascade Lake ESA claim corrected (KB 318697)
- **fix:** MTU 9000 changed from BLOCK to WARN (recommended, not required)
- **fix:** ESXi 7.x upgrade path corrected (no direct path to VCF 9.x)

### v0.1.0
- Initial prototype

## License

MIT
