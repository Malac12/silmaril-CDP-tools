param(
  [Alias('Tier')]
  [string[]]$Group = @('all'),
  [string[]]$TaskId = @(),
  [ValidateSet('silmaril', 'playwright', 'all')]
  [string[]]$Tool = @('all'),
  [switch]$Headless = $true,
  [int]$ColdRuns = 1,
  [int]$WarmRuns = 2,
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

$manifest = Get-BenchmarkTaskManifest
$protocol = Get-BenchmarkProtocol
$tasks = @(Get-BenchmarkTasks -TaskId $TaskId -Group $Group)
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
  $modePlan = @()
  if ($ColdRuns -gt 0) {
    $modePlan += [pscustomobject]@{ Mode = 'cold'; Repetitions = $ColdRuns }
  }
  if ($WarmRuns -gt 0) {
    $modePlan += [pscustomobject]@{ Mode = 'warm'; Repetitions = $WarmRuns }
  }

  foreach ($toolName in @($selectedTools)) {
    foreach ($modeEntry in @($modePlan)) {
      for ($runIndex = 1; $runIndex -le [int]$modeEntry.Repetitions; $runIndex += 1) {
        $runStartUtc = [DateTime]::UtcNow.ToString('o')
        Write-Host ("[{0}] {1} ({2}) {3} run {4}/{5}" -f $toolName, [string]$task.id, [string]$task.group, [string]$modeEntry.Mode, $runIndex, [int]$modeEntry.Repetitions)

        try {
          $adapterResult = switch ($toolName) {
            'silmaril' { Invoke-SilmarilBenchmarkTask -Task $task -Protocol $protocol -Mode ([string]$modeEntry.Mode) -Headless:$Headless }
            'playwright' { Invoke-PlaywrightBenchmarkTask -Task $task -Protocol $protocol -Mode ([string]$modeEntry.Mode) -Headless:$Headless }
            default { throw "Unsupported tool selection: $toolName" }
          }
        }
        catch {
          $adapterResult = [pscustomobject]@{
            ok                  = $false
            tool                = $toolName
            taskId              = [string]$task.id
            group               = [string]$task.group
            mode                = [string]$modeEntry.Mode
            startupMs           = $null
            taskMs              = $null
            wallMs              = $null
            finalUrl            = $null
            error               = [string]$_.Exception.Message
            steps               = @()
            transcript          = @()
            variables           = @{}
            commandCount        = 0
            contextRefreshCount = 0
            maxEscalationDepth  = 0
            distinctSurfaces    = @()
            escalationTrace     = @()
            completedStepCount  = 0
            totalStepCount      = @((Get-BenchmarkTaskSteps -Task $task -Tool $toolName)).Count
          }
        }

        $runRecords.Add((ConvertTo-BenchmarkRunRecord -RunStartUtc $runStartUtc -Task $task -AdapterResult $adapterResult -Tool $toolName -Mode ([string]$modeEntry.Mode) -RunIndex $runIndex -Protocol $protocol))
      }
    }
  }
}

$selectedTaskIds = @($tasks | ForEach-Object { [string]$_.id })

$rawPayload = [pscustomobject]@{
  metadata = [pscustomobject]$metadata
  protocol = $protocol
  selection = [pscustomobject]@{
    groups   = @($Group)
    taskIds  = $selectedTaskIds
    tools    = $selectedTools
    headless = [bool]$Headless
    coldRuns = [int]$ColdRuns
    warmRuns = [int]$WarmRuns
  }
  tasks = @($tasks)
  runs = @($runRecords.ToArray())
}

$rawPath = Join-Path $OutputDir 'raw-results.json'
$rawPayload | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $rawPath -Encoding UTF8

if (-not $SkipSummary) {
  & (Join-Path $PSScriptRoot 'Summarize-Benchmarks.ps1') -InputFile $rawPath -OutputDir $OutputDir
}

Write-Host ("Benchmark results written to {0}" -f $OutputDir)
