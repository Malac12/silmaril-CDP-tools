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

function Join-CountPairs {
  param([hashtable]$Counts)

  if ($null -eq $Counts -or $Counts.Count -lt 1) {
    return ''
  }

  $pairs = @()
  foreach ($key in @($Counts.Keys | Sort-Object)) {
    $pairs += ("{0} x{1}" -f [string]$key, [int]$Counts[$key])
  }

  return ($pairs -join '; ')
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

$summaryRows = New-Object System.Collections.Generic.List[object]
$grouped = $runs | Group-Object tier, taskId, tool, mode
foreach ($group in @($grouped)) {
  $items = @($group.Group)
  $successItems = @($items | Where-Object { $_.ok -and $null -ne $_.wallMs })
  $durations = @($successItems | ForEach-Object { [double]$_.wallMs })
  $startupDurations = @($successItems | Where-Object { $null -ne $_.startupMs } | ForEach-Object { [double]$_.startupMs })
  $failureCounts = @{}
  foreach ($failed in @($items | Where-Object { -not $_.ok })) {
    $message = if ([string]::IsNullOrWhiteSpace([string]$failed.error)) { 'Unknown error' } else { [string]$failed.error }
    if (-not $failureCounts.ContainsKey($message)) {
      $failureCounts[$message] = 0
    }
    $failureCounts[$message] += 1
  }

  $first = $items[0]
  $summaryRows.Add([pscustomobject]@{
    tier            = [string]$first.tier
    taskId          = [string]$first.taskId
    tool            = [string]$first.tool
    mode            = [string]$first.mode
    runs            = [int]$items.Count
    successCount    = [int]$successItems.Count
    successRate     = [Math]::Round((([double]$successItems.Count / [Math]::Max($items.Count, 1)) * 100.0), 2)
    medianMs        = Get-PercentileValue -Values $durations -Percentile 50
    p95Ms           = Get-PercentileValue -Values $durations -Percentile 95
    minMs           = if ($durations.Count -gt 0) { [Math]::Round(([double]($durations | Measure-Object -Minimum).Minimum), 3) } else { $null }
    maxMs           = if ($durations.Count -gt 0) { [Math]::Round(([double]($durations | Measure-Object -Maximum).Maximum), 3) } else { $null }
    medianStartupMs = Get-PercentileValue -Values $startupDurations -Percentile 50
    failures        = Join-CountPairs -Counts $failureCounts
  })
}

$summaryArray = @($summaryRows.ToArray())

$summaryPath = Join-Path $OutputDir 'summary.json'
@{
  metadata = $payload.metadata
  selection = $payload.selection
  rows = $summaryArray
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Benchmark Summary')
$lines.Add('')
$lines.Add(('Generated: `' + [string]$payload.metadata.generatedAtUtc + '`'))
$lines.Add(('Browser: `' + [string]$payload.metadata.browserPath + '`'))
$lines.Add(('Playwright: `' + [string]$payload.metadata.playwrightVersion + '`'))
$lines.Add(('Headless: `' + [string]$payload.selection.headless + '`'))
$lines.Add('')

foreach ($tierGroup in @($summaryArray | Group-Object tier | Sort-Object Name)) {
  $lines.Add(("## {0}" -f ([cultureinfo]::InvariantCulture.TextInfo.ToTitleCase([string]$tierGroup.Name))))
  $lines.Add('')
  $lines.Add('| Task | Tool | Mode | Runs | Success % | Median ms | P95 ms | Median startup ms | Failures |')
  $lines.Add('| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |')
  foreach ($row in @($tierGroup.Group | Sort-Object taskId, tool, mode)) {
    $median = if ($null -ne $row.medianMs) { [string]$row.medianMs } else { 'n/a' }
    $p95 = if ($null -ne $row.p95Ms) { [string]$row.p95Ms } else { 'n/a' }
    $startup = if ($null -ne $row.medianStartupMs) { [string]$row.medianStartupMs } else { 'n/a' }
    $failures = if ([string]::IsNullOrWhiteSpace([string]$row.failures)) { '' } else { [string]$row.failures }
    $lines.Add((
      '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f
      [string]$row.taskId,
      [string]$row.tool,
      [string]$row.mode,
      [int]$row.runs,
      [string]$row.successRate,
      $median,
      $p95,
      $startup,
      $failures
    ))
  }
  $lines.Add('')
}

$markdownPath = Join-Path $OutputDir 'summary.md'
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8

Write-Host ("Summary written to {0}" -f $markdownPath)
