# vsphere-vcf-readiness

Open-source PowerShell tool that analyzes existing vSphere 7/8 environments and generates a scored readiness report for VMware Cloud Foundation (VCF) 9.0.x migration.

## Why This Tool?

VCF Import Tool only validates brownfield import. VCF Diagnostic Tool (VDT) is for troubleshooting. **vsphere-vcf-readiness** fills the gap: a holistic pre-migration assessment that covers compute, storage, network, software, and licensing — with actionable remediation guidance.

## Requirements

- PowerShell 7.2+ (script auto-relaunches in pwsh if opened with PS 5.1)
- VMware.PowerCLI module (`Install-Module VMware.PowerCLI`)
- Read-only vCenter credentials (sufficient for all checks)

## Quick Start

```powershell
# Install PowerCLI
Install-Module VMware.PowerCLI -Scope CurrentUser -AllowClobber

# Clone the repo
git clone https://github.com/canberkys/vsphere-vcf-readiness.git
cd vsphere-vcf-readiness

# Edit config.json — set vcenterServer to your vCenter FQDN
code config.json

# Just run it — reads vCenter from config, handles credential automatically
.\vsphere-vcf-readiness.ps1

# Or specify everything via parameters
.\vsphere-vcf-readiness.ps1 -VCenterServer vcsa.lab.local -Credential (Get-Credential)

# WhatIf mode — mock data, no vCenter connection needed
.\vsphere-vcf-readiness.ps1 -WhatIf

# Export all report formats (HTML + JSON + CSV)
.\vsphere-vcf-readiness.ps1 -WhatIf -ReportFormat All
```

## Credential Management

The script resolves credentials in this order:

| Priority | Source | When |
|----------|--------|------|
| 1 | `-Credential` parameter | Explicitly passed on command line |
| 2 | Saved credential file | `~/.vcf-readiness-cred.xml` exists |
| 3 | Interactive prompt | No saved credential found |

### First Run

On first run, after entering credentials you'll be asked:

```
Save credential for next time? [Y/N]
```

If you choose **Y**, the credential is saved as an encrypted XML file at `~/.vcf-readiness-cred.xml` using PowerShell's `Export-Clixml` (encrypted with the current user's Windows DPAPI key — only readable by the same user on the same machine).

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
| `vcfAutomationRequired` | Include automation checks | `true` / `false` |
| `checkHcl` | Query vSAN HCL online | `true` / `false` |
| `excludeHosts` | Hosts to skip | `["witness01.lab.local"]` |

## Check Categories

| Category | Checks | Source |
|----------|--------|--------|
| **Compute** | CPU generation (blocked/deprecated), NIC count, RAM capacity, host count | KB 318697, KB 428874 |
| **Storage** | Datastore usage, snapshot age, USB/SD boot, vSAN HCL | KB 317631 |
| **Network** | VMkernel MTU (1600 req / 9000 rec), DNS fwd/rev, NTP, SSH | VCF 9.0 Deployment Guide |
| **Software** | ESXi version (8.0+ required), vCenter version, vLCM image mode, VMware Tools | KB 322186 |
| **Licensing** | Core count (max(cores,16) x sockets), license expiry, vSAN entitlement | KB 313548 |

## Severity Levels

Each check result includes both a **Status** and a **Severity**:

| Severity | Meaning | Scoring Impact |
|----------|---------|---------------|
| **REQ** (Requirement) | Official VCF gate — must be resolved | BLOCK: -20, WARN: -5 |
| **BP** (Best Practice) | Recommended but not mandatory | BLOCK: -10, WARN: -2 |

## Scoring

Base score of 100, penalties applied per issue. Final = max(0, 100 + penalties).

| Score | Verdict |
|-------|---------|
| 80-100 | Ready |
| 60-79 | Needs Work |
| 40-59 | At Risk |
| 0-39 | Not Ready |

## Report Output

Reports are generated in `output/` directory and automatically opened in browser:
- **HTML**: Standalone dark-theme report with score ring, category bars, issue tables, host inventory, remediation roadmap
- **JSON**: Machine-readable results for CI/CD integration
- **CSV**: Flat export for spreadsheet analysis

### Sample Report

An example HTML report is included in [`output/vcf-readiness-report_example.html`](output/vcf-readiness-report_example.html) — open it in any browser to see the full assessment layout with 10 mock hosts, 42 checks, and a prioritized remediation roadmap.

## Data Sources

All thresholds are driven by version-specific requirement matrices (`checks/requirements/vcf-*.json`), sourced from official Broadcom documentation:

- [CPU Deprecation & Discontinuation (KB 318697)](https://knowledge.broadcom.com/external/article/318697)
- [USB/SD Boot Guidance (KB 317631)](https://knowledge.broadcom.com/external/article/317631)
- [vLCM Image Requirement (KB 322186)](https://knowledge.broadcom.com/external/article/322186)
- [Core-Based Licensing (KB 313548)](https://knowledge.broadcom.com/external/article/313548)
- [VCF 9.0 Deployment Planning](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0)

## Changelog

### v0.5.0
- **fix:** Datastore threshold null bug — all datastores showed as BLOCK (even 0.3% usage) when Requirements matrix wasn't loaded. Now uses safe defaults (85%/75%)
- **fix:** All 5 check modules now use null-safe defaults when Requirements is null
- **fix:** Host Inventory now populated in real mode (was hardcoded empty)
- **feat:** Report results grouped by CheckName+Status — 24 identical CPU rows become 1 row with "(8x)" badge
- **feat:** PASS/INFO rows hidden by default with "Show X passed" toggle
- **feat:** Filter buttons per category table: [All] [Block] [Warn] [Pass]
- **feat:** AffectedObjects >5 items collapsed with "+N more" label
- **feat:** `excludeDatastorePatterns` in config.json to skip local/scratch disks

### v0.4.2
- **feat:** Interactive vCenter prompt shows config default: `(Enter for vcsa.lab.local)`
- **feat:** New/changed vCenter address can be saved back to config.json

### v0.4.1
- **fix:** `[CmdletBinding]` + `param()` moved before PS 5.1 guard — PowerShell requires these as first executable statements after help block

### v0.4.0
- **feat:** Credential auto-management — saved credential file (`~/.vcf-readiness-cred.xml`) with interactive save/load prompts, no external modules needed
- **feat:** PS 5.1 auto-relaunch — if opened with Windows PowerShell, script relaunches itself in pwsh
- **feat:** Interactive vCenter prompt — if `vcenterServer` is empty in config, prompts via `Read-Host`
- **feat:** Auto-open HTML report in browser after assessment completes
- **feat:** "Press any key to exit" for double-click execution scenarios
- **fix:** Removed dependency on CredentialManager/SecretManagement modules

### v0.3.0
- **feat:** `vcenterServer` in config.json — no need for `-VCenterServer` parameter
- **fix:** `$PSScriptRoot` empty in interactive/dot-source sessions — added fallback chain

### v0.2.0
- **feat:** 5 check modules — Compute, Storage, Network, Software, Licensing (20 checks total)
- **feat:** Severity-weighted scoring — `Requirement` vs `Best Practice` distinction
- **feat:** Version-specific requirement matrices (`checks/requirements/vcf-9.0.0.json`, `vcf-9.0.1.json`)
- **feat:** Dynamic HTML report engine with dark theme, score ring, remediation roadmap
- **feat:** Multi-format export — HTML, JSON, CSV
- **feat:** WhatIf mode with 10-host mock environment
- **fix:** Cascade Lake incorrectly marked as "vSAN ESA not available" — ESA requires NVMe + 128GB RAM, not a CPU generation (KB 318697)
- **fix:** MTU 9000 incorrectly marked as BLOCK — jumbo frames are recommended, not required. Only NSX overlay requires min MTU 1600 (VCF 9.0 Deployment Guide)
- **fix:** ESXi upgrade path incorrectly stated "minimum 7.0 U3" — there is no direct path from ESXi 7.x to VCF 9.x. Minimum is ESXi 8.0 U1a

### v0.1.0
- Initial prototype — Compute check only, static HTML report

## License

MIT
