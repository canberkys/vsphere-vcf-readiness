# vsphere-vcf-readiness

Open-source PowerShell tool that analyzes existing vSphere 7/8 environments and generates a scored readiness report for VMware Cloud Foundation (VCF) 9.0.x migration.

## Why This Tool?

VCF Import Tool only validates brownfield import. VCF Diagnostic Tool (VDT) is for troubleshooting. **vsphere-vcf-readiness** fills the gap: a holistic pre-migration assessment that covers compute, storage, network, software, and licensing — with actionable remediation guidance.

## Requirements

- PowerShell 7.2+
- VMware.PowerCLI module (`Install-Module VMware.PowerCLI`)
- Read-only vCenter credentials (sufficient for all checks)

## Quick Start

```powershell
# Install PowerCLI
Install-Module VMware.PowerCLI -Scope CurrentUser -AllowClobber

# Clone the repo
git clone https://github.com/canberkys/vsphere-vcf-readiness.git
cd vsphere-vcf-readiness

# Edit config.json for your environment
code config.json

# Run with vCenter connection
.\vsphere-vcf-readiness.ps1 -VCenterServer vcsa.lab.local -Credential (Get-Credential)

# Run in WhatIf mode (mock data, no connection)
.\vsphere-vcf-readiness.ps1 -WhatIf

# Export all formats
.\vsphere-vcf-readiness.ps1 -WhatIf -ReportFormat All
```

## Configuration (config.json)

| Key | Description | Values |
|-----|-------------|--------|
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

Reports are generated in `output/` directory:
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

## License

MIT
