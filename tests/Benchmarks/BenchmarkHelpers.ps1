Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BenchmarksRoot = $PSScriptRoot
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:TasksFile = Join-Path $script:BenchmarksRoot 'tasks.json'
$script:PlaywrightRunner = Join-Path $script:BenchmarksRoot 'playwright-benchmark.js'
$script:SilmarilEntryScript = Join-Path $script:RepoRoot 'silmaril.ps1'

. (Join-Path $script:RepoRoot 'lib/common.ps1')

$script:ShellPath = (Get-Process -Id $PID).Path
$script:ShellArgs = @('-NoProfile')
$script:IsWindowsPlatform = (($PSVersionTable.PSEdition -eq 'Desktop') -or ($env:OS -eq 'Windows_NT') -or ((Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) -and $IsWindows))
if ($script:IsWindowsPlatform) {
  $script:ShellArgs += @('-ExecutionPolicy', 'Bypass')
}

function Test-BenchmarkProperty {
  param(
    [object]$InputObject,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ($null -eq $InputObject) {
    return $false
  }

  return (@($InputObject.PSObject.Properties.Name) -contains $Name)
}

function Get-BenchmarkPropertyValue {
  param(
    [object]$InputObject,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [object]$Default = $null
  )

  if (Test-BenchmarkProperty -InputObject $InputObject -Name $Name) {
    return $InputObject.$Name
  }

  return $Default
}

function Get-BenchmarkNowUtcString {
  return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH-mm-ssZ')
}

function ConvertTo-BenchmarkMilliseconds {
  param(
    [Parameter(Mandatory = $true)]
    [System.Diagnostics.Stopwatch]$Stopwatch
  )

  return [Math]::Round($Stopwatch.Elapsed.TotalMilliseconds, 3)
}

function Get-FreeLoopbackPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  try {
    $listener.Start()
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  }
  finally {
    $listener.Stop()
  }
}

function Get-BenchmarkTaskManifest {
  if (-not (Test-Path -LiteralPath $script:TasksFile)) {
    throw "Missing benchmark task file: $($script:TasksFile)"
  }

  return (Get-Content -LiteralPath $script:TasksFile -Raw | ConvertFrom-Json)
}

function Get-BenchmarkProtocol {
  $manifest = Get-BenchmarkTaskManifest
  if (-not (Test-BenchmarkProperty -InputObject $manifest -Name 'protocol')) {
    throw 'Benchmark manifest is missing protocol metadata.'
  }

  return $manifest.protocol
}

function Get-BenchmarkGroupNames {
  $manifest = Get-BenchmarkTaskManifest
  return @($manifest.tasks | ForEach-Object { [string]$_.group } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Get-BenchmarkTasks {
  param(
    [string[]]$TaskId = @(),
    [string[]]$Group = @('all')
  )

  $manifest = Get-BenchmarkTaskManifest
  $tasks = @($manifest.tasks)

  $requestedGroups = @($Group | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_.ToLowerInvariant() })
  if ($requestedGroups.Count -gt 0 -and -not ($requestedGroups -contains 'all')) {
    $knownGroups = Get-BenchmarkGroupNames
    foreach ($requestedGroup in $requestedGroups) {
      if (-not ($knownGroups -contains $requestedGroup)) {
        throw "Unknown benchmark group: $requestedGroup"
      }
    }

    $tasks = @($tasks | Where-Object { $requestedGroups -contains ([string]$_.group).ToLowerInvariant() })
  }

  if ($TaskId -and $TaskId.Count -gt 0) {
    $requestedIds = @($TaskId | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $tasks = @($tasks | Where-Object { $requestedIds -contains [string]$_.id })
    foreach ($id in $requestedIds) {
      if (-not (@($tasks | Where-Object { [string]$_.id -eq $id }).Count)) {
        throw "Unknown benchmark task id: $id"
      }
    }
  }

  return @($tasks)
}

function Get-BenchmarkTaskSteps {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Task,
    [Parameter(Mandatory = $true)]
    [ValidateSet('silmaril', 'playwright')]
    [string]$Tool
  )

  if (Test-BenchmarkProperty -InputObject $Task -Name 'profiles') {
    $profiles = $Task.profiles
    if (Test-BenchmarkProperty -InputObject $profiles -Name $Tool) {
      $profile = $profiles.$Tool
      if (Test-BenchmarkProperty -InputObject $profile -Name 'steps') {
        return @($profile.steps)
      }
    }
  }

  if (Test-BenchmarkProperty -InputObject $Task -Name 'steps') {
    return @($Task.steps)
  }

  throw "Task $([string]$Task.id) does not declare steps for tool $Tool."
}

function Resolve-BenchmarkTemplateString {
  param(
    [AllowNull()]
    [object]$Value,
    [hashtable]$Variables
  )

  if ($null -eq $Value) {
    return $null
  }

  $text = [string]$Value
  if ($null -eq $Variables -or $Variables.Count -lt 1) {
    return $text
  }

  $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)

    $token = [string]$match.Groups[1].Value
    if ($token.StartsWith('urlencode:', [System.StringComparison]::OrdinalIgnoreCase)) {
      $name = $token.Substring(10)
      if ($Variables.ContainsKey($name)) {
        return [System.Uri]::EscapeDataString([string]$Variables[$name])
      }
      return $match.Value
    }

    if ($Variables.ContainsKey($token)) {
      return [string]$Variables[$token]
    }

    return $match.Value
  }

  return [System.Text.RegularExpressions.Regex]::Replace($text, '\{\{([^}]+)\}\}', $evaluator)
}

function Resolve-BenchmarkTemplateStringArray {
  param(
    [object[]]$Values,
    [hashtable]$Variables
  )

  $resolved = @()
  foreach ($value in @($Values)) {
    $resolved += (Resolve-BenchmarkTemplateString -Value $value -Variables $Variables)
  }

  return $resolved
}

function Get-BenchmarkValueByPath {
  param(
    [AllowNull()]
    [object]$InputObject,
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $InputObject
  }

  $current = $InputObject
  foreach ($segment in @($Path -split '\.')) {
    if ($null -eq $current) {
      return $null
    }

    if ($segment -match '^\d+$') {
      $index = [int]$segment
      $items = @($current)
      if ($index -ge $items.Count) {
        return $null
      }
      $current = $items[$index]
      continue
    }

    if ($current -is [System.Collections.IDictionary]) {
      if (-not $current.Contains($segment)) {
        return $null
      }
      $current = $current[$segment]
      continue
    }

    if (-not (Test-BenchmarkProperty -InputObject $current -Name $segment)) {
      return $null
    }

    $current = $current.$segment
  }

  return $current
}

function Set-BenchmarkStoredValues {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Variables,
    [AllowNull()]
    [object]$Payload,
    [AllowNull()]
    [object]$SaveAs,
    [string]$SaveFrom = '',
    [string]$DefaultSaveFrom = ''
  )

  if ($null -eq $SaveAs) {
    return
  }

  if ($SaveAs -is [string]) {
    $path = if ([string]::IsNullOrWhiteSpace($SaveFrom)) { $DefaultSaveFrom } else { $SaveFrom }
    $Variables[[string]$SaveAs] = (Get-BenchmarkValueByPath -InputObject $Payload -Path $path)
    return
  }

  foreach ($property in @($SaveAs.PSObject.Properties)) {
    $Variables[[string]$property.Name] = (Get-BenchmarkValueByPath -InputObject $Payload -Path ([string]$property.Value))
  }
}

function Get-BenchmarkEscalationDepth {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Protocol,
    [string]$Surface = 'documented'
  )

  $normalizedSurface = if ([string]::IsNullOrWhiteSpace($Surface)) { 'documented' } else { [string]$Surface }
  foreach ($entry in @($Protocol.escalationLadder)) {
    if ([string]$entry.id -eq $normalizedSurface) {
      return [int]$entry.depth
    }
  }

  return 0
}

function Get-BenchmarkCommandBudget {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Task,
    [Parameter(Mandatory = $true)]
    [object]$Protocol
  )

  if (Test-BenchmarkProperty -InputObject $Task -Name 'commandBudget') {
    return [int]$Task.commandBudget
  }

  return [int]$Protocol.commandBudgetDefault
}

function Get-BenchmarkTimeBudgetMs {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Task,
    [Parameter(Mandatory = $true)]
    [object]$Protocol
  )

  if (Test-BenchmarkProperty -InputObject $Task -Name 'timeBudgetMs') {
    return [int]$Task.timeBudgetMs
  }

  return [int]$Protocol.timeBudgetMsDefault
}

function Get-BenchmarkBoundaryDepth {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Task,
    [Parameter(Mandatory = $true)]
    [object]$Protocol
  )

  $boundary = Get-BenchmarkPropertyValue -InputObject $Task -Name 'fallbackEscalationBoundary' -Default 'raw_js'
  return (Get-BenchmarkEscalationDepth -Protocol $Protocol -Surface ([string]$boundary))
}

function Get-BenchmarkDefaultSurface {
  param([object]$Step)

  return [string](Get-BenchmarkPropertyValue -InputObject $Step -Name 'surface' -Default 'documented')
}

function Get-BenchmarkStepCountsAsCommand {
  param([object]$Step)

  if (Test-BenchmarkProperty -InputObject $Step -Name 'countsAsCommand') {
    return [bool]$Step.countsAsCommand
  }

  return (-not (([string]$Step.type) -in @('snapshotFindRef', 'switchTarget')))
}

function Get-BenchmarkStepCountsAsRefresh {
  param([object]$Step)

  if (Test-BenchmarkProperty -InputObject $Step -Name 'countsAsRefresh') {
    return [bool]$Step.countsAsRefresh
  }

  return $false
}

function Assert-BenchmarkTextContains {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Actual,
    [Parameter(Mandatory = $true)]
    [string]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$ContextLabel
  )

  if ([string]::IsNullOrWhiteSpace($Actual) -or ($Actual.IndexOf($Expected, [System.StringComparison]::Ordinal) -lt 0)) {
    throw "$ContextLabel did not contain expected text: $Expected"
  }
}

function Assert-BenchmarkTextEquals {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Actual,
    [Parameter(Mandatory = $true)]
    [string]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$ContextLabel
  )

  if ([string]$Actual -ne [string]$Expected) {
    throw "$ContextLabel was '$Actual' but expected '$Expected'."
  }
}

function Assert-BenchmarkQueryExpectation {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Payload,
    [object]$Expectation,
    [Parameter(Mandatory = $true)]
    [string]$ContextLabel
  )

  if ($null -eq $Expectation) {
    return
  }

  $expectationProps = @($Expectation.PSObject.Properties.Name)
  if (($expectationProps -contains 'returnedCountAtLeast') -and ([int]$Payload.returnedCount -lt [int]$Expectation.returnedCountAtLeast)) {
    throw "$ContextLabel returned $($Payload.returnedCount) rows; expected at least $($Expectation.returnedCountAtLeast)."
  }
  if (($expectationProps -contains 'matchedCountAtLeast') -and ([int]$Payload.matchedCount -lt [int]$Expectation.matchedCountAtLeast)) {
    throw "$ContextLabel matched $($Payload.matchedCount) rows; expected at least $($Expectation.matchedCountAtLeast)."
  }
  if (($expectationProps -contains 'visibleCountAtLeast') -and ([int]$Payload.visibleCount -lt [int]$Expectation.visibleCountAtLeast)) {
    throw "$ContextLabel exposed $($Payload.visibleCount) visible rows; expected at least $($Expectation.visibleCountAtLeast)."
  }

  if (($expectationProps -contains 'firstRow') -and $null -ne $Expectation.firstRow) {
    if ([int]$Payload.returnedCount -lt 1) {
      throw "$ContextLabel returned no rows; expected a first row."
    }

    $actualRow = $Payload.rows[0]
    foreach ($property in @($Expectation.firstRow.PSObject.Properties)) {
      $fieldName = [string]$property.Name
      $expectedValue = $property.Value
      $actualValue = $actualRow.$fieldName
      if ($actualValue -is [System.Array]) {
        $actualValue = @($actualValue) -join ','
      }
      if ($expectedValue -is [System.Array]) {
        $expectedValue = @($expectedValue) -join ','
      }
      if ([string]$actualValue -ne [string]$expectedValue) {
        throw "$ContextLabel field '$fieldName' was '$actualValue' but expected '$expectedValue'."
      }
    }
  }
}

function Assert-BenchmarkSnapshotExpectation {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Payload,
    [object]$Expectation,
    [Parameter(Mandatory = $true)]
    [string]$ContextLabel
  )

  if ($null -eq $Expectation) {
    return
  }

  if ((Test-BenchmarkProperty -InputObject $Expectation -Name 'refCountAtLeast') -and ([int]$Payload.refCount -lt [int]$Expectation.refCountAtLeast)) {
    throw "$ContextLabel captured $($Payload.refCount) refs; expected at least $($Expectation.refCountAtLeast)."
  }
}

function Find-BenchmarkSnapshotRef {
  param(
    [object[]]$Refs,
    [Parameter(Mandatory = $true)]
    [object]$Step
  )

  $matches = @($Refs | Where-Object {
      $ref = $_
      $ok = $true

      if ((Test-BenchmarkProperty -InputObject $Step -Name 'label') -and -not [string]::IsNullOrWhiteSpace([string]$Step.label)) {
        $ok = $ok -and ([string]$ref.label -eq [string]$Step.label)
      }
      if ((Test-BenchmarkProperty -InputObject $Step -Name 'labelIncludes') -and -not [string]::IsNullOrWhiteSpace([string]$Step.labelIncludes)) {
        $ok = $ok -and (-not [string]::IsNullOrWhiteSpace([string]$ref.label)) -and ([string]$ref.label).Contains([string]$Step.labelIncludes)
      }
      if ((Test-BenchmarkProperty -InputObject $Step -Name 'role') -and -not [string]::IsNullOrWhiteSpace([string]$Step.role)) {
        $ok = $ok -and ([string]$ref.role -eq [string]$Step.role)
      }
      if ((Test-BenchmarkProperty -InputObject $Step -Name 'kind') -and -not [string]::IsNullOrWhiteSpace([string]$Step.kind)) {
        $ok = $ok -and ([string]$ref.kind -eq [string]$Step.kind)
      }
      if ((Test-BenchmarkProperty -InputObject $Step -Name 'tag') -and -not [string]::IsNullOrWhiteSpace([string]$Step.tag)) {
        $ok = $ok -and ([string]$ref.tag -eq [string]$Step.tag)
      }
      if ((Test-BenchmarkProperty -InputObject $Step -Name 'selector') -and -not [string]::IsNullOrWhiteSpace([string]$Step.selector)) {
        $ok = $ok -and ([string]$ref.selector -eq [string]$Step.selector)
      }
      if ((Test-BenchmarkProperty -InputObject $Step -Name 'selectorIncludes') -and -not [string]::IsNullOrWhiteSpace([string]$Step.selectorIncludes)) {
        $ok = $ok -and (-not [string]::IsNullOrWhiteSpace([string]$ref.selector)) -and ([string]$ref.selector).Contains([string]$Step.selectorIncludes)
      }

      return $ok
    })

  if ($matches.Count -lt 1) {
    throw 'No snapshot ref matched the requested criteria.'
  }

  return $matches[0]
}

function Get-BenchmarkFrictionSignals {
  param(
    [AllowNull()]
    [string]$Error,
    [object[]]$Steps
  )

  $messages = @()
  if (-not [string]::IsNullOrWhiteSpace($Error)) {
    $messages += $Error
  }
  foreach ($step in @($Steps)) {
    if ((Test-BenchmarkProperty -InputObject $step -Name 'error') -and -not [string]::IsNullOrWhiteSpace([string]$step.error)) {
      $messages += [string]$step.error
    }
  }

  $joined = ($messages -join ' | ')
  return [ordered]@{
    quotingIssues         = if ($joined -match 'Unexpected token|Invalid selector') { 1 } else { 0 }
    staleRefs             = if ($joined -match 'snapshot|ref matched|resolvedRef|No snapshot ref') { 1 } else { 0 }
    frameTargetConfusion  = if ($joined -match 'target|tab|url-match|TARGET_AMBIGUOUS') { 1 } else { 0 }
    waitAmbiguity         = if ($joined -match 'Timed out|wait') { 1 } else { 0 }
    resultParsingAmbiguity = if ($joined -match 'expected|returned no rows|did not contain expected text') { 1 } else { 0 }
  }
}

function Get-BenchmarkOutcomeStatus {
  param(
    [Parameter(Mandatory = $true)]
    [bool]$Ok,
    [Parameter(Mandatory = $true)]
    [int]$CompletedStepCount,
    [Parameter(Mandatory = $true)]
    [int]$TotalStepCount,
    [Parameter(Mandatory = $true)]
    [int]$MaxEscalationDepth
  )

  if ($Ok) {
    if ($MaxEscalationDepth -gt 0) {
      return 'success_with_escalation'
    }

    return 'clean_success'
  }

  if ($CompletedStepCount -ge [Math]::Max(1, [Math]::Floor($TotalStepCount / 2.0))) {
    return 'partial'
  }

  return 'fail'
}

function Get-BenchmarkWhySummary {
  param(
    [Parameter(Mandatory = $true)]
    [object]$AdapterResult
  )

  if ([bool]$AdapterResult.ok) {
    $surfaceList = @($AdapterResult.distinctSurfaces | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($surfaceList.Count -gt 0) {
      return ("Succeeded using surfaces: " + ($surfaceList -join ', '))
    }

    return 'Succeeded within the documented interaction loop.'
  }

  $lastFailedStep = @($AdapterResult.steps | Where-Object { -not $_.ok } | Select-Object -Last 1)[0]
  if ($null -ne $lastFailedStep) {
    return ("Failed on step {0} ({1}): {2}" -f [int]$lastFailedStep.index, [string]$lastFailedStep.type, [string](Get-BenchmarkPropertyValue -InputObject $lastFailedStep -Name 'error' -Default 'Unknown step error'))
  }

  $adapterError = [string](Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'error' -Default '')
  if (-not [string]::IsNullOrWhiteSpace($adapterError)) {
    return ("Failed before step completion: " + $adapterError)
  }

  return 'Failed without a structured step-level error.'
}

function ConvertTo-BenchmarkRunRecord {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RunStartUtc,
    [Parameter(Mandatory = $true)]
    [object]$Task,
    [Parameter(Mandatory = $true)]
    [object]$AdapterResult,
    [Parameter(Mandatory = $true)]
    [string]$Tool,
    [Parameter(Mandatory = $true)]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [int]$RunIndex,
    [Parameter(Mandatory = $true)]
    [object]$Protocol
  )

  $commandBudget = Get-BenchmarkCommandBudget -Task $Task -Protocol $Protocol
  $timeBudgetMs = Get-BenchmarkTimeBudgetMs -Task $Task -Protocol $Protocol
  $boundaryDepth = Get-BenchmarkBoundaryDepth -Task $Task -Protocol $Protocol
  $completedStepCount = [int](Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'completedStepCount' -Default 0)
  $totalStepCount = [int](Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'totalStepCount' -Default @($AdapterResult.steps).Count)
  $maxEscalationDepth = [int](Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'maxEscalationDepth' -Default 0)
  $commandCount = [int](Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'commandCount' -Default 0)
  $contextRefreshCount = [int](Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'contextRefreshCount' -Default 0)
  $distinctSurfaces = @((Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'distinctSurfaces' -Default @()) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $status = Get-BenchmarkOutcomeStatus -Ok ([bool]$AdapterResult.ok) -CompletedStepCount $completedStepCount -TotalStepCount ([Math]::Max($totalStepCount, 1)) -MaxEscalationDepth $maxEscalationDepth
  $wallMs = [double](Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'wallMs' -Default 0.0)
  $signals = Get-BenchmarkFrictionSignals -Error ([string](Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'error' -Default '')) -Steps @($AdapterResult.steps)

  return [pscustomobject]@{
    timestampUtc               = $RunStartUtc
    taskId                     = [string]$Task.id
    group                      = [string]$Task.group
    site                       = [string](Get-BenchmarkPropertyValue -InputObject $Task -Name 'site' -Default '')
    title                      = [string](Get-BenchmarkPropertyValue -InputObject $Task -Name 'title' -Default $Task.id)
    description                = [string](Get-BenchmarkPropertyValue -InputObject $Task -Name 'description' -Default '')
    startingUrl                = [string](Get-BenchmarkPropertyValue -InputObject $Task -Name 'startingUrl' -Default '')
    successCondition           = [string](Get-BenchmarkPropertyValue -InputObject $Task -Name 'successCondition' -Default '')
    primaryInteractionPattern  = [string](Get-BenchmarkPropertyValue -InputObject $Task -Name 'expectedPrimaryInteractionPattern' -Default '')
    allowedToolSurface         = Get-BenchmarkPropertyValue -InputObject $Task -Name 'allowedToolSurface' -Default $null
    fallbackEscalationBoundary = [string](Get-BenchmarkPropertyValue -InputObject $Task -Name 'fallbackEscalationBoundary' -Default 'raw_js')
    stopCondition              = [string](Get-BenchmarkPropertyValue -InputObject $Task -Name 'stopCondition' -Default '')
    commandBudget              = $commandBudget
    timeBudgetMs               = $timeBudgetMs
    docsVsRealityNote          = [string](Get-BenchmarkPropertyValue -InputObject $Task -Name 'docsVsRealityNote' -Default '')
    silmarilStrengthHypothesis = [string](Get-BenchmarkPropertyValue -InputObject $Task -Name 'silmarilStrengthHypothesis' -Default '')
    silmarilImprovementBuckets = @(Get-BenchmarkPropertyValue -InputObject $Task -Name 'silmarilImprovementBuckets' -Default @())
    labels                     = @(Get-BenchmarkPropertyValue -InputObject $Task -Name 'labels' -Default @())
    tool                       = $Tool
    mode                       = $Mode
    runIndex                   = $RunIndex
    ok                         = [bool]$AdapterResult.ok
    status                     = $status
    startupMs                  = Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'startupMs' -Default $null
    taskMs                     = Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'taskMs' -Default $null
    wallMs                     = Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'wallMs' -Default $null
    finalUrl                   = [string](Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'finalUrl' -Default '')
    error                      = Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'error' -Default $null
    totalStepCount             = $totalStepCount
    completedStepCount         = $completedStepCount
    progressRatio              = [Math]::Round(([double]$completedStepCount / [Math]::Max($totalStepCount, 1)), 3)
    commandCount               = $commandCount
    contextRefreshCount        = $contextRefreshCount
    maxEscalationDepth         = $maxEscalationDepth
    escalationWithinBoundary   = ($maxEscalationDepth -le $boundaryDepth)
    distinctSurfaces           = $distinctSurfaces
    escalationTrace            = @(Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'escalationTrace' -Default @())
    frictionSignals            = [pscustomobject]$signals
    budgetBreached             = (($commandCount -gt $commandBudget) -or ($wallMs -gt $timeBudgetMs))
    commandBudgetBreached      = ($commandCount -gt $commandBudget)
    timeBudgetBreached         = ($wallMs -gt $timeBudgetMs)
    steps                      = @(Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'steps' -Default @())
    transcript                 = @(Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'transcript' -Default @())
    variables                  = Get-BenchmarkPropertyValue -InputObject $AdapterResult -Name 'variables' -Default @{}
    analysis                   = [pscustomobject]@{
      why                         = (Get-BenchmarkWhySummary -AdapterResult $AdapterResult)
      manualFailureCategory       = $null
      manualOperatorNotes         = ''
      manualToolClarity           = $null
      manualRecoveryQuality       = $null
      manualFrictionSignals       = [pscustomobject]@{
        quotingIssues         = $null
        staleRefs             = $null
        frameTargetConfusion  = $null
        waitAmbiguity         = $null
        resultParsingAmbiguity = $null
      }
    }
  }
}

function Get-PlaywrightNodeModulesPath {
  $candidate = Join-Path (Get-SilmarilUserHome) 'node_modules'
  if (Test-Path -LiteralPath $candidate) {
    return $candidate
  }

  return $null
}

function Get-PlaywrightPackageVersion {
  $nodeModulesPath = Get-PlaywrightNodeModulesPath
  if ([string]::IsNullOrWhiteSpace($nodeModulesPath)) {
    return $null
  }

  $packagePath = Join-Path $nodeModulesPath 'playwright/package.json'
  if (-not (Test-Path -LiteralPath $packagePath)) {
    return $null
  }

  try {
    return [string]((Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json).version)
  }
  catch {
    return $null
  }
}

function Get-PlaywrightBrowserPath {
  $browserPath = Get-SilmarilBrowserPath
  if ([string]::IsNullOrWhiteSpace([string]$browserPath)) {
    throw 'Unable to locate a local Chrome/Edge executable for Playwright benchmarking.'
  }

  return [string]$browserPath
}

function Invoke-SilmarilRaw {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$CliArgs
  )

  $output = & $script:ShellPath @script:ShellArgs -File $script:SilmarilEntryScript @CliArgs '--json' 2>&1
  $code = $LASTEXITCODE
  $lines = @($output | ForEach-Object { [string]$_ })
  $line = ($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($line)) {
    throw 'No JSON payload returned from silmaril command.'
  }

  return [ordered]@{
    code    = $code
    payload = ($line | ConvertFrom-Json)
    lines   = $lines
  }
}

function Invoke-SilmarilJson {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$CliArgs
  )

  $result = Invoke-SilmarilRaw -CliArgs $CliArgs
  if ($result.code -ne 0) {
    throw ("Silmaril command failed: " + (($result.payload | ConvertTo-Json -Compress -Depth 20)))
  }

  return $result.payload
}

function Invoke-SilmarilJsonWithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$CliArgs,
    [int]$Attempts = 4,
    [int]$DelayMs = 350
  )

  $lastFailure = $null
  for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
    $result = Invoke-SilmarilRaw -CliArgs $CliArgs
    if ($result.code -eq 0) {
      return $result.payload
    }

    $message = [string]$result.payload.message
    $isTransientExecutionContextIssue = ($message -like '*Cannot find default execution context*')
    if (-not $isTransientExecutionContextIssue -or $attempt -ge $Attempts) {
      throw ("Silmaril command failed: " + (($result.payload | ConvertTo-Json -Compress -Depth 20)))
    }

    $lastFailure = $result.payload
    Start-Sleep -Milliseconds $DelayMs
  }

  if ($null -ne $lastFailure) {
    throw ("Silmaril command failed: " + (($lastFailure | ConvertTo-Json -Compress -Depth 20)))
  }

  throw 'Silmaril command failed without a retryable payload.'
}

function Stop-BenchmarkSilmarilSession {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Session
  )

  if ($null -ne $Session.Pid -and [int]$Session.Pid -gt 0) {
    try {
      Stop-Process -Id ([int]$Session.Pid) -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 250
    }
    catch {
      # Ignore cleanup failures.
    }
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$Session.UserDataDir) -and (Test-Path -LiteralPath ([string]$Session.UserDataDir))) {
    try {
      Remove-Item -LiteralPath ([string]$Session.UserDataDir) -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
      # Ignore cleanup failures.
    }
  }
}

function Start-BenchmarkSilmarilSession {
  param(
    [switch]$Headless
  )

  $port = Get-FreeLoopbackPort
  $userDataDir = Get-SilmarilUserDataDir -Port $port
  $previousHeadless = $null
  $hadHeadless = Test-Path Env:SILMARIL_BROWSER_HEADLESS
  if ($hadHeadless) {
    $previousHeadless = $env:SILMARIL_BROWSER_HEADLESS
  }

  try {
    if ($Headless) {
      $env:SILMARIL_BROWSER_HEADLESS = '1'
    }
    else {
      Remove-Item Env:SILMARIL_BROWSER_HEADLESS -ErrorAction SilentlyContinue
    }

    $startupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $payload = Invoke-SilmarilJson -CliArgs @('openbrowser', '--port', ([string]$port), '--timeout-ms', '20000', '--poll-ms', '250')
    $startupStopwatch.Stop()

    $listenerPid = Get-SilmarilListenerPid -Port $port

    return [pscustomobject]@{
      Port        = $port
      Pid         = $listenerPid
      UserDataDir = $userDataDir
      StartupMs   = (ConvertTo-BenchmarkMilliseconds -Stopwatch $startupStopwatch)
      Payload     = $payload
    }
  }
  finally {
    if ($hadHeadless) {
      $env:SILMARIL_BROWSER_HEADLESS = $previousHeadless
    }
    else {
      Remove-Item Env:SILMARIL_BROWSER_HEADLESS -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-SilmarilBenchmarkTask {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Task,
    [Parameter(Mandatory = $true)]
    [object]$Protocol,
    [ValidateSet('cold', 'warm')]
    [string]$Mode,
    [switch]$Headless
  )

  $steps = Get-BenchmarkTaskSteps -Task $Task -Tool 'silmaril'
  $timeBudgetMs = Get-BenchmarkTimeBudgetMs -Task $Task -Protocol $Protocol
  $commandBudget = Get-BenchmarkCommandBudget -Task $Task -Protocol $Protocol

  $session = $null
  $variables = @{}
  $targetAliases = @{}
  $snapshotByAlias = @{}
  $currentAlias = ''
  $taskStopwatch = $null

  $result = [ordered]@{
    ok                  = $false
    tool                = 'silmaril'
    taskId              = [string]$Task.id
    group               = [string]$Task.group
    mode                = $Mode
    startupMs           = $null
    taskMs              = $null
    wallMs              = $null
    finalUrl            = $null
    error               = $null
    steps               = @()
    transcript          = @()
    variables           = @{}
    commandCount        = 0
    contextRefreshCount = 0
    maxEscalationDepth  = 0
    distinctSurfaces    = @()
    escalationTrace     = @()
    completedStepCount  = 0
    totalStepCount      = @($steps).Count
  }

  try {
    $session = Start-BenchmarkSilmarilSession -Headless:$Headless
    $result.startupMs = [double]$session.StartupMs
    $port = [int]$session.Port

    $taskStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    for ($stepIndex = 0; $stepIndex -lt $steps.Count; $stepIndex += 1) {
      $step = $steps[$stepIndex]
      $stepType = [string]$step.type
      $surface = Get-BenchmarkDefaultSurface -Step $step
      $escalationDepth = Get-BenchmarkEscalationDepth -Protocol $Protocol -Surface $surface
      $countsAsCommand = Get-BenchmarkStepCountsAsCommand -Step $step
      $countsAsRefresh = Get-BenchmarkStepCountsAsRefresh -Step $step
      $targetAlias = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'targetAlias' -Default $currentAlias) -Variables $variables
      $resolvedTargetId = $null
      if (-not [string]::IsNullOrWhiteSpace([string]$targetAlias) -and $targetAliases.ContainsKey([string]$targetAlias)) {
        $resolvedTargetId = [string]$targetAliases[[string]$targetAlias]
      }

      if ($countsAsCommand -and ($result.commandCount + 1) -gt $commandBudget) {
        throw "Command budget exceeded before step $($stepIndex + 1). Budget: $commandBudget"
      }
      if ($taskStopwatch.Elapsed.TotalMilliseconds -gt $timeBudgetMs) {
        throw "Time budget exceeded before step $($stepIndex + 1). Budget: $timeBudgetMs ms"
      }

      $stepRecord = [ordered]@{
        index             = $stepIndex + 1
        type              = $stepType
        targetAlias       = $targetAlias
        surface           = $surface
        escalationDepth   = $escalationDepth
        countsAsCommand   = $countsAsCommand
        countsAsRefresh   = $countsAsRefresh
        ok                = $false
        elapsedMs         = 0.0
        toolCommand       = ''
        commandArgs       = @()
      }

      $stepStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
      try {
        $payload = $null

        switch ($stepType) {
          'navigate' {
            $url = Resolve-BenchmarkTemplateString -Value $step.url -Variables $variables
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 20000)
            $args = @('openurl', $url, '--port', ([string]$port), '--timeout-ms', ([string]$timeoutMs))
            $stepRecord.toolCommand = 'silmaril openurl'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJson -CliArgs $args

            $aliasToStore = if ([string]::IsNullOrWhiteSpace([string]$targetAlias)) { 'default' } else { [string]$targetAlias }
            $targetAliases[$aliasToStore] = [string]$payload.resolvedTargetId
            $currentAlias = $aliasToStore
            $resolvedTargetId = [string]$payload.resolvedTargetId
            $result.finalUrl = [string]$payload.resolvedUrl

            Set-BenchmarkStoredValues -Variables $variables -Payload $payload -SaveAs (Get-BenchmarkPropertyValue -InputObject $step -Name 'saveAs' -Default $null) -SaveFrom (Get-BenchmarkPropertyValue -InputObject $step -Name 'saveFrom' -Default '')
          }
          'switchTarget' {
            if ([string]::IsNullOrWhiteSpace([string]$targetAlias)) {
              throw 'switchTarget requires targetAlias.'
            }
            if (-not $targetAliases.ContainsKey([string]$targetAlias)) {
              throw "Unknown target alias: $targetAlias"
            }
            $currentAlias = [string]$targetAlias
            $resolvedTargetId = [string]$targetAliases[[string]$currentAlias]
            $payload = [pscustomobject]@{
              targetAlias = $currentAlias
              resolvedTargetId = $resolvedTargetId
            }
            $stepRecord.toolCommand = 'benchmark.switchTarget'
          }
          'snapshot' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'snapshot requires a resolved target alias.'
            }
            $coverage = [string](Get-BenchmarkPropertyValue -InputObject $step -Name 'coverage' -Default 'viewport')
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 12000)
            $args = @('snapshot', '--coverage', $coverage, '--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs))
            $stepRecord.toolCommand = 'silmaril snapshot'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args
            Assert-BenchmarkSnapshotExpectation -Payload $payload -Expectation (Get-BenchmarkPropertyValue -InputObject $step -Name 'expect' -Default $null) -ContextLabel ("snapshot step for task " + [string]$Task.id)
            $snapshotByAlias[[string]$targetAlias] = $payload
            Set-BenchmarkStoredValues -Variables $variables -Payload $payload -SaveAs (Get-BenchmarkPropertyValue -InputObject $step -Name 'saveAs' -Default $null) -SaveFrom (Get-BenchmarkPropertyValue -InputObject $step -Name 'saveFrom' -Default '')
          }
          'snapshotFindRef' {
            if ([string]::IsNullOrWhiteSpace([string]$targetAlias)) {
              throw 'snapshotFindRef requires targetAlias.'
            }
            if (-not $snapshotByAlias.ContainsKey([string]$targetAlias)) {
              throw "No snapshot is available for target alias: $targetAlias"
            }
            $snapshot = $snapshotByAlias[[string]$targetAlias]
            $resolvedStep = [pscustomobject]@{
              label            = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'label' -Default $null) -Variables $variables
              labelIncludes    = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'labelIncludes' -Default $null) -Variables $variables
              role             = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'role' -Default $null) -Variables $variables
              kind             = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'kind' -Default $null) -Variables $variables
              tag              = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'tag' -Default $null) -Variables $variables
              selector         = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'selector' -Default $null) -Variables $variables
              selectorIncludes = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'selectorIncludes' -Default $null) -Variables $variables
            }
            $payload = Find-BenchmarkSnapshotRef -Refs @($snapshot.refs) -Step $resolvedStep
            $stepRecord.toolCommand = 'benchmark.snapshotFindRef'
            Set-BenchmarkStoredValues -Variables $variables -Payload $payload -SaveAs (Get-BenchmarkPropertyValue -InputObject $step -Name 'saveAs' -Default $null) -SaveFrom (Get-BenchmarkPropertyValue -InputObject $step -Name 'saveFrom' -Default '') -DefaultSaveFrom 'id'
          }
          'waitFor' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'waitFor requires a resolved target alias.'
            }
            $selector = Resolve-BenchmarkTemplateString -Value $step.selector -Variables $variables
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000)
            $args = @('wait-for', $selector, '--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs), '--poll-ms', '200')
            $stepRecord.toolCommand = 'silmaril wait-for'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args
          }
          'waitForAny' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'waitForAny requires a resolved target alias.'
            }
            $selectors = Resolve-BenchmarkTemplateStringArray -Values @($step.selectors) -Variables $variables
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000)
            $args = @('wait-for-any') + $selectors + @('--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs), '--poll-ms', '200')
            $stepRecord.toolCommand = 'silmaril wait-for-any'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args
          }
          'waitForGone' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'waitForGone requires a resolved target alias.'
            }
            $selector = Resolve-BenchmarkTemplateString -Value $step.selector -Variables $variables
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000)
            $args = @('wait-for-gone', $selector, '--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs), '--poll-ms', '200')
            $stepRecord.toolCommand = 'silmaril wait-for-gone'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args
          }
          'waitForCount' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'waitForCount requires a resolved target alias.'
            }
            $selector = Resolve-BenchmarkTemplateString -Value $step.selector -Variables $variables
            $timeoutMs = [int](Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000) -Variables $variables)
            $minCount = [int](Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'minCount' -Default 1) -Variables $variables)
            $args = @('wait-for-count', $selector, '--min-count', ([string]$minCount), '--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs), '--poll-ms', '200')
            if (Test-BenchmarkProperty -InputObject $step -Name 'root') {
              $args += @('--root', (Resolve-BenchmarkTemplateString -Value $step.root -Variables $variables))
            }
            $stepRecord.toolCommand = 'silmaril wait-for-count'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args
          }
          'waitForVisibleCount' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'waitForVisibleCount requires a resolved target alias.'
            }
            $selector = Resolve-BenchmarkTemplateString -Value $step.selector -Variables $variables
            $timeoutMs = [int](Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000) -Variables $variables)
            $minCount = [int](Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'minCount' -Default 1) -Variables $variables)
            $args = @('wait-for-visible-count', $selector, '--min-count', ([string]$minCount), '--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs), '--poll-ms', '200')
            if (Test-BenchmarkProperty -InputObject $step -Name 'root') {
              $args += @('--root', (Resolve-BenchmarkTemplateString -Value $step.root -Variables $variables))
            }
            $stepRecord.toolCommand = 'silmaril wait-for-visible-count'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args
          }
          'waitUntilJs' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'waitUntilJs requires a resolved target alias.'
            }
            $expression = Resolve-BenchmarkTemplateString -Value $step.expression -Variables $variables
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000)
            $args = @('wait-until-js', $expression, '--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs), '--poll-ms', '200')
            $stepRecord.toolCommand = 'silmaril wait-until-js'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args
            if (Test-BenchmarkProperty -InputObject $payload -Name 'resolvedUrl') {
              $result.finalUrl = [string]$payload.resolvedUrl
            }
          }
          'query' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'query requires a resolved target alias.'
            }
            $selector = Resolve-BenchmarkTemplateString -Value $step.selector -Variables $variables
            $fields = Resolve-BenchmarkTemplateStringArray -Values @($step.fields) -Variables $variables
            $limit = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'limit' -Default 20)
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000)
            $visibleOnly = [bool](Get-BenchmarkPropertyValue -InputObject $step -Name 'visibleOnly' -Default $false)
            $minCount = [int](Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'minCount' -Default 0) -Variables $variables)
            $args = @('query', $selector, '--fields', ($fields -join ','), '--limit', ([string]$limit), '--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs))
            if ($visibleOnly) {
              $args += '--visible-only'
            }
            if ($minCount -gt 0) {
              $args += @('--min-count', ([string]$minCount))
            }
            if (Test-BenchmarkProperty -InputObject $step -Name 'root') {
              $args += @('--root', (Resolve-BenchmarkTemplateString -Value $step.root -Variables $variables))
            }
            $stepRecord.toolCommand = 'silmaril query'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args
            Assert-BenchmarkQueryExpectation -Payload $payload -Expectation (Get-BenchmarkPropertyValue -InputObject $step -Name 'expect' -Default $null) -ContextLabel ("query step for task " + [string]$Task.id)
            Set-BenchmarkStoredValues -Variables $variables -Payload $payload -SaveAs (Get-BenchmarkPropertyValue -InputObject $step -Name 'saveAs' -Default $null) -SaveFrom (Get-BenchmarkPropertyValue -InputObject $step -Name 'saveFrom' -Default '')
          }
          'getText' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'getText requires a resolved target alias.'
            }
            $selector = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'selector' -Default 'body') -Variables $variables
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000)
            $args = @('get-text', $selector, '--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs))
            $stepRecord.toolCommand = 'silmaril get-text'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args

            $expectIncludes = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'expectIncludes' -Default $null) -Variables $variables
            $expectEquals = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'expectEquals' -Default $null) -Variables $variables
            if (-not [string]::IsNullOrWhiteSpace([string]$expectIncludes)) {
              Assert-BenchmarkTextContains -Actual ([string]$payload.text) -Expected ([string]$expectIncludes) -ContextLabel ("getText step for task " + [string]$Task.id)
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$expectEquals)) {
              Assert-BenchmarkTextEquals -Actual ([string]$payload.text) -Expected ([string]$expectEquals) -ContextLabel ("getText step for task " + [string]$Task.id)
            }

            Set-BenchmarkStoredValues -Variables $variables -Payload $payload -SaveAs (Get-BenchmarkPropertyValue -InputObject $step -Name 'saveAs' -Default $null) -SaveFrom (Get-BenchmarkPropertyValue -InputObject $step -Name 'saveFrom' -Default '') -DefaultSaveFrom 'text'
          }
          'type' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'type requires a resolved target alias.'
            }
            $selector = Resolve-BenchmarkTemplateString -Value $step.selector -Variables $variables
            $text = Resolve-BenchmarkTemplateString -Value $step.text -Variables $variables
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000)
            $args = @('type', $selector, $text, '--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs), '--yes')
            $stepRecord.toolCommand = 'silmaril type'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args
          }
          'click' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'click requires a resolved target alias.'
            }
            $selector = Resolve-BenchmarkTemplateString -Value $step.selector -Variables $variables
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000)
            $args = @('click', $selector, '--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs), '--yes')
            $stepRecord.toolCommand = 'silmaril click'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args
            if (Test-BenchmarkProperty -InputObject $payload -Name 'resolvedUrl') {
              $result.finalUrl = [string]$payload.resolvedUrl
            }
          }
          'scroll' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'scroll requires a resolved target alias.'
            }
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000)
            $args = @('scroll')

            if (Test-BenchmarkProperty -InputObject $step -Name 'selector') {
              $args += (Resolve-BenchmarkTemplateString -Value $step.selector -Variables $variables)
            }
            if (Test-BenchmarkProperty -InputObject $step -Name 'container') {
              $args += @('--container', (Resolve-BenchmarkTemplateString -Value $step.container -Variables $variables))
            }
            if (Test-BenchmarkProperty -InputObject $step -Name 'x') { $args += @('--x', ([string]$step.x)) }
            if (Test-BenchmarkProperty -InputObject $step -Name 'y') { $args += @('--y', ([string]$step.y)) }
            if (Test-BenchmarkProperty -InputObject $step -Name 'left') { $args += @('--left', ([string]$step.left)) }
            if (Test-BenchmarkProperty -InputObject $step -Name 'top') { $args += @('--top', ([string]$step.top)) }
            if (Test-BenchmarkProperty -InputObject $step -Name 'behavior') { $args += @('--behavior', ([string]$step.behavior)) }
            if (Test-BenchmarkProperty -InputObject $step -Name 'block') { $args += @('--block', ([string]$step.block)) }
            if (Test-BenchmarkProperty -InputObject $step -Name 'inline') { $args += @('--inline', ([string]$step.inline)) }
            $args += @('--port', ([string]$port), '--target-id', $resolvedTargetId, '--timeout-ms', ([string]$timeoutMs))
            $stepRecord.toolCommand = 'silmaril scroll'
            $stepRecord.commandArgs = $args
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs $args
          }
          'assertUrlIncludes' {
            if ([string]::IsNullOrWhiteSpace([string]$resolvedTargetId)) {
              throw 'assertUrlIncludes requires a resolved target alias.'
            }
            $expectedValue = Resolve-BenchmarkTemplateString -Value (Get-BenchmarkPropertyValue -InputObject $step -Name 'includes' -Default '') -Variables $variables
            $timeoutMs = [int](Get-BenchmarkPropertyValue -InputObject $step -Name 'timeoutMs' -Default 15000)
            $args = @('list-urls', '--port', ([string]$port))
            $stepRecord.toolCommand = 'silmaril list-urls(url-check)'
            $stepRecord.commandArgs = $args
            $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
            while ([DateTime]::UtcNow -lt $deadline) {
              $listPayload = Invoke-SilmarilJson -CliArgs $args
              $targetRow = @($listPayload.targets | Where-Object { [string]$_.id -eq $resolvedTargetId } | Select-Object -First 1)[0]
              if ($null -ne $targetRow -and -not [string]::IsNullOrWhiteSpace([string]$targetRow.url) -and ([string]$targetRow.url).Contains($expectedValue)) {
                $payload = [pscustomobject]@{
                  resolvedUrl = [string]$targetRow.url
                  resolvedTargetId = $resolvedTargetId
                }
                $result.finalUrl = [string]$targetRow.url
                break
              }

              Start-Sleep -Milliseconds 250
            }

            if ($null -eq $payload) {
              throw "Timed out waiting for target URL to include '$expectedValue'."
            }
          }
          default {
            throw "Unsupported benchmark step type for Silmaril: $stepType"
          }
        }

        $stepRecord.ok = $true
        $stepRecord.details = $payload
        if ($countsAsCommand) {
          $result.commandCount += 1
        }
        if ($countsAsRefresh) {
          $result.contextRefreshCount += 1
        }
        if ($escalationDepth -gt $result.maxEscalationDepth) {
          $result.maxEscalationDepth = $escalationDepth
        }
        if ($surface -and -not ($result.distinctSurfaces -contains $surface)) {
          $result.distinctSurfaces += $surface
        }
        if ($escalationDepth -gt 0) {
          $result.escalationTrace += [pscustomobject]@{
            index = $stepRecord.index
            type = $stepType
            surface = $surface
            escalationDepth = $escalationDepth
          }
        }
      }
      catch {
        $stepRecord.ok = $false
        $stepRecord.error = [string]$_.Exception.Message
        throw
      }
      finally {
        $stepStopwatch.Stop()
        $stepRecord.elapsedMs = (ConvertTo-BenchmarkMilliseconds -Stopwatch $stepStopwatch)
        $result.steps += [pscustomobject]$stepRecord
        $result.transcript += [pscustomobject]$stepRecord
        if ($stepRecord.ok) {
          $result.completedStepCount += 1
        }
      }
    }

    $taskStopwatch.Stop()
    $result.ok = $true
    $result.taskMs = (ConvertTo-BenchmarkMilliseconds -Stopwatch $taskStopwatch)
    $result.wallMs = if ($Mode -eq 'cold') { [Math]::Round(([double]$result.startupMs + [double]$result.taskMs), 3) } else { [double]$result.taskMs }
  }
  catch {
    $result.ok = $false
    $result.error = [string]$_.Exception.Message
    if ($null -eq $result.taskMs) {
      if ($null -ne $taskStopwatch) {
        $taskStopwatch.Stop()
        $result.taskMs = (ConvertTo-BenchmarkMilliseconds -Stopwatch $taskStopwatch)
      }
      else {
        $result.taskMs = 0.0
      }
    }
    $result.wallMs = if ($Mode -eq 'cold' -and $null -ne $result.startupMs) { [Math]::Round(([double]$result.startupMs + [double]$result.taskMs), 3) } else { [double]$result.taskMs }
  }
  finally {
    $result.variables = $variables
    if ($null -ne $session) {
      Stop-BenchmarkSilmarilSession -Session $session
    }
  }

  return [pscustomobject]$result
}

function Invoke-PlaywrightBenchmarkTask {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Task,
    [Parameter(Mandatory = $true)]
    [object]$Protocol,
    [ValidateSet('cold', 'warm')]
    [string]$Mode,
    [switch]$Headless
  )

  $nodeModulesPath = Get-PlaywrightNodeModulesPath
  if ([string]::IsNullOrWhiteSpace($nodeModulesPath)) {
    throw 'Unable to locate node_modules for Playwright.'
  }

  $browserPath = Get-PlaywrightBrowserPath
  $previousNodePath = $null
  $hadNodePath = Test-Path Env:NODE_PATH
  if ($hadNodePath) {
    $previousNodePath = $env:NODE_PATH
  }

  try {
    $env:NODE_PATH = $nodeModulesPath
    $headlessValue = if ($Headless) { '1' } else { '0' }
    $commandArgs = @(
      $script:PlaywrightRunner
      '--task-file', $script:TasksFile
      '--task-id', ([string]$Task.id)
      '--mode', $Mode
      '--playwright-module-path', (Join-Path $nodeModulesPath 'playwright')
      '--browser-path', $browserPath
      '--headless', $headlessValue
    )

    $output = & node @commandArgs 2>&1
    $line = (@($output | ForEach-Object { [string]$_ }) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($line)) {
      throw 'Playwright runner returned no JSON payload.'
    }

    return ($line | ConvertFrom-Json)
  }
  finally {
    if ($hadNodePath) {
      $env:NODE_PATH = $previousNodePath
    }
    else {
      Remove-Item Env:NODE_PATH -ErrorAction SilentlyContinue
    }
  }
}

function Get-BenchmarkEnvironmentMetadata {
  $manifest = Get-BenchmarkTaskManifest
  $gitCommit = $null
  try {
    $gitCommit = (& git -C $script:RepoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
  }
  catch {
    $gitCommit = $null
  }

  return [ordered]@{
    generatedAtUtc    = [DateTime]::UtcNow.ToString('o')
    repoRoot          = $script:RepoRoot
    tasksFile         = $script:TasksFile
    manifestVersion   = [int]$manifest.version
    playwrightVersion = Get-PlaywrightPackageVersion
    browserPath       = Get-PlaywrightBrowserPath
    gitCommit         = $gitCommit
    machineName       = [Environment]::MachineName
    osVersion         = [Environment]::OSVersion.VersionString
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    nodeVersion       = (& node --version 2>$null | Select-Object -First 1)
  }
}
