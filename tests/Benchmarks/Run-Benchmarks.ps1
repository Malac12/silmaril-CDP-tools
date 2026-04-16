param(
  [ValidateSet('all', 'micro', 'flow')]
  [string]$Tier = 'all',
  [string[]]$TaskId = @(),
  [ValidateSet('silmaril', 'playwright', 'all')]
  [string[]]$Tool = @('all'),
  [switch]$Headless = $true,
  [int]$ColdRuns = 3,
  [int]$WarmMicroRuns = 20,
  [int]$WarmFlowRuns = 10,
  [string]$OutputDir = '',
  [switch]$SkipSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'BenchmarkHelpers.ps1')

function Get-SelectedTools {
  param([string[]]$RequestedTools)

  if (-not $RequestedTools -or $RequestedTools.Count -eq 0 -or $RequestedTools -contains 'all') {
    return @('silmaril', 'playwright')
  }

  return @($RequestedTools | ForEach-Object { [string]$_.ToLowerInvariant() })
}

$tasks = @(Get-BenchmarkTasks -TaskId $TaskId -Tier $Tier)
if (-not $tasks -or $tasks.Count -lt 1) {
  throw 'No benchmark tasks selected.'
}

$selectedTools = Get-SelectedTools -RequestedTools $Tool
$metadata = Get-BenchmarkEnvironmentMetadata

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $PSScriptRoot ('results/' + (Get-BenchmarkNowUtcString))
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$runRecords = New-Object System.Collections.Generic.List[object]

foreach ($task in @($tasks)) {
  $warmRuns = if ([string]$task.tier -eq 'micro') { $WarmMicroRuns } else { $WarmFlowRuns }
  $modePlan = @()
  if ($ColdRuns -gt 0) {
    $modePlan += [pscustomobject]@{ Mode = 'cold'; Repetitions = $ColdRuns }
  }
  if ($warmRuns -gt 0) {
    $modePlan += [pscustomobject]@{ Mode = 'warm'; Repetitions = $warmRuns }
  }

  foreach ($toolName in @($selectedTools)) {
    foreach ($modeEntry in @($modePlan)) {
      for ($runIndex = 1; $runIndex -le [int]$modeEntry.Repetitions; $runIndex += 1) {
        $runStartUtc = [DateTime]::UtcNow.ToString('o')
        Write-Host ("[{0}] {1} {2} run {3}/{4}" -f $toolName, [string]$task.id, [string]$modeEntry.Mode, $runIndex, [int]$modeEntry.Repetitions)

        try {
          $adapterResult = switch ($toolName) {
            'silmaril' { Invoke-SilmarilBenchmarkTask -Task $task -Mode ([string]$modeEntry.Mode) -Headless:$Headless }
            'playwright' { Invoke-PlaywrightBenchmarkTask -Task $task -Mode ([string]$modeEntry.Mode) -Headless:$Headless }
            default { throw "Unsupported tool selection: $toolName" }
          }
        }
        catch {
          $adapterResult = [pscustomobject]@{
            ok        = $false
            tool      = $toolName
            taskId    = [string]$task.id
            tier      = [string]$task.tier
            mode      = [string]$modeEntry.Mode
            startupMs = $null
            taskMs    = $null
            wallMs    = $null
            finalUrl  = $null
            error     = [string]$_.Exception.Message
            steps     = @()
          }
        }

        $runRecords.Add([pscustomobject]@{
          timestampUtc = $runStartUtc
          taskId       = [string]$task.id
          description  = [string]$task.description
          tier         = [string]$task.tier
          tool         = [string]$toolName
          mode         = [string]$modeEntry.Mode
          runIndex     = $runIndex
          ok           = [bool]$adapterResult.ok
          startupMs    = $adapterResult.startupMs
          taskMs       = $adapterResult.taskMs
          wallMs       = $adapterResult.wallMs
          finalUrl     = $adapterResult.finalUrl
          error        = $adapterResult.error
          steps        = $adapterResult.steps
        })
      }
    }
  }
}

$selectedTaskIds = @($tasks | ForEach-Object { [string]$_.id })

$metadataObject = [pscustomobject]$metadata
$selectionObject = [pscustomobject]@{
  tier          = $Tier
  taskIds       = $selectedTaskIds
  tools         = $selectedTools
  headless      = [bool]$Headless
  coldRuns      = [int]$ColdRuns
  warmMicroRuns = [int]$WarmMicroRuns
  warmFlowRuns  = [int]$WarmFlowRuns
}
$runsArray = @($runRecords.ToArray())
$rawPayload = [pscustomobject]@{
  metadata = $metadataObject
  selection = $selectionObject
  runs = $runsArray
}

$rawPath = Join-Path $OutputDir 'raw-results.json'
$rawPayload | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $rawPath -Encoding UTF8

if (-not $SkipSummary) {
  & (Join-Path $PSScriptRoot 'Summarize-Benchmarks.ps1') -InputFile $rawPath -OutputDir $OutputDir
}

Write-Host ("Benchmark results written to {0}" -f $OutputDir)
