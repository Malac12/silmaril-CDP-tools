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

function Get-BenchmarkTasks {
  param(
    [string[]]$TaskId = @(),
    [ValidateSet('all', 'micro', 'flow')]
    [string]$Tier = 'all'
  )

  $manifest = Get-BenchmarkTaskManifest
  $tasks = @($manifest.tasks)
  if ($Tier -ne 'all') {
    $tasks = @($tasks | Where-Object { [string]$_.tier -eq $Tier })
  }

  if ($TaskId -and $TaskId.Count -gt 0) {
    $requested = @($TaskId | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $tasks = @($tasks | Where-Object { $requested -contains [string]$_.id })
    foreach ($id in $requested) {
      if (-not (@($tasks | Where-Object { [string]$_.id -eq $id }).Count)) {
        throw "Unknown benchmark task id: $id"
      }
    }
  }

  return @($tasks)
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

function Invoke-SilmarilBenchmarkTask {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Task,
    [ValidateSet('cold', 'warm')]
    [string]$Mode,
    [switch]$Headless
  )

  $session = $null
  $result = [ordered]@{
    ok         = $false
    tool       = 'silmaril'
    taskId     = [string]$Task.id
    tier       = [string]$Task.tier
    mode       = $Mode
    startupMs  = $null
    taskMs     = $null
    wallMs     = $null
    finalUrl   = $null
    error      = $null
    steps      = @()
  }

  try {
    $session = Start-BenchmarkSilmarilSession -Headless:$Headless
    $result.startupMs = [double]$session.StartupMs
    $port = [int]$session.Port
    $targetId = $null

    $taskStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($step in @($Task.steps)) {
      $stepRecord = [ordered]@{
        type      = [string]$step.type
        selector  = if ($step.PSObject.Properties.Name -contains 'selector') { [string]$step.selector } else { $null }
        ok        = $false
        elapsedMs = 0.0
      }

      $stepStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
      try {
        switch ([string]$step.type) {
          'navigate' {
            $payload = Invoke-SilmarilJson -CliArgs @('openurl', ([string]$step.url), '--port', ([string]$port), '--timeout-ms', ([string]$step.timeoutMs))
            $targetId = [string]$payload.resolvedTargetId
            $result.finalUrl = [string]$payload.resolvedUrl
            $stepRecord.details = [ordered]@{
              resolvedTargetId = $targetId
              resolvedUrl = $result.finalUrl
            }
          }
          'waitFor' {
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs @('wait-for', ([string]$step.selector), '--port', ([string]$port), '--target-id', ([string]$targetId), '--timeout-ms', ([string]$step.timeoutMs), '--poll-ms', '200')
            $stepRecord.details = [ordered]@{
              resolvedUrl = [string]$payload.resolvedUrl
            }
          }
          'waitForGone' {
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs @('wait-for-gone', ([string]$step.selector), '--port', ([string]$port), '--target-id', ([string]$targetId), '--timeout-ms', ([string]$step.timeoutMs), '--poll-ms', '200')
            $stepRecord.details = [ordered]@{
              resolvedUrl = [string]$payload.resolvedUrl
            }
          }
          'waitUntilJs' {
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs @('wait-until-js', ([string]$step.expression), '--port', ([string]$port), '--target-id', ([string]$targetId), '--timeout-ms', ([string]$step.timeoutMs), '--poll-ms', '200')
            $stepRecord.details = [ordered]@{
              resolvedUrl = [string]$payload.resolvedUrl
            }
            $result.finalUrl = [string]$payload.resolvedUrl
          }
          'query' {
            $fieldsCsv = (@($step.fields) | ForEach-Object { [string]$_ }) -join ','
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs @('query', ([string]$step.selector), '--fields', $fieldsCsv, '--limit', ([string]$step.limit), '--port', ([string]$port), '--target-id', ([string]$targetId), '--timeout-ms', ([string]$step.timeoutMs))
            Assert-BenchmarkQueryExpectation -Payload $payload -Expectation $step.expect -ContextLabel ("query step for task " + [string]$Task.id)
            $stepRecord.details = [ordered]@{
              returnedCount = [int]$payload.returnedCount
              rows = $payload.rows
            }
          }
          'type' {
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs @('type', ([string]$step.selector), ([string]$step.text), '--port', ([string]$port), '--target-id', ([string]$targetId), '--timeout-ms', ([string]$step.timeoutMs), '--yes')
            $stepRecord.details = [ordered]@{
              bytes = [int64]$payload.bytes
            }
          }
          'click' {
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs @('click', ([string]$step.selector), '--port', ([string]$port), '--target-id', ([string]$targetId), '--timeout-ms', ([string]$step.timeoutMs), '--yes')
            $result.finalUrl = [string]$payload.resolvedUrl
            $stepRecord.details = [ordered]@{
              resolvedUrl = [string]$payload.resolvedUrl
            }
          }
          'assertTextIncludes' {
            $selector = if ($step.PSObject.Properties.Name -contains 'selector' -and -not [string]::IsNullOrWhiteSpace([string]$step.selector)) { [string]$step.selector } else { 'body' }
            $payload = Invoke-SilmarilJsonWithRetry -CliArgs @('get-text', $selector, '--port', ([string]$port), '--target-id', ([string]$targetId), '--timeout-ms', ([string]$step.timeoutMs))
            Assert-BenchmarkTextContains -Actual ([string]$payload.text) -Expected ([string]$step.includes) -ContextLabel ("text assertion for task " + [string]$Task.id)
            $stepRecord.details = [ordered]@{
              textLength = ([string]$payload.text).Length
            }
          }
          default {
            throw "Unsupported benchmark step type for Silmaril: $([string]$step.type)"
          }
        }

        $stepRecord.ok = $true
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
      $result.taskMs = 0.0
    }
    $result.wallMs = if ($Mode -eq 'cold' -and $null -ne $result.startupMs) { [Math]::Round(([double]$result.startupMs + [double]$result.taskMs), 3) } else { [double]$result.taskMs }
  }
  finally {
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
    $headlessValue = '0'
    if ($Headless) {
      $headlessValue = '1'
    }
    $commandArgs = @(
      $script:PlaywrightRunner
      '--task-file', $script:TasksFile
      '--task-id', ([string]$Task.id)
      '--mode', $Mode
      '--browser-path', $browserPath
      '--headless', $headlessValue
    )

    $output = & node @commandArgs 2>&1
    $code = $LASTEXITCODE
    $lines = @($output | ForEach-Object { [string]$_ })
    $line = ($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
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
    playwrightVersion = Get-PlaywrightPackageVersion
    browserPath       = Get-PlaywrightBrowserPath
    gitCommit         = $gitCommit
    machineName       = [Environment]::MachineName
    osVersion         = [Environment]::OSVersion.VersionString
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    nodeVersion       = (& node --version 2>$null | Select-Object -First 1)
  }
}
