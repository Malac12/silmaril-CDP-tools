param(
  [Parameter(Mandatory = $true)]
  [string]$InputFile,
  [string]$OutputDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PercentileValue {
  param(
    [double[]]$Values,
    [double]$Percentile
  )

  if (-not $Values -or $Values.Count -lt 1) {
    return $null
  }

  $sorted = @($Values | Sort-Object)
  if ($sorted.Count -eq 1) {
    return [Math]::Round([double]$sorted[0], 3)
  }

  $rank = ($Percentile / 100.0) * ($sorted.Count - 1)
  $lowerIndex = [Math]::Floor($rank)
  $upperIndex = [Math]::Ceiling($rank)
  if ($lowerIndex -eq $upperIndex) {
    return [Math]::Round([double]$sorted[$lowerIndex], 3)
  }

  $fraction = $rank - $lowerIndex
  $interpolated = ([double]$sorted[$lowerIndex]) + (([double]$sorted[$upperIndex] - [double]$sorted[$lowerIndex]) * $fraction)
  return [Math]::Round($interpolated, 3)
}

function Get-StatusSeverity {
  param([string]$Status)

  switch ($Status) {
    'clean_success' { return 0 }
    'success_with_escalation' { return 2 }
    'partial' { return 4 }
    'fail' { return 6 }
    default { return 1 }
  }
}

function Join-StringList {
  param([object[]]$Values)

  $items = @($Values | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  if ($items.Count -lt 1) {
    return ''
  }

  return ($items -join ', ')
}

function Get-MedianValue {
  param([double[]]$Values)
  return (Get-PercentileValue -Values $Values -Percentile 50)
}

function Get-PreferredTaskRows {
  param([object[]]$TaskRows)

  $preferred = New-Object System.Collections.Generic.List[object]
  $grouped = $TaskRows | Group-Object taskId, tool
  foreach ($group in @($grouped)) {
    $items = @($group.Group)
    $warm = @($items | Where-Object { [string]$_.mode -eq 'warm' })
    if ($warm.Count -gt 0) {
      $preferred.Add($warm[0])
      continue
    }

    $preferred.Add($items[0])
  }

  return @($preferred.ToArray())
}

function New-AggregatedRow {
  param([object[]]$Items)

  $successItems = @($Items | Where-Object { $_.ok })
  $cleanSuccessItems = @($Items | Where-Object { [string]$_.status -eq 'clean_success' })
  $partialItems = @($Items | Where-Object { [string]$_.status -eq 'partial' })
  $failItems = @($Items | Where-Object { [string]$_.status -eq 'fail' })
  $wallValues = @($successItems | ForEach-Object { [double]$_.wallMs })
  $commandValues = @($Items | ForEach-Object { [double]$_.commandCount })
  $refreshValues = @($Items | ForEach-Object { [double]$_.contextRefreshCount })
  $escalationValues = @($Items | ForEach-Object { [double]$_.maxEscalationDepth })
  $startupValues = @($successItems | Where-Object { $null -ne $_.startupMs } | ForEach-Object { [double]$_.startupMs })
  $surfaceValues = Join-StringList -Values @($Items | ForEach-Object { @($_.distinctSurfaces) })
  $errorValues = Join-StringList -Values @($Items | ForEach-Object { [string]$_.error })

  return [pscustomobject]@{
    runs                    = [int]$Items.Count
    successCount            = [int]$successItems.Count
    cleanSuccessCount       = [int]$cleanSuccessItems.Count
    partialCount            = [int]$partialItems.Count
    failCount               = [int]$failItems.Count
    successRate             = [Math]::Round((([double]$successItems.Count / [Math]::Max($Items.Count, 1)) * 100.0), 2)
    cleanSuccessRate        = [Math]::Round((([double]$cleanSuccessItems.Count / [Math]::Max($Items.Count, 1)) * 100.0), 2)
    partialRate             = [Math]::Round((([double]$partialItems.Count / [Math]::Max($Items.Count, 1)) * 100.0), 2)
    failRate                = [Math]::Round((([double]$failItems.Count / [Math]::Max($Items.Count, 1)) * 100.0), 2)
    medianWallMs            = Get-MedianValue -Values $wallValues
    p95WallMs               = Get-PercentileValue -Values $wallValues -Percentile 95
    medianCommandCount      = Get-MedianValue -Values $commandValues
    medianContextRefreshes  = Get-MedianValue -Values $refreshValues
    medianEscalationDepth   = Get-MedianValue -Values $escalationValues
    medianStartupMs         = Get-MedianValue -Values $startupValues
    surfaces                = $surfaceValues
    errors                  = $errorValues
  }
}

function Get-InferredIssueCategory {
  param([object]$Comparison)

  $silmarilStatus = [string]$Comparison.silmarilStatus
  $playwrightStatus = [string]$Comparison.playwrightStatus
  $silmarilError = [string]$Comparison.silmarilErrors

  if (($silmarilStatus -in @('fail', 'partial')) -and ($playwrightStatus -in @('fail', 'partial'))) {
    return 'website_specific_instability'
  }
  if ($silmarilError -match 'Unsupported benchmark step type') {
    return 'missing_capability'
  }
  if ($silmarilError -match 'Unknown target alias|No snapshot is available|Unknown benchmark task id') {
    return 'operator_error'
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Comparison.docsVsRealityNote) -and $silmarilStatus -eq 'success_with_escalation') {
    return 'documentation_gap'
  }
  if ($silmarilStatus -ne 'clean_success') {
    return 'weak_ergonomics'
  }

  return 'none'
}

if (-not (Test-Path -LiteralPath $InputFile)) {
  throw "Missing benchmark result file: $InputFile"
}

$payload = Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json
$runs = @($payload.runs)
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Split-Path -Parent $InputFile
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$taskRows = New-Object System.Collections.Generic.List[object]
$taskGroups = $runs | Group-Object group, taskId, tool, mode
foreach ($group in @($taskGroups)) {
  $items = @($group.Group)
  $first = $items[0]
  $aggregated = New-AggregatedRow -Items $items
  $taskRows.Add([pscustomobject]@{
    group                      = [string]$first.group
    taskId                     = [string]$first.taskId
    title                      = [string]$first.title
    site                       = [string]$first.site
    tool                       = [string]$first.tool
    mode                       = [string]$first.mode
    docsVsRealityNote          = [string]$first.docsVsRealityNote
    silmarilStrengthHypothesis = [string]$first.silmarilStrengthHypothesis
    silmarilImprovementBuckets = @($first.silmarilImprovementBuckets)
    commandBudget              = [int]$first.commandBudget
    timeBudgetMs               = [int]$first.timeBudgetMs
    runs                       = $aggregated.runs
    successCount               = $aggregated.successCount
    cleanSuccessCount          = $aggregated.cleanSuccessCount
    partialCount               = $aggregated.partialCount
    failCount                  = $aggregated.failCount
    successRate                = $aggregated.successRate
    cleanSuccessRate           = $aggregated.cleanSuccessRate
    partialRate                = $aggregated.partialRate
    failRate                   = $aggregated.failRate
    medianWallMs               = $aggregated.medianWallMs
    p95WallMs                  = $aggregated.p95WallMs
    medianCommandCount         = $aggregated.medianCommandCount
    medianContextRefreshes     = $aggregated.medianContextRefreshes
    medianEscalationDepth      = $aggregated.medianEscalationDepth
    medianStartupMs            = $aggregated.medianStartupMs
    surfaces                   = $aggregated.surfaces
    errors                     = $aggregated.errors
    preferredStatus            = if ($aggregated.failCount -eq $aggregated.runs) { 'fail' } elseif ($aggregated.successCount -eq $aggregated.runs -and $aggregated.cleanSuccessCount -eq $aggregated.runs) { 'clean_success' } elseif ($aggregated.successCount -eq $aggregated.runs) { 'success_with_escalation' } elseif ($aggregated.partialCount -gt 0) { 'partial' } else { 'fail' }
  })
}

$groupRows = New-Object System.Collections.Generic.List[object]
$byGroup = $runs | Group-Object group, tool, mode
foreach ($group in @($byGroup)) {
  $items = @($group.Group)
  $first = $items[0]
  $aggregated = New-AggregatedRow -Items $items
  $groupRows.Add([pscustomobject]@{
    group                   = [string]$first.group
    tool                    = [string]$first.tool
    mode                    = [string]$first.mode
    runs                    = $aggregated.runs
    successRate             = $aggregated.successRate
    cleanSuccessRate        = $aggregated.cleanSuccessRate
    partialRate             = $aggregated.partialRate
    failRate                = $aggregated.failRate
    medianWallMs            = $aggregated.medianWallMs
    medianCommandCount      = $aggregated.medianCommandCount
    medianContextRefreshes  = $aggregated.medianContextRefreshes
    medianEscalationDepth   = $aggregated.medianEscalationDepth
    surfaces                = $aggregated.surfaces
  })
}

$preferredTaskRows = Get-PreferredTaskRows -TaskRows @($taskRows.ToArray())
$comparisonRows = New-Object System.Collections.Generic.List[object]
$preferredByTask = $preferredTaskRows | Group-Object taskId
foreach ($group in @($preferredByTask)) {
  $items = @($group.Group)
  $silmaril = @($items | Where-Object { [string]$_.tool -eq 'silmaril' })[0]
  $playwright = @($items | Where-Object { [string]$_.tool -eq 'playwright' })[0]
  if ($null -eq $silmaril -or $null -eq $playwright) {
    continue
  }

  $comparisonRows.Add([pscustomobject]@{
    taskId                     = [string]$silmaril.taskId
    group                      = [string]$silmaril.group
    title                      = [string]$silmaril.title
    site                       = [string]$silmaril.site
    docsVsRealityNote          = [string]$silmaril.docsVsRealityNote
    silmarilStrengthHypothesis = [string]$silmaril.silmarilStrengthHypothesis
    silmarilImprovementBuckets = @($silmaril.silmarilImprovementBuckets)
    silmarilStatus             = [string]$silmaril.preferredStatus
    playwrightStatus           = [string]$playwright.preferredStatus
    silmarilSuccessRate        = [double]$silmaril.successRate
    playwrightSuccessRate      = [double]$playwright.successRate
    silmarilMedianWallMs       = $silmaril.medianWallMs
    playwrightMedianWallMs     = $playwright.medianWallMs
    silmarilMedianCommands     = $silmaril.medianCommandCount
    playwrightMedianCommands   = $playwright.medianCommandCount
    silmarilMedianRefreshes    = $silmaril.medianContextRefreshes
    playwrightMedianRefreshes  = $playwright.medianContextRefreshes
    silmarilMedianEscalation   = $silmaril.medianEscalationDepth
    playwrightMedianEscalation = $playwright.medianEscalationDepth
    silmarilSurfaces           = [string]$silmaril.surfaces
    playwrightSurfaces         = [string]$playwright.surfaces
    silmarilErrors             = [string]$silmaril.errors
    playwrightErrors           = [string]$playwright.errors
  })
}

$comparisonArray = @($comparisonRows.ToArray())
$silmarilRougherSuccesses = @($comparisonArray | Where-Object {
    ($_.silmarilStatus -in @('clean_success', 'success_with_escalation')) -and
    ($_.playwrightStatus -in @('clean_success', 'success_with_escalation')) -and
    (
      ([double]$_.silmarilMedianEscalation -gt [double]$_.playwrightMedianEscalation) -or
      ([double]$_.silmarilMedianCommands -gt [double]$_.playwrightMedianCommands) -or
      ([double]$_.silmarilMedianRefreshes -gt [double]$_.playwrightMedianRefreshes)
    )
  })
$silmarilEscalationOnly = @($comparisonArray | Where-Object {
    [string]$_.silmarilStatus -eq 'success_with_escalation' -and [string]$_.playwrightStatus -eq 'clean_success'
  })
$silmarilWins = @($comparisonArray | Where-Object {
    (
      ($_.silmarilStatus -in @('clean_success', 'success_with_escalation')) -and
      ($_.playwrightStatus -in @('partial', 'fail'))
    ) -or (
      -not [string]::IsNullOrWhiteSpace([string]$_.silmarilStrengthHypothesis) -and
      ($_.silmarilStatus -in @('clean_success', 'success_with_escalation')) -and
      ([double]$_.silmarilMedianCommands -le [double]$_.playwrightMedianCommands)
    )
  })
$docsVsReality = @($comparisonArray | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_.docsVsRealityNote) -and
    (
      [double]$_.silmarilMedianEscalation -gt 0 -or
      [string]$_.silmarilStatus -ne 'clean_success'
    )
  })

$backlogMap = @{}
foreach ($comparison in @($comparisonArray)) {
  $weight = (Get-StatusSeverity -Status ([string]$comparison.silmarilStatus)) + [int]([double]$comparison.silmarilMedianEscalation)
  if ($weight -le 0) {
    continue
  }

  foreach ($bucket in @($comparison.silmarilImprovementBuckets)) {
    $key = [string]$bucket
    if ([string]::IsNullOrWhiteSpace($key)) {
      continue
    }
    if (-not $backlogMap.ContainsKey($key)) {
      $backlogMap[$key] = [ordered]@{
        bucket = $key
        totalWeight = 0
        taskIds = New-Object System.Collections.Generic.List[string]
        statuses = New-Object System.Collections.Generic.List[string]
      }
    }

    $backlogMap[$key].totalWeight += $weight
    $backlogMap[$key].taskIds.Add([string]$comparison.taskId)
    $backlogMap[$key].statuses.Add([string]$comparison.silmarilStatus)
  }
}

$backlogRows = @($backlogMap.Values | ForEach-Object {
    [pscustomobject]@{
      bucket      = [string]$_.bucket
      totalWeight = [int]$_.totalWeight
      taskCount   = @($_.taskIds | Sort-Object -Unique).Count
      taskIds     = (@($_.taskIds | Sort-Object -Unique) -join ', ')
      statuses    = (@($_.statuses | Sort-Object -Unique) -join ', ')
    }
  } | Sort-Object -Property @{ Expression = 'totalWeight'; Descending = $true }, 'bucket')

$classificationMap = @{}
foreach ($comparison in @($comparisonArray)) {
  $category = Get-InferredIssueCategory -Comparison $comparison
  if ($category -eq 'none') {
    continue
  }
  if (-not $classificationMap.ContainsKey($category)) {
    $classificationMap[$category] = New-Object System.Collections.Generic.List[string]
  }
  $classificationMap[$category].Add([string]$comparison.taskId)
}

$classificationRows = @($classificationMap.Keys | Sort-Object | ForEach-Object {
    [pscustomobject]@{
      category = [string]$_
      taskCount = @($classificationMap[$_] | Sort-Object -Unique).Count
      taskIds = (@($classificationMap[$_] | Sort-Object -Unique) -join ', ')
    }
  })

$summaryPayload = [pscustomobject]@{
  metadata = $payload.metadata
  protocol = $payload.protocol
  selection = $payload.selection
  groupRows = @($groupRows.ToArray())
  taskRows = @($taskRows.ToArray())
  comparisons = $comparisonArray
  findings = [pscustomobject]@{
    silmarilRougherSuccesses = $silmarilRougherSuccesses
    silmarilEscalationOnly   = $silmarilEscalationOnly
    silmarilWins             = $silmarilWins
    docsVsReality            = $docsVsReality
  }
  backlog = $backlogRows
  classifications = $classificationRows
}

$summaryPath = Join-Path $OutputDir 'summary.json'
$summaryPayload | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Benchmark Summary')
$lines.Add('')
$lines.Add(('Generated: `' + [string]$payload.metadata.generatedAtUtc + '`'))
$lines.Add(('Browser: `' + [string]$payload.metadata.browserPath + '`'))
$lines.Add(('Playwright: `' + [string]$payload.metadata.playwrightVersion + '`'))
$lines.Add(('Groups: `' + ((@($payload.selection.groups) -join ', ')) + '`'))
$lines.Add(('Headless: `' + [string]$payload.selection.headless + '`'))
$lines.Add('')
$lines.Add('## Protocol')
$lines.Add('')
$lines.Add(('- Command budget default: `' + [string]$payload.protocol.commandBudgetDefault + '`'))
$lines.Add(('- Time budget default: `' + [string]$payload.protocol.timeBudgetMsDefault + ' ms`'))
$lines.Add(('- Escalation ladder: `' + (Join-StringList -Values @($payload.protocol.escalationLadder | ForEach-Object { [string]$_.id })) + '`'))
$lines.Add('')
$lines.Add('## Group Scoreboard')
$lines.Add('')
$lines.Add('| Group | Tool | Mode | Success % | Clean % | Partial % | Median ms | Median cmds | Median refreshes | Median depth |')
$lines.Add('| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
foreach ($row in @(@($groupRows.ToArray()) | Sort-Object group, tool, mode)) {
  $lines.Add((
    '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} |' -f
    [string]$row.group,
    [string]$row.tool,
    [string]$row.mode,
    [string]$row.successRate,
    [string]$row.cleanSuccessRate,
    [string]$row.partialRate,
    $(if ($null -ne $row.medianWallMs) { [string]$row.medianWallMs } else { 'n/a' }),
    $(if ($null -ne $row.medianCommandCount) { [string]$row.medianCommandCount } else { 'n/a' }),
    $(if ($null -ne $row.medianContextRefreshes) { [string]$row.medianContextRefreshes } else { 'n/a' }),
    $(if ($null -ne $row.medianEscalationDepth) { [string]$row.medianEscalationDepth } else { 'n/a' })
  ))
}
$lines.Add('')
$lines.Add('## Task Head To Head')
$lines.Add('')
$lines.Add('| Task | Group | Silmaril | Playwright | Silmaril cmds | Playwright cmds | Silmaril depth | Playwright depth |')
$lines.Add('| --- | --- | --- | --- | ---: | ---: | ---: | ---: |')
foreach ($row in @($comparisonArray | Sort-Object group, taskId)) {
  $lines.Add((
    '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f
    [string]$row.taskId,
    [string]$row.group,
    [string]$row.silmarilStatus,
    [string]$row.playwrightStatus,
    $(if ($null -ne $row.silmarilMedianCommands) { [string]$row.silmarilMedianCommands } else { 'n/a' }),
    $(if ($null -ne $row.playwrightMedianCommands) { [string]$row.playwrightMedianCommands } else { 'n/a' }),
    $(if ($null -ne $row.silmarilMedianEscalation) { [string]$row.silmarilMedianEscalation } else { 'n/a' }),
    $(if ($null -ne $row.playwrightMedianEscalation) { [string]$row.playwrightMedianEscalation } else { 'n/a' })
  ))
}
$lines.Add('')

$lines.Add('## Key Findings')
$lines.Add('')
$lines.Add('### Tasks Where Both Succeed But Silmaril Feels Worse')
$lines.Add('')
if ($silmarilRougherSuccesses.Count -lt 1) {
  $lines.Add('- None in this run.')
}
else {
  foreach ($row in @($silmarilRougherSuccesses | Sort-Object group, taskId)) {
    $lines.Add(('- `' + [string]$row.taskId + '` in `' + [string]$row.group + '` used more commands or deeper escalation in Silmaril.'))
  }
}
$lines.Add('')

$lines.Add('### Tasks Where Silmaril Needs Deeper Escalation')
$lines.Add('')
if ($silmarilEscalationOnly.Count -lt 1) {
  $lines.Add('- None in this run.')
}
else {
  foreach ($row in @($silmarilEscalationOnly | Sort-Object group, taskId)) {
    $lines.Add(('- `' + [string]$row.taskId + '` succeeded in Silmaril only after escalation beyond the clean path.'))
  }
}
$lines.Add('')

$lines.Add('### Tasks Where Silmaril Shows A Product Advantage')
$lines.Add('')
if ($silmarilWins.Count -lt 1) {
  $lines.Add('- None in this run.')
}
else {
  foreach ($row in @($silmarilWins | Sort-Object group, taskId)) {
    $lines.Add(('- `' + [string]$row.taskId + '` supports the Silmaril value hypothesis: ' + [string]$row.silmarilStrengthHypothesis))
  }
}
$lines.Add('')

$lines.Add('### Docs Versus Real Workflow Mismatches')
$lines.Add('')
if ($docsVsReality.Count -lt 1) {
  $lines.Add('- None in this run.')
}
else {
  foreach ($row in @($docsVsReality | Sort-Object group, taskId)) {
    $lines.Add(('- `' + [string]$row.taskId + '`: ' + [string]$row.docsVsRealityNote))
  }
}
$lines.Add('')

$lines.Add('## Silmaril Backlog')
$lines.Add('')
$lines.Add('| Bucket | Weight | Task count | Supporting tasks |')
$lines.Add('| --- | ---: | ---: | --- |')
foreach ($row in @($backlogRows | Sort-Object -Property @{ Expression = 'totalWeight'; Descending = $true }, 'bucket')) {
  $lines.Add((
    '| {0} | {1} | {2} | {3} |' -f
    [string]$row.bucket,
    [int]$row.totalWeight,
    [int]$row.taskCount,
    [string]$row.taskIds
  ))
}
$lines.Add('')

$lines.Add('## Issue Classification')
$lines.Add('')
$lines.Add('| Category | Task count | Tasks |')
$lines.Add('| --- | ---: | --- |')
foreach ($row in @($classificationRows | Sort-Object category)) {
  $lines.Add((
    '| {0} | {1} | {2} |' -f
    [string]$row.category,
    [int]$row.taskCount,
    [string]$row.taskIds
  ))
}
$lines.Add('')

$markdownPath = Join-Path $OutputDir 'summary.md'
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8

Write-Host ("Summary written to {0}" -f $markdownPath)
