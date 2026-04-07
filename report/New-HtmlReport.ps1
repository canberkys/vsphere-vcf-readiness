function New-HtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$ReadinessResults,

        [Parameter()]
        [string]$OutputPath = ".",

        [Parameter()]
        [ValidateSet("HTML","JSON","CSV","All")]
        [string]$Format = "HTML"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd"
    $baseName  = "vcf-readiness-report_$timestamp"
    $outputs   = @()

    if ($Format -in @("JSON","All")) {
        $jsonPath = Join-Path $OutputPath "$baseName.json"
        $ReadinessResults | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
        $outputs += $jsonPath
    }

    if ($Format -in @("CSV","All")) {
        $csvPath = Join-Path $OutputPath "$baseName.csv"
        $ReadinessResults.Results | ForEach-Object {
            [PSCustomObject]@{
                Category        = $_.Category
                CheckName       = $_.CheckName
                Status          = $_.Status
                Severity        = $_.Severity
                Score           = $_.Score
                AffectedObjects = ($_.AffectedObjects -join "; ")
                Description     = $_.Description
                Remediation     = $_.Remediation
            }
        } | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        $outputs += $csvPath
    }

    if ($Format -in @("HTML","All")) {
        $htmlPath = Join-Path $OutputPath "$baseName.html"
        $html     = Build-HtmlContent -R $ReadinessResults
        Set-Content -Path $htmlPath -Value $html -Encoding UTF8
        $outputs += $htmlPath
    }

    return ($outputs -join ", ")
}

function Build-HtmlContent {
    param([psobject]$R)

    # Helper: convert URLs in text to clickable links
    function ConvertTo-LinkedHtml([string]$text) {
        $encoded = [System.Web.HttpUtility]::HtmlEncode($text)
        $encoded -replace '(https?://[^\s&lt;]+)', '<a href="$1" target="_blank" style="color:var(--accent-blue)">$1</a>'
    }

    $score    = $R.Score
    $vcenter  = $R.VCenter
    $vcVer    = $R.VCenterVersion
    $ts       = $R.Timestamp
    $vcf      = $R.TargetVcf
    $storage  = $R.StorageType
    $ver      = $R.ToolVersion

    $circumference = [math]::Round(2 * [math]::PI * 85, 2)
    $offset = [math]::Round($circumference - ($score / 100) * $circumference, 2)
    $ringColor = if ($score -ge 80) { "#3fb950" } elseif ($score -ge 50) { "#d29922" } else { "#f85149" }
    $verdict = if ($score -ge 80) { "Ready" } elseif ($score -ge 60) { "Needs Work" } elseif ($score -ge 40) { "At Risk" } else { "Not Ready" }

    # Category scores HTML
    $catScoresHtml = ""
    foreach ($cat in ($R.CategoryScores.GetEnumerator() | Sort-Object Key)) {
        $catColor = if ($cat.Value -ge 80) { "#3fb950" } elseif ($cat.Value -ge 50) { "#d29922" } else { "#f85149" }
        $catScoresHtml += @"
    <div class="cat-bar-card">
      <div class="cat-bar-header"><span class="name">$($cat.Key)</span><span class="val" style="color:$catColor">$($cat.Value)</span></div>
      <div class="cat-bar-track"><div class="cat-bar-fill" style="width:$($cat.Value)%;background:$catColor"></div></div>
    </div>
"@
    }

    # Executive summary - top 3 blockers
    $topBlockers = $R.Results | Where-Object { $_.Status -eq "BLOCK" } |
        Group-Object -Property { "$($_.CheckName)|$($_.Category)" } |
        Sort-Object Count -Descending | Select-Object -First 3
    $execBlockerHtml = ""
    foreach ($b in $topBlockers) {
        $first = $b.Group[0]
        $execBlockerHtml += "<li><strong>$($first.CheckName)</strong> ($($first.Category)) - $($b.Count) item(s)</li>`n"
    }
    if (-not $execBlockerHtml) { $execBlockerHtml = "<li>No blockers found</li>" }

    # Category detail tables
    $categories = $R.Results | Select-Object -ExpandProperty Category -Unique
    $categoryIcons = @{ Compute="&#9881;"; Storage="&#128190;"; Network="&#127760;"; Software="&#128230;"; Licensing="&#128273;" }
    $categorySections = ""
    $expandId = 0

    foreach ($cat in $categories) {
        $catResults = $R.Results | Where-Object { $_.Category -eq $cat }
        $icon = if ($categoryIcons[$cat]) { $categoryIcons[$cat] } else { "&#9632;" }

        $grouped = $catResults | Group-Object -Property { "$($_.CheckName)|$($_.Status)|$($_.Severity)|$($_.Description)|$($_.Remediation)" }

        $rows = ""
        $passCount = 0

        foreach ($group in $grouped) {
            $first = $group.Group[0]
            $chipClass = switch ($first.Status) { "BLOCK"{"chip-block"} "WARN"{"chip-warn"} "PASS"{"chip-pass"} "INFO"{"chip-info"} }
            $sevLabel = if ($first.Severity -eq "Requirement") { '<span class="sev sev-req">REQ</span>' } else { '<span class="sev sev-bp">BP</span>' }

            $allObjects = @()
            foreach ($item in $group.Group) {
                if ($item.AffectedObjects) { $allObjects += $item.AffectedObjects }
            }
            $allObjects = $allObjects | Select-Object -Unique

            $expandId++
            if ($allObjects.Count -eq 0) {
                $objHtml = "<span class='obj-none'>-</span>"
            } elseif ($allObjects.Count -le 3) {
                $objHtml = ($allObjects | ForEach-Object { "<span class='obj-tag'>$([System.Web.HttpUtility]::HtmlEncode($_))</span>" }) -join ""
            } else {
                $visibleHtml = ($allObjects[0..2] | ForEach-Object { "<span class='obj-tag'>$([System.Web.HttpUtility]::HtmlEncode($_))</span>" }) -join ""
                $hiddenHtml = ($allObjects[3..($allObjects.Count-1)] | ForEach-Object { "<span class='obj-tag'>$([System.Web.HttpUtility]::HtmlEncode($_))</span>" }) -join ""
                $remaining = $allObjects.Count - 3
                $objHtml = "${visibleHtml}<span class='obj-hidden' id='exp-${expandId}' style='display:none'>${hiddenHtml}</span><span class='obj-toggle' onclick='toggleExpand(${expandId})'>+${remaining} more</span>"
            }

            $isPass = $first.Status -in @("PASS","INFO")
            if ($isPass) { $passCount += $group.Count }
            $hideClass = if ($isPass) { "row-pass" } else { "" }
            $hideStyle = if ($isPass) { "display:none" } else { "" }
            $countBadge = if ($group.Count -gt 1) { " <span class='count-badge'>$($group.Count)x</span>" } else { "" }

            $rows += @"
      <tr class="$hideClass" style="$hideStyle" data-status="$($first.Status)">
        <td><span class="chip $chipClass">$sevLabel $($first.Status)</span></td>
        <td class="td-check">$([System.Web.HttpUtility]::HtmlEncode($first.CheckName))$countBadge</td>
        <td class="td-desc">$([System.Web.HttpUtility]::HtmlEncode($first.Description))</td>
        <td class="td-obj">$objHtml</td>
        <td class="td-fix">$(ConvertTo-LinkedHtml $first.Remediation)</td>
      </tr>
"@
        }

        $passToggle = if ($passCount -gt 0) {
            "<div class='pass-toggle' onclick='togglePass(this)'><span class='pass-arrow'>&#9654;</span> Show $passCount passed/info check(s)</div>"
        } else { "" }

        $catId = $cat.ToLower()
        $blockN = ($catResults | Where-Object { $_.Status -eq "BLOCK" }).Count
        $warnN  = ($catResults | Where-Object { $_.Status -eq "WARN" }).Count
        $passN  = ($catResults | Where-Object { $_.Status -in @("PASS","INFO") }).Count

        $categorySections += @"
<section id="$catId">
<div class="container">
  <div class="section-title"><span class="icon">$icon</span> $cat Checks</div>
  <div class="filter-bar">
    <button class="fbtn active" onclick="filterTable(this,'$catId','ALL')">All ($($grouped.Count))</button>
    <button class="fbtn fbtn-block" onclick="filterTable(this,'$catId','BLOCK')">Block ($blockN)</button>
    <button class="fbtn fbtn-warn" onclick="filterTable(this,'$catId','WARN')">Warn ($warnN)</button>
    <button class="fbtn fbtn-pass" onclick="filterTable(this,'$catId','PASS')">Pass ($passN)</button>
  </div>
  <div class="tbl-wrap">
  <table id="tbl-$catId">
    <thead><tr><th style="width:100px">Status</th><th style="width:180px">Check</th><th>Description</th><th style="width:280px">Affected Objects</th><th style="width:260px">Remediation</th></tr></thead>
    <tbody>
$rows
    </tbody>
  </table>
  $passToggle
  </div>
</div>
</section>
"@
    }

    # Host inventory - grouped by cluster
    $hostCards = ""
    $clusters = $R.Hosts | Group-Object -Property { if ($_.Cluster) { $_.Cluster } else { "Unassigned" } } | Sort-Object Name

    foreach ($cluster in $clusters) {
        $clusterName = $cluster.Name
        $clusterHosts = $cluster.Group
        $clusterBlockCount = 0
        $clusterWarnCount = 0
        foreach ($h in $clusterHosts) {
            $hr = $R.Results | Where-Object { $_.AffectedObjects -contains $h.Name }
            if ($hr | Where-Object { $_.Status -eq "BLOCK" }) { $clusterBlockCount++ }
            elseif ($hr | Where-Object { $_.Status -eq "WARN" }) { $clusterWarnCount++ }
        }
        $clusterColor = if ($clusterBlockCount -gt 0) { "var(--color-block)" } elseif ($clusterWarnCount -gt 0) { "var(--color-warn)" } else { "var(--color-pass)" }

        $hostCards += @"
    <div class="cluster-header">
      <span class="cluster-dot" style="background:$clusterColor"></span>
      <span class="cluster-name">$([System.Web.HttpUtility]::HtmlEncode($clusterName))</span>
      <span class="cluster-count">$($clusterHosts.Count) host(s)</span>
    </div>
    <div class="host-grid">
"@

        foreach ($h in $clusterHosts) {
            $cpuShort = if ($h.ProcessorType) {
                $h.ProcessorType -replace 'Intel\(R\) Xeon\(R\) ','' -replace ' CPU','' -replace ' @ .*',''
            } else { "N/A" }
            $totalCores = if ($h.CoresPerSocket -and $h.CpuSockets) { $h.CoresPerSocket * $h.CpuSockets } else { 0 }
            $coreInfo = if ($totalCores -gt 0) { "${totalCores}c / $($h.CpuSockets)s" } else { "" }
            $nicCount = if ($h._MockNicCount) { $h._MockNicCount } else { "?" }

            $hostResults = $R.Results | Where-Object { $_.AffectedObjects -contains $h.Name }
            $hasBlock = ($hostResults | Where-Object { $_.Status -eq "BLOCK" }).Count -gt 0
            $hasWarn  = ($hostResults | Where-Object { $_.Status -eq "WARN" }).Count -gt 0
            $borderStyle = if ($hasBlock) { "border-color:var(--color-block)" } elseif ($hasWarn) { "border-color:var(--color-warn)" } else { "" }
            $statusDot = if ($hasBlock) { '<span class="host-dot dot-block"></span>' } elseif ($hasWarn) { '<span class="host-dot dot-warn"></span>' } else { '<span class="host-dot dot-pass"></span>' }

            $hostCards += @"
      <div class="host-card" style="$borderStyle">
        <div class="hname">$statusDot $([System.Web.HttpUtility]::HtmlEncode($h.Name))</div>
        <div class="hrow"><span class="lbl">ESXi</span><span class="val">$($h.Version)</span></div>
        <div class="hrow"><span class="lbl">CPU</span><span class="val" title="$([System.Web.HttpUtility]::HtmlEncode($h.ProcessorType))">$cpuShort</span></div>
        <div class="hrow"><span class="lbl">Cores</span><span class="val">$coreInfo</span></div>
        <div class="hrow"><span class="lbl">RAM</span><span class="val">$($h.MemoryTotalGB) GB</span></div>
        <div class="hrow"><span class="lbl">NICs</span><span class="val">$nicCount</span></div>
      </div>
"@
        }
        $hostCards += "    </div>`n"
    }

    # Remediation roadmap
    $roadmapItems = $R.Results | Where-Object { $_.Status -in @("BLOCK","WARN") } |
        Sort-Object @{E={if($_.Status -eq "BLOCK"){0}else{1}}}, @{E={if($_.Severity -eq "Requirement"){0}else{1}}}, Category |
        Group-Object -Property { "$($_.CheckName)|$($_.Category)" }

    $roadmapHtml = ""
    $priority = 0
    foreach ($group in $roadmapItems) {
        $priority++
        $first = $group.Group[0]
        $numClass = if ($first.Status -eq "BLOCK") { "blocker" } else { "warning" }
        $sevTag = if ($first.Severity -eq "Requirement") { '<span class="tag tag-req">Requirement</span>' } else { '<span class="tag tag-bp">Best Practice</span>' }
        $allObjects = ($group.Group | ForEach-Object { $_.AffectedObjects }) | Select-Object -Unique
        $objCount = $allObjects.Count
        $objectSummary = if ($objCount -le 3) { ($allObjects -join ", ") } else {
            "$($allObjects[0..1] -join ', ') +$($objCount - 2) more"
        }

        $roadmapHtml += @"
  <div class="roadmap-card">
    <div class="roadmap-num $numClass">$priority</div>
    <div class="roadmap-body">
      <div class="action">$(ConvertTo-LinkedHtml $first.Remediation)</div>
      <div class="roadmap-detail">$([System.Web.HttpUtility]::HtmlEncode($objectSummary))</div>
      <div class="roadmap-tags">
        <span class="tag tag-cat">$($first.Category)</span>
        <span class="tag">$($first.CheckName)</span>
        $sevTag
        <span class="tag">$objCount object(s)</span>
      </div>
    </div>
  </div>
"@
    }

    # Nav links
    $navLinks = ""
    foreach ($cat in $categories) {
        $navLinks += "<a href=`"#$($cat.ToLower())`">$cat</a>`n"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VCF Readiness Report - $vcenter</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500;600;700&family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
/* Dark theme (default) */
:root,[data-theme="dark"]{--bg-primary:#0d1117;--bg-secondary:#161b22;--bg-tertiary:#21262d;--bg-card:#1c2128;--border:#30363d;--text-primary:#e6edf3;--text-secondary:#8b949e;--text-muted:#6e7681;--accent-blue:#58a6ff;--accent-purple:#bc8cff;--color-block:#f85149;--color-block-bg:rgba(248,81,73,.12);--color-warn:#d29922;--color-warn-bg:rgba(210,153,34,.12);--color-pass:#3fb950;--color-pass-bg:rgba(63,185,80,.12);--color-info:#58a6ff;--color-info-bg:rgba(88,166,255,.12);--font-mono:'JetBrains Mono',monospace;--font-sans:'Inter',-apple-system,sans-serif;--radius:8px;--radius-lg:12px}
/* Light theme */
[data-theme="light"]{--bg-primary:#ffffff;--bg-secondary:#f6f8fa;--bg-tertiary:#e8eaed;--bg-card:#f6f8fa;--border:#d0d7de;--text-primary:#1f2328;--text-secondary:#656d76;--text-muted:#8b949e;--accent-blue:#0969da;--accent-purple:#8250df;--color-block:#cf222e;--color-block-bg:rgba(207,34,46,.08);--color-warn:#9a6700;--color-warn-bg:rgba(154,103,0,.08);--color-pass:#1a7f37;--color-pass-bg:rgba(26,127,55,.08);--color-info:#0969da;--color-info-bg:rgba(9,105,218,.08)}
html{scroll-behavior:smooth}
body{font-family:var(--font-sans);background:var(--bg-primary);color:var(--text-primary);line-height:1.6;min-height:100vh;transition:background .3s,color .3s}
a{color:var(--accent-blue);text-decoration:none}a:hover{text-decoration:underline}
.container{max-width:1400px;margin:0 auto;padding:0 24px}
/* Header */
.header{background:var(--bg-secondary);border-bottom:1px solid var(--border);padding:32px 0}
.header-inner{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:16px}
.header h1{font-family:var(--font-mono);font-size:24px;font-weight:600}
.header h1 span{color:var(--accent-purple)}
.header-meta{font-size:13px;color:var(--text-secondary);font-family:var(--font-mono);text-align:right}
.header-meta div{margin-bottom:2px}
.header-actions{display:flex;gap:8px;margin-top:8px;justify-content:flex-end}
.hbtn{background:var(--bg-tertiary);color:var(--text-secondary);border:1px solid var(--border);border-radius:6px;padding:5px 12px;font-size:11px;font-family:var(--font-mono);cursor:pointer;transition:all .2s}
.hbtn:hover{border-color:var(--accent-blue);color:var(--text-primary)}
/* Nav */
.nav{background:var(--bg-secondary);border-bottom:1px solid var(--border);position:sticky;top:0;z-index:100}
.nav-inner{display:flex;gap:0;overflow-x:auto}
.nav a{padding:12px 20px;font-size:13px;font-weight:500;color:var(--text-secondary);border-bottom:2px solid transparent;white-space:nowrap;transition:all .2s}
.nav a:hover{color:var(--text-primary);text-decoration:none;background:var(--bg-tertiary)}
.nav a.active{color:var(--accent-blue);border-bottom-color:var(--accent-blue)}
section{padding:40px 0}section+section{border-top:1px solid var(--border)}
.section-title{font-family:var(--font-mono);font-size:18px;font-weight:600;margin-bottom:24px;display:flex;align-items:center;gap:10px}
.section-title .icon{font-size:20px;opacity:.7}
/* Executive Summary */
.exec-summary{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius-lg);padding:24px;margin-bottom:32px}
.exec-summary h3{font-family:var(--font-mono);font-size:15px;margin-bottom:12px;color:var(--accent-purple)}
.exec-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:20px}
.exec-col h4{font-size:13px;color:var(--text-secondary);margin-bottom:8px;text-transform:uppercase;letter-spacing:.5px}
.exec-col ul{list-style:none;font-size:13px}
.exec-col li{padding:3px 0;color:var(--text-primary)}
.exec-col li::before{content:'';display:inline-block;width:6px;height:6px;border-radius:50%;margin-right:8px;vertical-align:middle}
.exec-col li.li-block::before{background:var(--color-block)}.exec-col li.li-warn::before{background:var(--color-warn)}.exec-col li.li-pass::before{background:var(--color-pass)}
/* Score ring */
.score-section{display:flex;gap:40px;align-items:flex-start;flex-wrap:wrap}
.ring-container{flex-shrink:0;position:relative;width:220px;height:220px}
.ring-container svg{width:100%;height:100%;transform:rotate(-90deg)}
.ring-bg{fill:none;stroke:var(--bg-tertiary);stroke-width:12}
.ring-progress{fill:none;stroke-width:12;stroke-linecap:round;transition:stroke-dashoffset 1.5s ease}
.ring-label{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);text-align:center}
.ring-label .score{font-family:var(--font-mono);font-size:48px;font-weight:700;line-height:1;color:$ringColor}
.ring-label .of{font-size:14px;color:var(--text-muted)}
.ring-label .verdict{font-size:12px;font-weight:600;margin-top:4px;text-transform:uppercase;letter-spacing:1px;color:$ringColor}
.stat-cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px;flex:1;min-width:300px}
.stat-card{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius);padding:16px;text-align:center}
.stat-card .num{font-family:var(--font-mono);font-size:32px;font-weight:700;line-height:1.2}
.stat-card .lbl{font-size:12px;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.5px;margin-top:4px}
.stat-card.block .num{color:var(--color-block)}.stat-card.warn .num{color:var(--color-warn)}.stat-card.pass .num{color:var(--color-pass)}.stat-card.info .num{color:var(--color-info)}
.cat-scores{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin-top:24px}
.cat-bar-card{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius);padding:16px 20px}
.cat-bar-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}
.cat-bar-header .name{font-size:14px;font-weight:500}.cat-bar-header .val{font-family:var(--font-mono);font-size:14px;font-weight:600}
.cat-bar-track{height:6px;background:var(--bg-tertiary);border-radius:3px;overflow:hidden}
.cat-bar-fill{height:100%;border-radius:3px;transition:width 1s ease}
/* Chips */
.chip{display:inline-flex;align-items:center;gap:4px;padding:3px 10px;border-radius:12px;font-family:var(--font-mono);font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.5px;white-space:nowrap}
.chip-block{background:var(--color-block-bg);color:var(--color-block)}.chip-warn{background:var(--color-warn-bg);color:var(--color-warn)}.chip-pass{background:var(--color-pass-bg);color:var(--color-pass)}.chip-info{background:var(--color-info-bg);color:var(--color-info)}
.sev{font-size:9px;padding:1px 4px;border-radius:3px;font-weight:700;margin-right:2px}
.sev-req{background:rgba(255,255,255,.12)}.sev-bp{background:rgba(255,255,255,.06);opacity:.7}
[data-theme="light"] .sev-req{background:rgba(0,0,0,.08)}[data-theme="light"] .sev-bp{background:rgba(0,0,0,.04)}
.count-badge{opacity:.5;font-size:11px;font-weight:400;margin-left:4px}
/* Tables */
.tbl-wrap{overflow-x:auto;border:1px solid var(--border);border-radius:var(--radius-lg)}
table{width:100%;border-collapse:collapse;font-size:13px;table-layout:fixed}
thead{background:var(--bg-tertiary)}
th{padding:10px 14px;text-align:left;font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.5px;color:var(--text-secondary);white-space:nowrap}
td{padding:14px 14px;border-top:1px solid var(--border);vertical-align:top;word-wrap:break-word;overflow-wrap:break-word}
tr:hover td{background:rgba(88,166,255,.04)}
.td-check{font-weight:500}.td-desc{color:var(--text-secondary);font-size:12px;line-height:1.5}
.td-fix{color:var(--text-muted);font-size:12px;line-height:1.5}.td-obj{font-family:var(--font-mono);font-size:11px;color:var(--text-secondary);line-height:1.8}
.obj-tag{display:inline-block;background:var(--bg-tertiary);padding:2px 8px;border-radius:4px;margin:2px 3px 2px 0;word-break:break-all}
.obj-hidden{display:none}
.obj-toggle{display:inline-block;background:rgba(88,166,255,.1);color:var(--accent-blue);padding:2px 10px;border-radius:4px;margin:2px 3px;cursor:pointer;font-weight:600;transition:background .2s}
.obj-toggle:hover{background:rgba(88,166,255,.2)}
.obj-none{color:var(--text-muted)}
/* Filter buttons */
.filter-bar{display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap}
.fbtn{background:var(--bg-tertiary);color:var(--text-secondary);border:1px solid var(--border);border-radius:6px;padding:5px 14px;font-size:11px;font-family:var(--font-mono);cursor:pointer;transition:all .2s}
.fbtn:hover{border-color:var(--accent-blue);color:var(--text-primary)}
.fbtn.active{background:var(--accent-blue);color:#fff;border-color:var(--accent-blue)}
.fbtn-block.active{background:var(--color-block);border-color:var(--color-block)}
.fbtn-warn.active{background:var(--color-warn);border-color:var(--color-warn);color:#000}
.fbtn-pass.active{background:var(--color-pass);border-color:var(--color-pass);color:#000}
/* Pass toggle */
.pass-toggle{padding:10px 14px;font-size:12px;color:var(--accent-blue);cursor:pointer;border-top:1px solid var(--border);transition:background .2s;user-select:none}
.pass-toggle:hover{background:rgba(88,166,255,.05)}
.pass-arrow{display:inline-block;transition:transform .2s;font-size:10px;margin-right:6px}
.pass-toggle.open .pass-arrow{transform:rotate(90deg)}
/* Legend */
.legend{display:flex;gap:20px;margin-bottom:20px;font-size:12px;color:var(--text-secondary);flex-wrap:wrap;padding:12px 16px;background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius)}
.legend-item{display:flex;align-items:center;gap:6px}
/* Cluster grouping */
.cluster-header{display:flex;align-items:center;gap:10px;margin:20px 0 10px 0;padding-bottom:6px;border-bottom:1px solid var(--border)}
.cluster-header:first-child{margin-top:0}
.cluster-dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.cluster-name{font-family:var(--font-mono);font-size:15px;font-weight:600;color:var(--text-primary)}
.cluster-count{font-size:12px;color:var(--text-muted)}
/* Host cards */
.host-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:12px;margin-bottom:16px}
.host-card{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius);padding:14px 18px;display:flex;flex-direction:column;gap:6px;transition:border-color .2s}
.host-card:hover{border-color:var(--accent-blue)}
.host-card .hname{font-family:var(--font-mono);font-size:13px;font-weight:600;color:var(--accent-blue);display:flex;align-items:center;gap:8px}
.host-card .hrow{display:flex;justify-content:space-between;font-size:12px;padding:1px 0}
.host-card .hrow .lbl{color:var(--text-muted)}.host-card .hrow .val{font-family:var(--font-mono);color:var(--text-secondary);text-align:right;max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.host-dot{width:8px;height:8px;border-radius:50%;display:inline-block;flex-shrink:0}
.dot-block{background:var(--color-block)}.dot-warn{background:var(--color-warn)}.dot-pass{background:var(--color-pass)}
/* Roadmap */
.roadmap-card{background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius);padding:16px 20px;display:flex;align-items:flex-start;gap:16px;margin-bottom:8px;transition:border-color .2s}
.roadmap-card:hover{border-color:var(--accent-blue)}
.roadmap-num{flex-shrink:0;width:32px;height:32px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-family:var(--font-mono);font-size:13px;font-weight:700}
.roadmap-num.blocker{background:var(--color-block-bg);color:var(--color-block)}.roadmap-num.warning{background:var(--color-warn-bg);color:var(--color-warn)}
.roadmap-body{flex:1}.roadmap-body .action{font-size:14px;font-weight:500;margin-bottom:4px}
.roadmap-detail{font-size:12px;color:var(--text-secondary);margin-bottom:6px;font-family:var(--font-mono)}
.roadmap-tags{display:flex;gap:6px;flex-wrap:wrap}
.roadmap-tags .tag{font-size:11px;padding:2px 8px;border-radius:4px;background:var(--bg-tertiary);color:var(--text-secondary);font-family:var(--font-mono)}
.roadmap-tags .tag-cat{color:var(--accent-purple)}.roadmap-tags .tag-req{color:var(--color-block)}.roadmap-tags .tag-bp{color:var(--color-info)}
/* Footer */
.footer{border-top:1px solid var(--border);padding:24px 0;font-size:12px;color:var(--text-muted);text-align:center;font-family:var(--font-mono)}
.footer div+div{margin-top:4px}
/* Print / PDF */
@media print{
  body{background:#fff!important;color:#1a1a1a!important}
  .nav,.filter-bar,.pass-toggle,.hbtn,.obj-toggle{display:none!important}
  .row-pass{display:table-row!important}
  .obj-hidden{display:inline!important}
  .exec-summary{break-after:page}
  section{padding:20px 0}
  .host-card{break-inside:avoid}
  .roadmap-card{break-inside:avoid}
}
@media(max-width:768px){.score-section{flex-direction:column;align-items:center}.ring-container{width:180px;height:180px}.header-inner{flex-direction:column;text-align:center}.header-meta{text-align:center}table{font-size:11px}td{padding:8px 10px}}
</style>
</head>
<body>

<header class="header">
  <div class="container header-inner">
    <div>
      <h1><span>VCF</span> Readiness Report</h1>
      <div style="color:var(--text-secondary);font-size:13px;margin-top:4px;">vSphere to VCF $vcf Migration Assessment</div>
    </div>
    <div>
      <div class="header-meta">
        <div>$vcenter</div>
        <div>vCenter $vcVer</div>
        <div>$ts</div>
        <div style="color:var(--accent-purple);">Target: VCF $vcf / $storage</div>
      </div>
      <div class="header-actions">
        <button class="hbtn" onclick="toggleTheme()">Light / Dark</button>
        <button class="hbtn" onclick="window.print()">Save as PDF</button>
      </div>
    </div>
  </div>
</header>

<nav class="nav">
  <div class="container nav-inner">
    <a href="#overview" class="active">Overview</a>
    $navLinks
    <a href="#hosts">Host Inventory</a>
    <a href="#roadmap">Remediation</a>
  </div>
</nav>

<section id="overview">
<div class="container">
  <div class="section-title"><span class="icon">&#9881;</span> Overview</div>

  <!-- Executive Summary -->
  <div class="exec-summary">
    <h3>Executive Summary</h3>
    <div class="exec-grid">
      <div class="exec-col">
        <h4>Assessment Result</h4>
        <ul>
          <li class="li-$(if($score -ge 80){'pass'}elseif($score -ge 40){'warn'}else{'block'})"><strong>Score: $score/100</strong> - $verdict</li>
          <li>$($R.TotalChecks) checks evaluated across $($R.Hosts.Count) hosts</li>
          <li class="li-block">$($R.Blockers) blocker(s) must be resolved before migration</li>
          <li class="li-warn">$($R.Warnings) warning(s) should be addressed</li>
        </ul>
      </div>
      <div class="exec-col">
        <h4>Top Blockers</h4>
        <ul>
$execBlockerHtml
        </ul>
      </div>
      <div class="exec-col">
        <h4>Environment</h4>
        <ul>
          <li>vCenter: $vcenter ($vcVer)</li>
          <li>Target: VCF $vcf / $storage</li>
          <li>$($R.Hosts.Count) ESXi hosts scanned</li>
          <li>Assessment date: $ts</li>
        </ul>
      </div>
    </div>
  </div>

  <div class="legend">
    <div class="legend-item"><span class="sev sev-req" style="font-size:10px">REQ</span> VCF Requirement (hard gate)</div>
    <div class="legend-item"><span class="sev sev-bp" style="font-size:10px">BP</span> Best Practice (advisory)</div>
    <div class="legend-item"><span class="chip chip-block" style="font-size:9px;padding:1px 6px">BLOCK</span> Migration stopper</div>
    <div class="legend-item"><span class="chip chip-warn" style="font-size:9px;padding:1px 6px">WARN</span> Needs attention</div>
    <div class="legend-item"><span class="chip chip-pass" style="font-size:9px;padding:1px 6px">PASS</span> OK</div>
  </div>
  <div class="score-section">
    <div class="ring-container">
      <svg viewBox="0 0 200 200">
        <circle class="ring-bg" cx="100" cy="100" r="85"></circle>
        <circle class="ring-progress" id="scoreRing" cx="100" cy="100" r="85"
                stroke="$ringColor"
                stroke-dasharray="$circumference"
                stroke-dashoffset="$circumference"></circle>
      </svg>
      <div class="ring-label">
        <div class="score" id="scoreNum">0</div>
        <div class="of">/ 100</div>
        <div class="verdict" id="scoreVerdict">$verdict</div>
      </div>
    </div>
    <div class="stat-cards">
      <div class="stat-card"><div class="num">$($R.TotalChecks)</div><div class="lbl">Total Checks</div></div>
      <div class="stat-card block"><div class="num">$($R.Blockers)</div><div class="lbl">Blockers</div></div>
      <div class="stat-card warn"><div class="num">$($R.Warnings)</div><div class="lbl">Warnings</div></div>
      <div class="stat-card pass"><div class="num">$($R.Passed)</div><div class="lbl">Passed</div></div>
      <div class="stat-card info"><div class="num">$($R.Info)</div><div class="lbl">Info</div></div>
      <div class="stat-card" style="border-left:3px solid var(--accent-purple)"><div class="num" style="font-size:20px;color:var(--accent-purple)">$($R.Hosts.Count)</div><div class="lbl">Hosts Scanned</div></div>
    </div>
  </div>
  <div class="cat-scores">
$catScoresHtml
  </div>
</div>
</section>

$categorySections

<section id="hosts">
<div class="container">
  <div class="section-title"><span class="icon">&#128421;</span> Host Inventory</div>
$hostCards
</div>
</section>

<section id="roadmap">
<div class="container">
  <div class="section-title"><span class="icon">&#128736;</span> Remediation Roadmap</div>
  <p style="color:var(--text-secondary);font-size:13px;margin-bottom:20px;">Prioritized actions - requirements first, then best practices.</p>
$roadmapHtml
</div>
</section>

<footer class="footer">
  <div class="container">
    <div>vsphere-vcf-readiness v$ver</div>
    <div>$vcenter - $ts</div>
    <div style="margin-top:8px">
      <a href="https://github.com/canberkys/vsphere-vcf-readiness" style="color:var(--accent-blue)">github.com/canberkys/vsphere-vcf-readiness</a>
      &middot;
      <a href="https://canberkki.com" style="color:var(--accent-purple)">canberkki.com</a>
    </div>
  </div>
</footer>

<script>
(function(){
  // Score ring animation
  var SCORE=$score,CIRC=$circumference,ring=document.getElementById('scoreRing'),numEl=document.getElementById('scoreNum');
  if(ring){var off=CIRC-(SCORE/100)*CIRC;setTimeout(function(){ring.style.strokeDashoffset=off;var c=0,step=Math.max(1,Math.floor(SCORE/30));var t=setInterval(function(){c+=step;if(c>=SCORE){c=SCORE;clearInterval(t)}numEl.textContent=c},25)},300)}
  // Nav scroll tracking
  var sections=document.querySelectorAll('section[id]'),navLinks=document.querySelectorAll('.nav a');
  function updateNav(){var c='';sections.forEach(function(s){if(window.scrollY>=s.offsetTop-80)c=s.id});
  navLinks.forEach(function(l){l.classList.toggle('active',l.getAttribute('href')==='#'+c)});}
  window.addEventListener('scroll',updateNav,{passive:true});
})();

// Theme toggle
function toggleTheme(){
  var html=document.documentElement;
  html.dataset.theme=html.dataset.theme==='dark'?'light':'dark';
}

// Expand/collapse affected objects
function toggleExpand(id){
  var el=document.getElementById('exp-'+id);if(!el)return;
  var btn=el.nextElementSibling;
  if(el.style.display==='none'){el.style.display='inline';btn.textContent='collapse';btn.style.background='rgba(88,166,255,.15)'}
  else{el.style.display='none';var count=el.querySelectorAll('.obj-tag').length;btn.textContent='+'+count+' more';btn.style.background=''}
}

// Filter table rows
function filterTable(btn,catId,status){
  var tbl=document.getElementById('tbl-'+catId);if(!tbl)return;
  tbl.querySelectorAll('tbody tr').forEach(function(r){
    if(status==='ALL')r.style.display='';
    else if(status==='PASS')r.style.display=(r.dataset.status==='PASS'||r.dataset.status==='INFO')?'':'none';
    else r.style.display=r.dataset.status===status?'':'none';
  });
  btn.parentElement.querySelectorAll('.fbtn').forEach(function(b){b.classList.remove('active')});
  btn.classList.add('active');
  var toggle=tbl.parentElement.querySelector('.pass-toggle');
  if(toggle)toggle.style.display=status==='ALL'?'':'none';
}

// Toggle pass rows
function togglePass(el){
  var tbl=el.previousElementSibling;if(!tbl)return;
  var rows=tbl.querySelectorAll('.row-pass');
  var showing=rows[0]&&rows[0].style.display==='none';
  rows.forEach(function(r){r.style.display=showing?'':'none'});
  el.classList.toggle('open',showing);
  var m=el.textContent.match(/\d+/);var count=m?m[0]:'';
  el.innerHTML=showing
    ?'<span class="pass-arrow" style="transform:rotate(90deg)">&#9654;</span> Hide '+count+' passed/info check(s)'
    :'<span class="pass-arrow">&#9654;</span> Show '+count+' passed/info check(s)';
}
</script>
</body>
</html>
"@

    return $html
}
