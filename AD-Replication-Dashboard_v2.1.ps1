<#
.SYNOPSIS
    AD Replication Health Dashboard V2.1 with improved topology diagram

.DESCRIPTION
    Generates a live HTML dashboard for Active Directory replication health with:
      - KPI summary
      - Replication failures / warnings
      - Domain Controller summary
      - Full replication detail table
      - Site-to-site summary table
      - Live topology diagram with directional arrows
      - Click a DC to highlight only its paths
      - Diagram filters (All / Issues / Failed)
      - Auto-refreshing browser view + live loop mode

.NOTES
    Author  : core365.cloud
    Version : 2.1
    Requires: ActiveDirectory module, repadmin available
#>

[CmdletBinding()]
param(
    [int]$AutoRefreshSeconds  = 60,
    [int]$StaleThresholdHours = 2,
    [string]$OutputPath       = $null,
    [switch]$RunOnce
)

Import-Module ActiveDirectory -ErrorAction Stop

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "AD-Replication-Dashboard-v2.1.html"
}

function Convert-ToHtmlSafe {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return "" }
    $safe = [string]$Text
    $safe = $safe.Replace('&', '&amp;')
    $safe = $safe.Replace('<', '&lt;')
    $safe = $safe.Replace('>', '&gt;')
    $safe = $safe.Replace('"', '&quot;')
    return $safe
}

function Get-ShortDcName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    if ($Name -match '^([^\.]+)\..*$') { return $matches[1] }
    return $Name
}

function Resolve-PartnerName {
    param(
        [string]$PartnerRaw,
        [hashtable]$ShortToFqdnMap
    )

    if ([string]::IsNullOrWhiteSpace($PartnerRaw)) { return $PartnerRaw }

    $partnerName = $PartnerRaw
    if ($partnerName -match '^CN=NTDS Settings,CN=([^,]+),') {
        $partnerName = $matches[1]
    }

    if ($partnerName -notmatch '\.' -and $ShortToFqdnMap.ContainsKey($partnerName.ToUpper())) {
        return $ShortToFqdnMap[$partnerName.ToUpper()]
    }

    return $partnerName
}

function Get-LinkSeverity {
    param([string]$Status)
    switch ($Status) {
        'FAILED'  { return 3 }
        'STALE'   { return 2 }
        'Healthy' { return 1 }
        default   { return 0 }
    }
}

function Get-OverallStatusBadge {
    param([string]$Status)
    switch ($Status) {
        'Critical' { return '<span class="badge badge-red">Critical</span>' }
        'Warning'  { return '<span class="badge badge-amber">Warning</span>' }
        default    { return '<span class="badge badge-green">Healthy</span>' }
    }
}

function Get-LinkStatusBadge {
    param([string]$Status)
    switch ($Status) {
        'FAILED'  { return '<span class="badge badge-red">FAILED</span>' }
        'STALE'   { return '<span class="badge badge-amber">STALE</span>' }
        default   { return '<span class="badge badge-green">Healthy</span>' }
    }
}

function Get-CollectionData {
    param([int]$StaleHours)

    Write-Host "[*] Collecting domain controllers..." -ForegroundColor Cyan
    $dcs = Get-ADDomainController -Filter * | Sort-Object HostName

    $shortToFqdn = @{}
    foreach ($dc in $dcs) {
        $shortToFqdn[(Get-ShortDcName $dc.HostName).ToUpper()] = $dc.HostName
        $shortToFqdn[$dc.Name.ToUpper()] = $dc.HostName
    }

    $replData = [System.Collections.Generic.List[object]]::new()
    $failureData = [System.Collections.Generic.List[object]]::new()
    $summaryData = [System.Collections.Generic.List[object]]::new()

    $totalLinks = 0
    $healthyLinks = 0
    $failedLinks = 0
    $staleLinks = 0

    foreach ($dc in $dcs) {
        Write-Host ("  - Querying {0}..." -f $dc.HostName) -ForegroundColor DarkGray
        try {
            $partners = Get-ADReplicationPartnerMetadata -Target $dc.HostName -ErrorAction Stop
            foreach ($p in $partners) {
                $totalLinks++

                $lastRepl = $p.LastReplicationSuccess
                $lastAttempt = $p.LastReplicationAttempt
                $lastResult = $p.LastReplicationResult
                $partnerFqdn = Resolve-PartnerName -PartnerRaw $p.Partner -ShortToFqdnMap $shortToFqdn
                $partnerShort = Get-ShortDcName $partnerFqdn
                $sourceShort = Get-ShortDcName $dc.HostName

                $partition = [string]$p.Partition
                $partition = $partition -replace '^DC=', ''
                $partition = $partition -replace ',DC=', '.'

                $isFailure = ($lastResult -ne 0)
                $isStale = $false
                if ($lastRepl) {
                    $ageHours = (New-TimeSpan -Start $lastRepl -End (Get-Date)).TotalHours
                    if ($ageHours -gt $StaleHours) { $isStale = $true }
                }

                if ($isFailure) {
                    $status = 'FAILED'
                    $failedLinks++
                }
                elseif ($isStale) {
                    $status = 'STALE'
                    $staleLinks++
                }
                else {
                    $status = 'Healthy'
                    $healthyLinks++
                }

                $row = [PSCustomObject]@{
                    SourceDC         = $dc.HostName
                    SourceShort      = $sourceShort
                    SourceSite       = $dc.Site
                    PartnerDC        = $partnerFqdn
                    PartnerShort     = $partnerShort
                    PartnerSite      = $null
                    Partition        = $partition
                    LastSuccess      = if ($lastRepl) { $lastRepl.ToString('yyyy-MM-dd HH:mm:ss') } else { 'Never' }
                    LastAttempt      = if ($lastAttempt) { $lastAttempt.ToString('yyyy-MM-dd HH:mm:ss') } else { 'N/A' }
                    ResultCode       = [string]$lastResult
                    Status           = $status
                    ConsecutiveFails = [string]$p.ConsecutiveReplicationFailures
                }
                $replData.Add($row)
                if ($status -in @('FAILED','STALE')) { $failureData.Add($row) }
            }
        }
        catch {
            $totalLinks++
            $failedLinks++
            $row = [PSCustomObject]@{
                SourceDC         = $dc.HostName
                SourceShort      = (Get-ShortDcName $dc.HostName)
                SourceSite       = $dc.Site
                PartnerDC        = 'N/A'
                PartnerShort     = 'N/A'
                PartnerSite      = 'N/A'
                Partition        = 'N/A'
                LastSuccess      = 'N/A'
                LastAttempt      = 'N/A'
                ResultCode       = 'Unreachable'
                Status           = 'FAILED'
                ConsecutiveFails = 'N/A'
            }
            $replData.Add($row)
            $failureData.Add($row)
        }
    }

    $dcMap = @{}
    foreach ($dc in $dcs) { $dcMap[$dc.HostName] = $dc }

    foreach ($r in $replData) {
        if ($dcMap.ContainsKey($r.PartnerDC)) {
            $r.PartnerSite = $dcMap[$r.PartnerDC].Site
        }
        elseif (-not $r.PartnerSite) {
            $r.PartnerSite = 'Unknown'
        }
    }

    foreach ($dc in $dcs) {
        $dcLinks = @($replData | Where-Object { $_.SourceDC -eq $dc.HostName })
        $dcFailed = @($dcLinks | Where-Object { $_.Status -eq 'FAILED' }).Count
        $dcStale = @($dcLinks | Where-Object { $_.Status -eq 'STALE' }).Count
        $dcHealthy = @($dcLinks | Where-Object { $_.Status -eq 'Healthy' }).Count
        $dcTotal = $dcLinks.Count

        $overallStatus = if ($dcFailed -gt 0) { 'Critical' } elseif ($dcStale -gt 0) { 'Warning' } else { 'Healthy' }

        $summaryData.Add([PSCustomObject]@{
            DomainController = $dc.HostName
            ShortName        = (Get-ShortDcName $dc.HostName)
            Site             = $dc.Site
            TotalLinks       = $dcTotal
            Healthy          = $dcHealthy
            Stale            = $dcStale
            Failed           = $dcFailed
            OverallStatus    = $overallStatus
        })
    }

    Write-Host "[*] Running repadmin /replsummary..." -ForegroundColor Cyan
    $replSummaryRaw = (repadmin /replsummary 2>&1) -join "`r`n"

    $healthPct = if ($totalLinks -gt 0) { [Math]::Round(($healthyLinks / $totalLinks) * 100, 1) } else { 0 }

    return [PSCustomObject]@{
        DCs            = $dcs
        ReplData       = $replData
        FailureData    = $failureData
        SummaryData    = $summaryData
        TotalLinks     = $totalLinks
        HealthyLinks   = $healthyLinks
        FailedLinks    = $failedLinks
        StaleLinks     = $staleLinks
        HealthPct      = $healthPct
        ReplSummaryRaw = $replSummaryRaw
        GeneratedAt    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
}

function Build-TopologySvg {
    param(
        [array]$DCs,
        [array]$SummaryData,
        [array]$ReplData
    )

    if (-not $DCs -or $DCs.Count -eq 0) {
        return '<div style="padding:20px;color:#ff6b6b;">No domain controllers found.</div>'
    }

    $summaryMap = @{}
    foreach ($s in $SummaryData) { $summaryMap[$s.DomainController] = $s }

    $siteGroups = $DCs | Group-Object Site | Sort-Object Name

    $marginX = 30
    $marginY = 30
    $siteGapX = 34
    $siteGapY = 34
    $sitePadding = 20
    $siteHeaderHeight = 42
    $nodeWidth = 190
    $nodeHeight = 62
    $nodeGapX = 18
    $nodeGapY = 14
    $maxCanvasWidth = 1800

    $layouts = New-Object System.Collections.Generic.List[object]
    $rowWidths = @{}
    $rowHeights = @{}
    $currentRow = 0
    $currentX = $marginX

    foreach ($sg in $siteGroups) {
        $nodes = @($sg.Group | Sort-Object HostName)
        $dcCount = $nodes.Count
        if ($dcCount -le 2) { $nodeCols = 1 }
        elseif ($dcCount -le 4) { $nodeCols = 2 }
        else { $nodeCols = 3 }

        $nodeRows = [int][Math]::Ceiling($dcCount / [double]$nodeCols)
        $siteInnerWidth = ($nodeCols * $nodeWidth) + (($nodeCols - 1) * $nodeGapX)
        $siteWidth = $siteInnerWidth + ($sitePadding * 2)
        $siteHeight = $siteHeaderHeight + ($sitePadding * 2) + ($nodeRows * $nodeHeight) + (($nodeRows - 1) * $nodeGapY)

        if (($currentX + $siteWidth + $marginX) -gt $maxCanvasWidth -and $currentX -gt $marginX) {
            $currentRow++
            $currentX = $marginX
        }

        if (-not $rowWidths.ContainsKey($currentRow)) { $rowWidths[$currentRow] = 0 }
        if (-not $rowHeights.ContainsKey($currentRow)) { $rowHeights[$currentRow] = 0 }

        $layouts.Add([PSCustomObject]@{
            Row        = $currentRow
            SiteName   = if ([string]::IsNullOrWhiteSpace($sg.Name)) { 'Unknown Site' } else { $sg.Name }
            Nodes      = $nodes
            NodeCols   = $nodeCols
            NodeRows   = $nodeRows
            SiteWidth  = $siteWidth
            SiteHeight = $siteHeight
            X          = $currentX
        })

        $rowWidths[$currentRow] = $currentX + $siteWidth
        if ($siteHeight -gt $rowHeights[$currentRow]) { $rowHeights[$currentRow] = $siteHeight }
        $currentX += $siteWidth + $siteGapX
    }

    $rowY = @{}
    $y = $marginY
    $maxRow = if ($rowHeights.Keys.Count -gt 0) { ($rowHeights.Keys | Measure-Object -Maximum).Maximum } else { 0 }
    for ($r = 0; $r -le $maxRow; $r++) {
        $rowY[$r] = $y
        $y += $rowHeights[$r] + $siteGapY
    }

    $canvasWidth = $maxCanvasWidth
    $canvasHeight = $y + $marginY

    $siteRects = New-Object System.Collections.Generic.List[string]
    $nodeRects = New-Object System.Collections.Generic.List[string]
    $nodeCoords = @{}

    foreach ($layout in $layouts) {
        $siteX = [int]$layout.X
        $siteY = [int]$rowY[$layout.Row]
        $siteNameSafe = Convert-ToHtmlSafe $layout.SiteName

        $siteRects.Add(@"
<g class="site-group">
  <rect x="$siteX" y="$siteY" width="$($layout.SiteWidth)" height="$($layout.SiteHeight)" rx="18" ry="18" class="site-box"></rect>
  <text x="$($siteX + 18)" y="$($siteY + 28)" class="site-title">$siteNameSafe</text>
</g>
"@)

        for ($i = 0; $i -lt $layout.Nodes.Count; $i++) {
            $dc = $layout.Nodes[$i]
            $nCol = $i % $layout.NodeCols
            $nRow = [int][Math]::Floor($i / $layout.NodeCols)

            $nodeX = $siteX + $sitePadding + ($nCol * ($nodeWidth + $nodeGapX))
            $nodeY = $siteY + $siteHeaderHeight + $sitePadding + ($nRow * ($nodeHeight + $nodeGapY))
            $centerX = [Math]::Round($nodeX + ($nodeWidth / 2), 2)
            $centerY = [Math]::Round($nodeY + ($nodeHeight / 2), 2)

            $short = Get-ShortDcName $dc.HostName
            $shortSafe = Convert-ToHtmlSafe $short
            $fqdnSafe = Convert-ToHtmlSafe $dc.HostName
            $siteSafe = Convert-ToHtmlSafe $layout.SiteName
            $nodeStatus = if ($summaryMap.ContainsKey($dc.HostName)) { $summaryMap[$dc.HostName].OverallStatus } else { 'Healthy' }
            $nodeClass = switch ($nodeStatus) {
                'Critical' { 'node-critical' }
                'Warning'  { 'node-warning' }
                default    { 'node-healthy' }
            }
            $nodeCoords[$dc.HostName] = [PSCustomObject]@{
                X = $nodeX; Y = $nodeY; W = $nodeWidth; H = $nodeHeight; CX = $centerX; CY = $centerY; Site = $layout.SiteName; Short = $short
            }

            $nodeRects.Add(@"
<g class="dc-node $nodeClass" data-dc="$fqdnSafe" data-short="$shortSafe" data-site="$siteSafe" onclick="toggleDcFocus('$fqdnSafe')">
  <title>$fqdnSafe</title>
  <rect x="$nodeX" y="$nodeY" width="$nodeWidth" height="$nodeHeight" rx="14" ry="14" class="dc-rect"></rect>
  <text x="$($nodeX + 14)" y="$($nodeY + 25)" class="dc-name">$shortSafe</text>
  <text x="$($nodeX + 14)" y="$($nodeY + 46)" class="dc-sub">$siteSafe</text>
</g>
"@)
        }
    }

    $edgeLines = New-Object System.Collections.Generic.List[string]
    $edgeIndex = 0
    foreach ($r in $ReplData) {
        $src = [string]$r.SourceDC
        $dst = [string]$r.PartnerDC
        if ([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($dst)) { continue }
        if ($dst -eq 'N/A') { continue }
        if (-not $nodeCoords.ContainsKey($src)) { continue }
        if (-not $nodeCoords.ContainsKey($dst)) { continue }
        if ($src -eq $dst) { continue }

        $a = $nodeCoords[$src]
        $b = $nodeCoords[$dst]
        $status = [string]$r.Status
        $lineClass = switch ($status) {
            'FAILED' { 'edge edge-failed' }
            'STALE'  { 'edge edge-stale' }
            default  { 'edge edge-healthy' }
        }

        $dx = [double]($b.CX - $a.CX)
        $dy = [double]($b.CY - $a.CY)
        $dist = [Math]::Sqrt(($dx * $dx) + ($dy * $dy))
        if ($dist -lt 1) { $dist = 1 }
        $ux = $dx / $dist
        $uy = $dy / $dist
        $px = -1 * $uy
        $py = $ux
        $offset = 12

        $hasReverse = $false
        if ($ReplData | Where-Object { $_.SourceDC -eq $dst -and $_.PartnerDC -eq $src } | Select-Object -First 1) {
            $hasReverse = $true
        }

        $dirRank = 1
        if ($src -gt $dst) { $dirRank = -1 }
        $curveOffset = if ($hasReverse) { $offset * $dirRank } else { 0 }

        $startX = [Math]::Round($a.CX + ($ux * ($a.W / 2.4)), 2)
        $startY = [Math]::Round($a.CY + ($uy * ($a.H / 2.4)), 2)
        $endX = [Math]::Round($b.CX - ($ux * ($b.W / 2.4)), 2)
        $endY = [Math]::Round($b.CY - ($uy * ($b.H / 2.4)), 2)
        $midX = ($startX + $endX) / 2
        $midY = ($startY + $endY) / 2
        $ctrlX = [Math]::Round($midX + ($px * $curveOffset), 2)
        $ctrlY = [Math]::Round($midY + ($py * $curveOffset), 2)
        $tooltip = Convert-ToHtmlSafe ("{0} [{1}] -> {2} [{3}] | Partition: {4} | Result: {5}" -f $r.SourceShort, $r.SourceSite, $r.PartnerShort, $r.PartnerSite, $r.Partition, $r.ResultCode)
        $edgeId = "edge_$edgeIndex"
        $statusLabel = Convert-ToHtmlSafe $status
        $dataSrc = Convert-ToHtmlSafe $src
        $dataDst = Convert-ToHtmlSafe $dst

        $edgeLines.Add(@"
<g id="$edgeId" class="$lineClass" data-status="$status" data-source="$dataSrc" data-target="$dataDst" data-sitesource="$(Convert-ToHtmlSafe $r.SourceSite)" data-sitetarget="$(Convert-ToHtmlSafe $r.PartnerSite)">
  <title>$tooltip</title>
  <path d="M $startX $startY Q $ctrlX $ctrlY $endX $endY" marker-end="url(#arrow-$(($status).ToLower()))"></path>
  <text class="edge-direction-label"><textPath href="#$edgeId-path" startOffset="50%"></textPath></text>
</g>
<path id="$edgeId-path" d="M $startX $startY Q $ctrlX $ctrlY $endX $endY" style="display:none;"></path>
"@)
        $edgeIndex++
    }

    $controls = @"
<div class="diagram-toolbar">
  <div class="diagram-controls">
    <button class="filter-btn active" onclick="setDiagramFilter('all', this)">Show All</button>
    <button class="filter-btn" onclick="setDiagramFilter('issues', this)">Warnings + Failures</button>
    <button class="filter-btn" onclick="setDiagramFilter('failed', this)">Failures Only</button>
    <button class="filter-btn" onclick="clearDcFocus(this)">Clear DC Highlight</button>
  </div>
  <div id="dcFocusInfo" class="dc-focus-info">Click a DC to highlight only its replication paths.</div>
</div>
"@

    $legend = @"
<div class="diagram-legend">
  <span><i class="legend-line legend-green"></i> Healthy link</span>
  <span><i class="legend-line legend-amber"></i> Stale link</span>
  <span><i class="legend-line legend-red"></i> Failed link</span>
  <span><i class="legend-arrow">&#8594;</i> Arrow shows replication direction</span>
  <span><i class="legend-box legend-node-green"></i> Healthy DC</span>
  <span><i class="legend-box legend-node-amber"></i> Warning DC</span>
  <span><i class="legend-box legend-node-red"></i> Critical DC</span>
</div>
"@

    $svg = @"
$controls
$legend
<div class="diagram-wrap">
<svg id="topologySvg" xmlns="http://www.w3.org/2000/svg" width="$canvasWidth" height="$canvasHeight" viewBox="0 0 $canvasWidth $canvasHeight" preserveAspectRatio="xMinYMin meet">
  <defs>
    <filter id="softShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="#000000" flood-opacity="0.25"/>
    </filter>
<marker id="arrow-healthy" markerWidth="6" markerHeight="6" refX="5.5" refY="3" orient="auto" markerUnits="userSpaceOnUse">
  <path d="M 0 0 L 6 3 L 0 6 z" fill="#27ae60"></path>
</marker>
<marker id="arrow-stale" markerWidth="6" markerHeight="6" refX="5.5" refY="3" orient="auto" markerUnits="userSpaceOnUse">
  <path d="M 0 0 L 6 3 L 0 6 z" fill="#f39c12"></path>
</marker>
<marker id="arrow-failed" markerWidth="6" markerHeight="6" refX="5.5" refY="3" orient="auto" markerUnits="userSpaceOnUse">
  <path d="M 0 0 L 6 3 L 0 6 z" fill="#e74c3c"></path>
</marker>
  </defs>

  <g class="sites-layer">
    $($siteRects -join "`r`n")
  </g>

  <g class="edges-layer">
    $($edgeLines -join "`r`n")
  </g>

  <g class="nodes-layer">
    $($nodeRects -join "`r`n")
  </g>
</svg>
</div>
"@

    return $svg
}

function Build-SiteToSiteSummaryRows {
    param([array]$ReplData)

    $map = @{}
    foreach ($r in $ReplData) {
        $srcSite = if ([string]::IsNullOrWhiteSpace($r.SourceSite)) { 'Unknown' } else { $r.SourceSite }
        $dstSite = if ([string]::IsNullOrWhiteSpace($r.PartnerSite)) { 'Unknown' } else { $r.PartnerSite }
        $key = "$srcSite||$dstSite"
        if (-not $map.ContainsKey($key)) {
            $map[$key] = [PSCustomObject]@{
                SourceSite = $srcSite
                TargetSite = $dstSite
                LinkCount = 0
                WorstSeverity = 0
                WorstStatus = 'Healthy'
                Examples = New-Object System.Collections.Generic.List[string]
            }
        }

        $entry = $map[$key]
        $entry.LinkCount++
        $severity = Get-LinkSeverity $r.Status
        if ($severity -gt $entry.WorstSeverity) {
            $entry.WorstSeverity = $severity
            $entry.WorstStatus = $r.Status
        }
        if ($entry.Examples.Count -lt 3) {
            $entry.Examples.Add(("{0} -> {1}" -f $r.SourceShort, $r.PartnerShort))
        }
        $map[$key] = $entry
    }

    $rows = foreach ($entry in ($map.Values | Sort-Object SourceSite, TargetSite)) {
        $rowClass = switch ($entry.WorstStatus) {
            'FAILED' { 'row-critical' }
            'STALE'  { 'row-warning' }
            default  { '' }
        }
        $badge = Get-LinkStatusBadge $entry.WorstStatus
        $examples = Convert-ToHtmlSafe ($entry.Examples -join ', ')
        @"
<tr class="$rowClass">
  <td>$(Convert-ToHtmlSafe $entry.SourceSite)</td>
  <td>$(Convert-ToHtmlSafe $entry.TargetSite)</td>
  <td>$($entry.LinkCount)</td>
  <td>$badge</td>
  <td>$examples</td>
</tr>
"@
    }

    return ($rows -join "`r`n")
}

function Build-Html {
    param(
        [pscustomobject]$Data,
        [int]$AutoRefreshSeconds,
        [int]$StaleThresholdHours
    )

    Write-Host "[*] Building HTML dashboard..." -ForegroundColor Cyan

    $summaryRows = foreach ($s in $Data.SummaryData) {
        $rowClass = switch ($s.OverallStatus) {
            'Critical' { 'row-critical' }
            'Warning'  { 'row-warning' }
            default    { '' }
        }
        $badge = Get-OverallStatusBadge $s.OverallStatus
        @"
<tr class="$rowClass">
  <td>$(Convert-ToHtmlSafe $s.DomainController)</td>
  <td>$(Convert-ToHtmlSafe $s.Site)</td>
  <td>$($s.TotalLinks)</td>
  <td>$($s.Healthy)</td>
  <td>$($s.Stale)</td>
  <td>$($s.Failed)</td>
  <td>$badge</td>
</tr>
"@
    }

    $detailRows = foreach ($r in $Data.ReplData) {
        $rowClass = switch ($r.Status) {
            'FAILED' { 'row-critical' }
            'STALE'  { 'row-warning' }
            default  { '' }
        }
        $badge = Get-LinkStatusBadge $r.Status
        @"
<tr class="$rowClass">
  <td>$(Convert-ToHtmlSafe $r.SourceDC)</td>
  <td>$(Convert-ToHtmlSafe $r.PartnerDC)</td>
  <td>$(Convert-ToHtmlSafe $r.SourceSite)</td>
  <td>$(Convert-ToHtmlSafe $r.PartnerSite)</td>
  <td class="partition-cell">$(Convert-ToHtmlSafe $r.Partition)</td>
  <td>$(Convert-ToHtmlSafe $r.LastSuccess)</td>
  <td>$(Convert-ToHtmlSafe $r.LastAttempt)</td>
  <td>$(Convert-ToHtmlSafe $r.ResultCode)</td>
  <td>$(Convert-ToHtmlSafe $r.ConsecutiveFails)</td>
  <td>$badge</td>
</tr>
"@
    }

    if ($Data.FailureData.Count -gt 0) {
        $failureRows = foreach ($f in $Data.FailureData) {
            $badge = Get-LinkStatusBadge $f.Status
            @"
<tr class="row-critical-solid">
  <td>$(Convert-ToHtmlSafe $f.SourceDC)</td>
  <td>$(Convert-ToHtmlSafe $f.PartnerDC)</td>
  <td>$(Convert-ToHtmlSafe $f.SourceSite)</td>
  <td>$(Convert-ToHtmlSafe $f.PartnerSite)</td>
  <td class="partition-cell">$(Convert-ToHtmlSafe $f.Partition)</td>
  <td>$(Convert-ToHtmlSafe $f.LastSuccess)</td>
  <td>$(Convert-ToHtmlSafe $f.ResultCode)</td>
  <td>$(Convert-ToHtmlSafe $f.ConsecutiveFails)</td>
  <td>$badge</td>
</tr>
"@
        }
        $failureRows = ($failureRows -join "`r`n")
    }
    else {
        $failureRows = @"
<tr>
  <td colspan="9" style="text-align:center;color:#27ae60;font-weight:600;padding:30px;">
    &#9989; No replication failures detected - all links healthy!
  </td>
</tr>
"@
    }

    $topologySvg = Build-TopologySvg -DCs $Data.DCs -SummaryData $Data.SummaryData -ReplData $Data.ReplData
    $siteSummaryRows = Build-SiteToSiteSummaryRows -ReplData $Data.ReplData
    $repadminSafe = Convert-ToHtmlSafe $Data.ReplSummaryRaw

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta http-equiv="refresh" content="$AutoRefreshSeconds" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>AD Replication Health Dashboard V2.1 - core365.cloud</title>
<style>
:root {
    --bg:#0f1117; --card:#1a1d27; --border:#2a2d3a; --text:#e4e6eb; --muted:#8b8fa3;
    --accent:#4f8cff; --accent2:#6c5ce7; --green:#27ae60; --red:#e74c3c; --amber:#f39c12;
    --site-fill:#151925; --site-stroke:#2b3350;
}
* { box-sizing:border-box; margin:0; padding:0; }
body { font-family:'Segoe UI',system-ui,-apple-system,sans-serif; background:var(--bg); color:var(--text); padding:24px; min-height:100vh; }
.header { display:flex; justify-content:space-between; align-items:center; gap:16px; flex-wrap:wrap; margin-bottom:24px; }
.header h1 { font-size:1.75rem; font-weight:700; background:linear-gradient(135deg,var(--accent),var(--accent2)); -webkit-background-clip:text; -webkit-text-fill-color:transparent; }
.header .meta { font-size:0.82rem; color:var(--muted); text-align:right; line-height:1.55; }
.kpi-strip { display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:16px; margin-bottom:24px; }
.kpi { background:var(--card); border:1px solid var(--border); border-radius:14px; padding:20px 18px; text-align:center; box-shadow:0 10px 24px rgba(0,0,0,0.18); }
.kpi .value { font-size:2.2rem; font-weight:700; line-height:1; }
.kpi .label { font-size:0.84rem; color:var(--muted); margin-top:8px; }
.kpi.green .value { color:var(--green); } .kpi.red .value { color:var(--red); } .kpi.amber .value { color:var(--amber); } .kpi.blue .value { color:var(--accent); }
.section { background:var(--card); border:1px solid var(--border); border-radius:16px; padding:22px; margin-bottom:24px; box-shadow:0 12px 28px rgba(0,0,0,0.18); }
.section h2 { font-size:1.12rem; font-weight:600; margin-bottom:16px; color:#ffffff; }
.section-sub { font-size:0.88rem; color:var(--muted); margin-bottom:14px; }
.search-box { width:100%; padding:11px 14px; border-radius:10px; border:1px solid var(--border); background:#0d1017; color:var(--text); font-size:0.92rem; margin-bottom:14px; outline:none; }
.search-box:focus { border-color:var(--accent); box-shadow:0 0 0 3px rgba(79,140,255,0.15); }
.table-wrap { overflow:auto; border-radius:12px; }
table { width:100%; border-collapse:collapse; font-size:0.85rem; }
th { text-align:left; padding:11px 12px; background:#0d1017; color:var(--muted); font-weight:600; font-size:0.78rem; text-transform:uppercase; letter-spacing:0.45px; border-bottom:2px solid var(--border); position:sticky; top:0; cursor:pointer; white-space:nowrap; }
th:hover { color:var(--accent); }
td { padding:10px 12px; border-bottom:1px solid var(--border); max-width:320px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
tr:hover { background:rgba(79,140,255,0.06); }
.partition-cell { max-width:190px; }
.row-critical { background:rgba(231,76,60,0.08); } .row-critical td { color:#ff8484; }
.row-critical-solid { background:rgba(231,76,60,0.12); } .row-critical-solid td { color:#ff8484; font-weight:500; }
.row-warning { background:rgba(243,156,18,0.08); } .row-warning td { color:#ffc266; }
.badge { display:inline-block; padding:3px 10px; border-radius:999px; font-size:0.75rem; font-weight:700; letter-spacing:0.2px; }
.badge-green { background:rgba(39,174,96,0.15); color:var(--green); }
.badge-red { background:rgba(231,76,60,0.18); color:var(--red); }
.badge-amber { background:rgba(243,156,18,0.15); color:var(--amber); }
.repadmin-pre { background:#0d1017; border:1px solid var(--border); border-radius:12px; padding:16px; font-size:0.8rem; line-height:1.5; font-family:'Cascadia Code','Consolas','Courier New',monospace; overflow-x:auto; max-height:420px; overflow-y:auto; color:#c7cce0; white-space:pre-wrap; }
.footer { text-align:center; font-size:0.8rem; color:var(--muted); padding:12px 8px; }
.diagram-toolbar { display:flex; justify-content:space-between; gap:12px; flex-wrap:wrap; align-items:center; margin-bottom:12px; }
.diagram-controls { display:flex; gap:10px; flex-wrap:wrap; }
.filter-btn { border:1px solid var(--border); background:#121725; color:var(--text); padding:8px 12px; border-radius:10px; cursor:pointer; font-size:0.84rem; transition:all 0.2s ease; }
.filter-btn:hover { border-color:var(--accent); color:#ffffff; }
.filter-btn.active { background:rgba(79,140,255,0.15); border-color:var(--accent); color:#ffffff; }
.dc-focus-info { font-size:0.84rem; color:var(--muted); }
.diagram-legend { display:flex; flex-wrap:wrap; gap:14px 22px; margin-bottom:14px; color:var(--muted); font-size:0.82rem; }
.diagram-legend span { display:inline-flex; align-items:center; gap:8px; }
.legend-line { display:inline-block; width:22px; height:0; border-top:3px solid; }
.legend-green { border-color:var(--green); } .legend-amber { border-color:var(--amber); } .legend-red { border-color:var(--red); }
.legend-box { display:inline-block; width:16px; height:16px; border-radius:4px; border:2px solid; background:rgba(255,255,255,0.06); }
.legend-node-green { border-color:var(--green); } .legend-node-amber { border-color:var(--amber); } .legend-node-red { border-color:var(--red); }
.legend-arrow { font-size:1rem; color:#c6cbe1; }
.diagram-wrap { overflow:auto; border:1px solid var(--border); border-radius:14px; background:linear-gradient(180deg,#0d1017 0%,#111522 100%); padding:14px; }
#topologySvg { min-width:100%; height:auto; }
.site-box { fill:var(--site-fill); stroke:var(--site-stroke); stroke-width:1.5; filter:url(#softShadow); }
.site-title { fill:#ffffff; font-size:14px; font-weight:700; }
.dc-node { cursor:pointer; transition:opacity 0.2s ease; }
.dc-rect { fill:#151a27; stroke-width:2.2; filter:url(#softShadow); }
.dc-node.node-healthy .dc-rect { stroke:var(--green); }
.dc-node.node-warning .dc-rect { stroke:var(--amber); }
.dc-node.node-critical .dc-rect { stroke:var(--red); }
.dc-node.is-focused .dc-rect { stroke:#79a8ff; stroke-width:3.2; }
.dc-name { fill:#ffffff; font-size:12px; font-weight:700; }
.dc-sub { fill:#9ca5c0; font-size:10px; }
.edge path { fill:none; stroke-width:3; opacity:0.92; }
.edge-healthy path { stroke:var(--green); }
.edge-stale path { stroke:var(--amber); }
.edge-failed path { stroke:var(--red); }
.edge.dimmed path, .dc-node.dimmed { opacity:0.12; }
.edge.focused path { stroke-width:4.8; opacity:1; }
.edge-failed.focused path { filter:drop-shadow(0 0 5px rgba(231,76,60,0.6)); }
.edge-stale.focused path { filter:drop-shadow(0 0 5px rgba(243,156,18,0.5)); }
.edge-healthy.focused path { filter:drop-shadow(0 0 4px rgba(39,174,96,0.45)); }
@keyframes pulse-red { 0%,100% { box-shadow:0 0 0 0 rgba(231,76,60,0.35); } 50% { box-shadow:0 0 0 9px rgba(231,76,60,0); } }
.kpi.red { animation:pulse-red 2s infinite; }
@media (max-width:900px) { body { padding:16px; } .section { padding:18px; } .header h1 { font-size:1.35rem; } .diagram-toolbar { align-items:flex-start; } }
</style>
</head>
<body>
<div class="header">
  <h1>&#128260; AD Replication Health Dashboard V2.1</h1>
  <div class="meta">
    <div>Generated: <strong>$($Data.GeneratedAt)</strong></div>
    <div>Auto-refresh: <strong>every $AutoRefreshSeconds seconds</strong></div>
    <div>Stale threshold: <strong>$StaleThresholdHours hours</strong></div>
  </div>
</div>

<div class="kpi-strip">
  <div class="kpi blue"><div class="value">$($Data.DCs.Count)</div><div class="label">Domain Controllers</div></div>
  <div class="kpi blue"><div class="value">$($Data.TotalLinks)</div><div class="label">Directional Replication Links</div></div>
  <div class="kpi green"><div class="value">$($Data.HealthyLinks)</div><div class="label">Healthy</div></div>
  <div class="kpi amber"><div class="value">$($Data.StaleLinks)</div><div class="label">Stale (&gt; $StaleThresholdHours h)</div></div>
  <div class="kpi $(if ($Data.FailedLinks -gt 0) { 'red' } else { 'green' })"><div class="value">$($Data.FailedLinks)</div><div class="label">Failed</div></div>
  <div class="kpi $(if ($Data.HealthPct -ge 90) { 'green' } elseif ($Data.HealthPct -ge 70) { 'amber' } else { 'red' })"><div class="value">$($Data.HealthPct)%</div><div class="label">Health Score</div></div>
</div>

<div class="section">
  <h2>&#128506; Live Replication Topology Diagram</h2>
  <div class="section-sub">Version 2.1 fixes the layout issue, shows arrow direction on links, and lets you click a DC to isolate only its paths.</div>
  $topologySvg
</div>

<div class="section">
  <h2>&#8646; Site-to-Site Summary View</h2>
  <div class="section-sub">Directional view of replication between AD sites. Worst status wins for each site pair.</div>
  <div class="table-wrap">
    <table>
      <thead>
        <tr>
          <th>Source Site</th>
          <th>Target Site</th>
          <th>Directional Links</th>
          <th>Worst Status</th>
          <th>Example DC Paths</th>
        </tr>
      </thead>
      <tbody>
        $siteSummaryRows
      </tbody>
    </table>
  </div>
</div>

<div class="section" style="border-left:4px solid var(--red);">
  <h2>&#128680; Replication Failures &amp; Warnings</h2>
  <div class="table-wrap">
    <table>
      <thead>
        <tr>
          <th>Source DC</th>
          <th>Partner DC</th>
          <th>Source Site</th>
          <th>Target Site</th>
          <th>Partition</th>
          <th>Last Success</th>
          <th>Result Code</th>
          <th>Consecutive Fails</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        $failureRows
      </tbody>
    </table>
  </div>
</div>

<div class="section">
  <h2>&#128421;&#65039; Domain Controller Summary</h2>
  <div class="table-wrap">
    <table>
      <thead>
        <tr>
          <th>Domain Controller</th>
          <th>Site</th>
          <th>Total Links</th>
          <th>Healthy</th>
          <th>Stale</th>
          <th>Failed</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        $($summaryRows -join "`r`n")
      </tbody>
    </table>
  </div>
</div>

<div class="section">
  <h2>&#128203; All Replication Links - Detail</h2>
  <input type="text" class="search-box" id="searchDetail" placeholder="&#128269; Filter by DC name, partner, site, partition, or status..." onkeyup="filterTable('detailTable','searchDetail')" />
  <div class="table-wrap">
    <table id="detailTable">
      <thead>
        <tr>
          <th onclick="sortTable('detailTable',0)">Source DC &#8597;</th>
          <th onclick="sortTable('detailTable',1)">Partner DC &#8597;</th>
          <th onclick="sortTable('detailTable',2)">Source Site &#8597;</th>
          <th onclick="sortTable('detailTable',3)">Target Site &#8597;</th>
          <th onclick="sortTable('detailTable',4)">Partition &#8597;</th>
          <th onclick="sortTable('detailTable',5)">Last Success &#8597;</th>
          <th onclick="sortTable('detailTable',6)">Last Attempt &#8597;</th>
          <th onclick="sortTable('detailTable',7)">Result Code &#8597;</th>
          <th onclick="sortTable('detailTable',8)">Consecutive Fails &#8597;</th>
          <th onclick="sortTable('detailTable',9)">Status &#8597;</th>
        </tr>
      </thead>
      <tbody>
        $($detailRows -join "`r`n")
      </tbody>
    </table>
  </div>
</div>

<div class="section">
  <h2>&#129534; repadmin /replsummary (Raw)</h2>
  <pre class="repadmin-pre">$repadminSafe</pre>
</div>

<div class="footer">AD Replication Health Dashboard V2.1 | core365.cloud | Auto-refresh every $AutoRefreshSeconds seconds</div>

<script>
function filterTable(tableId, inputId) {
    const input = document.getElementById(inputId).value.toUpperCase();
    const rows = document.getElementById(tableId).tBodies[0].rows;
    for (let r = 0; r < rows.length; r++) {
        let match = false;
        for (let c = 0; c < rows[r].cells.length; c++) {
            if (rows[r].cells[c].textContent.toUpperCase().includes(input)) { match = true; break; }
        }
        rows[r].style.display = match ? '' : 'none';
    }
}

let sortDir = {};
function sortTable(tableId, col) {
    const table = document.getElementById(tableId);
    const body = table.tBodies[0];
    const rows = Array.from(body.rows);
    const key = tableId + '_' + col;
    sortDir[key] = !sortDir[key];
    rows.sort((a, b) => {
        let x = a.cells[col].textContent.trim();
        let y = b.cells[col].textContent.trim();
        const nx = Number(x), ny = Number(y);
        if (!isNaN(nx) && !isNaN(ny) && x !== '' && y !== '') { return sortDir[key] ? nx - ny : ny - nx; }
        return sortDir[key] ? x.localeCompare(y) : y.localeCompare(x);
    });
    rows.forEach(r => body.appendChild(r));
}

let currentDiagramFilter = 'all';
let focusedDc = null;

function setDiagramFilter(mode, btn) {
    currentDiagramFilter = mode;
    document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
    if (btn) btn.classList.add('active');
    applyDiagramState();
}

function toggleDcFocus(dcFqdn) {
    focusedDc = (focusedDc === dcFqdn) ? null : dcFqdn;
    applyDiagramState();
}

function clearDcFocus(btn) {
    focusedDc = null;
    applyDiagramState();
}

function applyDiagramState() {
    const edges = document.querySelectorAll('#topologySvg .edge');
    const nodes = document.querySelectorAll('#topologySvg .dc-node');
    const info = document.getElementById('dcFocusInfo');

    edges.forEach(edge => {
        const status = edge.getAttribute('data-status');
        let visibleByFilter = true;
        if (currentDiagramFilter === 'issues') visibleByFilter = (status === 'FAILED' || status === 'STALE');
        if (currentDiagramFilter === 'failed') visibleByFilter = (status === 'FAILED');

        const src = edge.getAttribute('data-source');
        const dst = edge.getAttribute('data-target');
        const related = !focusedDc || src === focusedDc || dst === focusedDc;

        edge.style.display = visibleByFilter ? '' : 'none';
        edge.classList.toggle('dimmed', visibleByFilter && focusedDc && !related);
        edge.classList.toggle('focused', visibleByFilter && related && !!focusedDc);
    });

    nodes.forEach(node => {
        const dc = node.getAttribute('data-dc');
        const related = !focusedDc || dc === focusedDc || Array.from(edges).some(edge => {
            if (edge.style.display === 'none') return false;
            const src = edge.getAttribute('data-source');
            const dst = edge.getAttribute('data-target');
            return src === dc || dst === dc;
        });
        node.classList.toggle('dimmed', !!focusedDc && !related);
        node.classList.toggle('is-focused', focusedDc === dc);
    });

    if (!focusedDc) {
        info.textContent = 'Click a DC to highlight only its replication paths.';
    } else {
        info.textContent = 'Showing only replication paths for: ' + focusedDc;
    }
}

applyDiagramState();
</script>
</body>
</html>
"@

    return $html
}

function Write-Dashboard {
    param(
        [int]$StaleThresholdHours,
        [int]$AutoRefreshSeconds,
        [string]$OutputPath
    )

    $data = Get-CollectionData -StaleHours $StaleThresholdHours
    $html = Build-Html -Data $data -AutoRefreshSeconds $AutoRefreshSeconds -StaleThresholdHours $StaleThresholdHours
    $html | Out-File -FilePath $OutputPath -Encoding UTF8 -Force

    Write-Host ''
    Write-Host ("[+] Dashboard saved to: {0}" -f $OutputPath) -ForegroundColor Green
    Write-Host ("[+] Status: {0} healthy / {1} stale / {2} failed" -f $data.HealthyLinks, $data.StaleLinks, $data.FailedLinks) -ForegroundColor Cyan
    Write-Host ''

    return $data
}

$data = Write-Dashboard -StaleThresholdHours $StaleThresholdHours -AutoRefreshSeconds $AutoRefreshSeconds -OutputPath $OutputPath
Start-Process $OutputPath

if (-not $RunOnce) {
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host (" Live mode enabled. Dashboard will update every {0} seconds." -f $AutoRefreshSeconds) -ForegroundColor Yellow
    Write-Host " Keep this PowerShell window open. Press Ctrl+C to stop." -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        Start-Sleep -Seconds $AutoRefreshSeconds
        Write-Host ("[{0}] Refreshing replication data..." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Cyan
        try {
            $data = Write-Dashboard -StaleThresholdHours $StaleThresholdHours -AutoRefreshSeconds $AutoRefreshSeconds -OutputPath $OutputPath
            Write-Host ("[{0}] Dashboard refreshed successfully." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Green
        }
        catch {
            Write-Host ("[{0}] ERROR: {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) -ForegroundColor Red
        }
    }
}
