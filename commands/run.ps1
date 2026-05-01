param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1")

if (-not $RemainingArgs) {
  $RemainingArgs = @()
}

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout -AllowPoll
$RemainingArgs = @($common.RemainingArgs)

$defaultPort = [int]$common.Port
$defaultTargetId = [string]$common.TargetId
$defaultUrlMatch = [string]$common.UrlMatch
$defaultUrlContains = [string]$common.UrlContains
$defaultTitleMatch = [string]$common.TitleMatch
$defaultTitleContains = [string]$common.TitleContains
$defaultTimeoutMs = [int]$common.TimeoutMs
$defaultPollMs = [int]$common.PollMs

$flowPath = $null
$artifactsDir = $null

$i = 0
while ($i -lt $RemainingArgs.Count) {
  $arg = [string]$RemainingArgs[$i]
  $argLower = $arg.ToLowerInvariant()

  switch ($argLower) {
    "--artifacts-dir" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "run --artifacts-dir requires a path."
      }
      $artifactsDir = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    default {
      if ($arg.StartsWith("--")) {
        throw "Unsupported flag '$arg' for run. Supported flags: --artifacts-dir, --port, --page-id/--target-id, --url-match, --url-contains, --title-match, --title-contains, --timeout-ms, --poll-ms"
      }

      if ($null -ne $flowPath) {
        throw "run accepts exactly one flow file path."
      }

      $flowPath = $arg
      $i += 1
    }
  }
}

if ([string]::IsNullOrWhiteSpace($flowPath)) {
  throw "run requires a flow JSON path."
}

$flowLoaded = Read-SilmarilTextFile -Path $flowPath -Label "Flow" -MaxBytes 2097152
$flowFile = [string]$flowLoaded.path

$flow = $null
try {
  $flow = $flowLoaded.content | ConvertFrom-Json
}
catch {
  throw "Failed to parse flow JSON: $flowFile"
}

if (-not $flow) {
  throw "Flow JSON is empty: $flowFile"
}

$settings = $null
$flowProps = @(Get-SilmarilPropertyNames -InputObject $flow)
if ($flowProps -contains "settings") {
  $settings = $flow.settings
}

$steps = @()
if ($flowProps -contains "steps" -and $null -ne $flow.steps) {
  $steps = @($flow.steps)
}
if ($steps.Count -lt 1) {
  throw "Flow must include a non-empty steps array."
}

function Get-SilmarilOptionalValue {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Default = $null
  )

  if ($null -eq $Object) {
    return $Default
  }

  $props = @(Get-SilmarilPropertyNames -InputObject $Object)
  if ($props -contains $Name) {
    $value = $Object.$Name
    if ($null -ne $value) {
      return $value
    }
  }

  return $Default
}

$defaults = [ordered]@{
  port         = $defaultPort
  targetId     = $defaultTargetId
  urlMatch     = $defaultUrlMatch
  urlContains  = $defaultUrlContains
  titleMatch   = $defaultTitleMatch
  titleContains = $defaultTitleContains
  timeoutMs    = $defaultTimeoutMs
  pollMs       = $defaultPollMs
  retries      = 0
  retryDelayMs = 300
}

if ($null -ne $settings) {
  $defaults.port = [int](Get-SilmarilOptionalValue -Object $settings -Name "port" -Default $defaults.port)
  $defaults.targetId = [string](Get-SilmarilOptionalValue -Object $settings -Name "targetId" -Default $defaults.targetId)
  $settingsPageId = [string](Get-SilmarilOptionalValue -Object $settings -Name "pageId" -Default "")
  if (-not [string]::IsNullOrWhiteSpace($settingsPageId)) {
    $defaults.targetId = $settingsPageId
  }
  $defaults.urlMatch = [string](Get-SilmarilOptionalValue -Object $settings -Name "urlMatch" -Default $defaults.urlMatch)
  $defaults.urlContains = [string](Get-SilmarilOptionalValue -Object $settings -Name "urlContains" -Default $defaults.urlContains)
  $defaults.titleMatch = [string](Get-SilmarilOptionalValue -Object $settings -Name "titleMatch" -Default $defaults.titleMatch)
  $defaults.titleContains = [string](Get-SilmarilOptionalValue -Object $settings -Name "titleContains" -Default $defaults.titleContains)
  $defaults.timeoutMs = [int](Get-SilmarilOptionalValue -Object $settings -Name "timeoutMs" -Default $defaults.timeoutMs)
  $defaults.pollMs = [int](Get-SilmarilOptionalValue -Object $settings -Name "pollMs" -Default $defaults.pollMs)
  $defaults.retries = [int](Get-SilmarilOptionalValue -Object $settings -Name "retries" -Default $defaults.retries)
  $defaults.retryDelayMs = [int](Get-SilmarilOptionalValue -Object $settings -Name "retryDelayMs" -Default $defaults.retryDelayMs)

  if ([string]::IsNullOrWhiteSpace($artifactsDir)) {
    $settingsArtifacts = [string](Get-SilmarilOptionalValue -Object $settings -Name "artifactsDir" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($settingsArtifacts)) {
      $artifactsDir = $settingsArtifacts
    }
  }
}

if ($defaults.retries -lt 0) {
  throw "settings.retries must be >= 0."
}
if ($defaults.retryDelayMs -lt 0) {
  throw "settings.retryDelayMs must be >= 0."
}
if ($defaults.timeoutMs -lt 100) {
  throw "settings.timeoutMs must be >= 100."
}
if ($defaults.pollMs -lt 50) {
  throw "settings.pollMs must be >= 50."
}
$defaultTargetSelectorCount = 0
foreach ($candidate in @($defaults.targetId, $defaults.urlMatch, $defaults.urlContains, $defaults.titleMatch, $defaults.titleContains)) {
  if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
    $defaultTargetSelectorCount += 1
  }
}
if ($defaultTargetSelectorCount -gt 1) {
  throw "Flow defaults can set only one page target selector: targetId/pageId, urlMatch, urlContains, titleMatch, or titleContains."
}

if ([string]::IsNullOrWhiteSpace($artifactsDir)) {
  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $artifactsDir = Join-Path -Path $scriptRoot -ChildPath ("runs/run-" + $timestamp)
}

New-Item -Path $artifactsDir -ItemType Directory -Force | Out-Null
$stepsDir = Join-Path -Path $artifactsDir -ChildPath "steps"
New-Item -Path $stepsDir -ItemType Directory -Force | Out-Null

$entryScript = Join-Path -Path $scriptRoot -ChildPath "silmaril.ps1"

function Invoke-SilmarilJsonCommand {
  param(
    [string]$CommandName,
    [string[]]$CommandArgs
  )

  $shellPath = Get-SilmarilPowerShellPath
  $args = @("-NoProfile")
  if (Test-SilmarilWindowsPlatform) {
    $args += @("-ExecutionPolicy", "Bypass")
  }
  $args += @("-File", $entryScript, $CommandName)

  if ($CommandArgs) {
    $args += @($CommandArgs)
  }

  $args += "--json"

  $rawOutput = & $shellPath @args 2>&1
  $exitCode = $LASTEXITCODE

  $lines = @()
  foreach ($line in @($rawOutput)) {
    $lines += [string]$line
  }

  $jsonLine = $null
  for ($idx = $lines.Count - 1; $idx -ge 0; $idx--) {
    $candidate = [string]$lines[$idx]
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }

    $trim = $candidate.Trim()
    if ($trim.StartsWith("{") -and $trim.EndsWith("}")) {
      $jsonLine = $trim
      break
    }
  }

  $payload = $null
  if (-not [string]::IsNullOrWhiteSpace($jsonLine)) {
    try {
      $payload = $jsonLine | ConvertFrom-Json
    }
    catch {
      $payload = $null
    }
  }

  if ($null -eq $payload) {
    $message = "Command '$CommandName' returned non-JSON output."
    if ($lines.Count -gt 0) {
      $message = "Command '$CommandName' returned non-JSON output: $($lines[$lines.Count - 1])"
    }

    $payload = Get-SilmarilErrorContract -Command $CommandName -Message $message
  }

  return [ordered]@{
    exitCode = $exitCode
    lines    = $lines
    payload  = $payload
  }
}

function Add-SilmarilCommonStepFlags {
  param(
    [System.Collections.ArrayList]$Args,
    [int]$Port,
    [string]$TargetId,
    [string]$UrlMatch,
    [string]$UrlContains,
    [string]$TitleMatch,
    [string]$TitleContains,
    [int]$TimeoutMs,
    [int]$PollMs,
    [switch]$IncludePoll
  )

  [void]$Args.Add("--port")
  [void]$Args.Add([string]$Port)

  if (-not [string]::IsNullOrWhiteSpace($TargetId)) {
    [void]$Args.Add("--page-id")
    [void]$Args.Add($TargetId)
  }
  elseif (-not [string]::IsNullOrWhiteSpace($UrlMatch)) {
    [void]$Args.Add("--url-match")
    [void]$Args.Add($UrlMatch)
  }
  elseif (-not [string]::IsNullOrWhiteSpace($UrlContains)) {
    [void]$Args.Add("--url-contains")
    [void]$Args.Add($UrlContains)
  }
  elseif (-not [string]::IsNullOrWhiteSpace($TitleMatch)) {
    [void]$Args.Add("--title-match")
    [void]$Args.Add($TitleMatch)
  }
  elseif (-not [string]::IsNullOrWhiteSpace($TitleContains)) {
    [void]$Args.Add("--title-contains")
    [void]$Args.Add($TitleContains)
  }

  [void]$Args.Add("--timeout-ms")
  [void]$Args.Add([string]$TimeoutMs)

  if ($IncludePoll) {
    [void]$Args.Add("--poll-ms")
    [void]$Args.Add([string]$PollMs)
  }
}

$runLog = New-Object System.Collections.Generic.List[string]
$stepResults = New-Object System.Collections.Generic.List[object]
$startedAt = (Get-Date).ToString("o")
$runName = [string](Get-SilmarilOptionalValue -Object $flow -Name "name" -Default "flow")
$finalSnapshotPort = [int]$defaults.port
$finalSnapshotTargetId = [string]$defaults.targetId
$finalSnapshotUrlMatch = [string]$defaults.urlMatch
$finalSnapshotUrlContains = [string]$defaults.urlContains
$finalSnapshotTitleMatch = [string]$defaults.titleMatch
$finalSnapshotTitleContains = [string]$defaults.titleContains

for ($stepIndex = 0; $stepIndex -lt $steps.Count; $stepIndex++) {
  $step = $steps[$stepIndex]
  if ($null -eq $step) {
    throw "Step $stepIndex is null."
  }

  $actionRaw = [string](Get-SilmarilOptionalValue -Object $step -Name "action" -Default "")
  if ([string]::IsNullOrWhiteSpace($actionRaw)) {
    throw "Step $stepIndex is missing action."
  }

  $action = $actionRaw.ToLowerInvariant()
  $stepId = [string](Get-SilmarilOptionalValue -Object $step -Name "id" -Default ("step-" + ($stepIndex + 1)))

  $stepPort = [int](Get-SilmarilOptionalValue -Object $step -Name "port" -Default $defaults.port)
  $stepTargetId = [string](Get-SilmarilOptionalValue -Object $step -Name "targetId" -Default $defaults.targetId)
  $stepPageId = [string](Get-SilmarilOptionalValue -Object $step -Name "pageId" -Default "")
  if (-not [string]::IsNullOrWhiteSpace($stepPageId)) {
    $stepTargetId = $stepPageId
  }
  $stepUrlMatch = [string](Get-SilmarilOptionalValue -Object $step -Name "urlMatch" -Default $defaults.urlMatch)
  $stepUrlContains = [string](Get-SilmarilOptionalValue -Object $step -Name "urlContains" -Default $defaults.urlContains)
  $stepTitleMatch = [string](Get-SilmarilOptionalValue -Object $step -Name "titleMatch" -Default $defaults.titleMatch)
  $stepTitleContains = [string](Get-SilmarilOptionalValue -Object $step -Name "titleContains" -Default $defaults.titleContains)
  $stepTimeoutMs = [int](Get-SilmarilOptionalValue -Object $step -Name "timeoutMs" -Default $defaults.timeoutMs)
  $stepPollMs = [int](Get-SilmarilOptionalValue -Object $step -Name "pollMs" -Default $defaults.pollMs)
  $stepRetries = [int](Get-SilmarilOptionalValue -Object $step -Name "retries" -Default $defaults.retries)
  $stepRetryDelayMs = [int](Get-SilmarilOptionalValue -Object $step -Name "retryDelayMs" -Default $defaults.retryDelayMs)

  if ($stepRetries -lt 0) {
    throw "Step '$stepId' retries must be >= 0."
  }
  if ($stepRetryDelayMs -lt 0) {
    throw "Step '$stepId' retryDelayMs must be >= 0."
  }
  if ($stepTimeoutMs -lt 100) {
    throw "Step '$stepId' timeoutMs must be >= 100."
  }
  if ($stepPollMs -lt 50) {
    throw "Step '$stepId' pollMs must be >= 50."
  }
  $stepTargetSelectorCount = 0
  foreach ($candidate in @($stepTargetId, $stepUrlMatch, $stepUrlContains, $stepTitleMatch, $stepTitleContains)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
      $stepTargetSelectorCount += 1
    }
  }
  if ($stepTargetSelectorCount -gt 1) {
    throw "Step '$stepId' can set only one page target selector: targetId/pageId, urlMatch, urlContains, titleMatch, or titleContains."
  }

  $commandName = $null
  $commandArgsList = New-Object System.Collections.ArrayList
  $includePoll = $false

  switch ($action) {
    "openurl" {
      $url = [string](Get-SilmarilOptionalValue -Object $step -Name "url" -Default "")
      if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Step '$stepId' action openUrl requires url."
      }

      $commandName = "openurl"
      [void]$commandArgsList.Add($url)
      Add-SilmarilCommonStepFlags -Args $commandArgsList -Port $stepPort -TargetId "" -UrlMatch "" -UrlContains "" -TitleMatch "" -TitleContains "" -TimeoutMs $stepTimeoutMs -PollMs $stepPollMs
    }
    "openbrowser" {
      $commandName = "openbrowser"
      $includePoll = $true
      Add-SilmarilCommonStepFlags -Args $commandArgsList -Port $stepPort -TargetId "" -UrlMatch "" -UrlContains "" -TitleMatch "" -TitleContains "" -TimeoutMs $stepTimeoutMs -PollMs $stepPollMs -IncludePoll
    }
    "wait-for" {
      $selector = [string](Get-SilmarilOptionalValue -Object $step -Name "selector" -Default "")
      if ([string]::IsNullOrWhiteSpace($selector)) {
        throw "Step '$stepId' action wait-for requires selector."
      }

      $commandName = "wait-for"
      [void]$commandArgsList.Add($selector)
      $includePoll = $true
      Add-SilmarilCommonStepFlags -Args $commandArgsList -Port $stepPort -TargetId $stepTargetId -UrlMatch $stepUrlMatch -UrlContains $stepUrlContains -TitleMatch $stepTitleMatch -TitleContains $stepTitleContains -TimeoutMs $stepTimeoutMs -PollMs $stepPollMs -IncludePoll
    }
    "click" {
      $selector = [string](Get-SilmarilOptionalValue -Object $step -Name "selector" -Default "")
      if ([string]::IsNullOrWhiteSpace($selector)) {
        throw "Step '$stepId' action click requires selector."
      }

      $commandName = "click"
      [void]$commandArgsList.Add($selector)
      [void]$commandArgsList.Add("--yes")
      Add-SilmarilCommonStepFlags -Args $commandArgsList -Port $stepPort -TargetId $stepTargetId -UrlMatch $stepUrlMatch -UrlContains $stepUrlContains -TitleMatch $stepTitleMatch -TitleContains $stepTitleContains -TimeoutMs $stepTimeoutMs -PollMs $stepPollMs
    }
    "query" {
      $selector = [string](Get-SilmarilOptionalValue -Object $step -Name "selector" -Default "")
      if ([string]::IsNullOrWhiteSpace($selector)) {
        throw "Step '$stepId' action query requires selector."
      }

      $commandName = "query"
      [void]$commandArgsList.Add($selector)

      $fields = [string](Get-SilmarilOptionalValue -Object $step -Name "fields" -Default "")
      if (-not [string]::IsNullOrWhiteSpace($fields)) {
        [void]$commandArgsList.Add("--fields")
        [void]$commandArgsList.Add($fields)
      }

      $limitRaw = Get-SilmarilOptionalValue -Object $step -Name "limit" -Default $null
      if ($null -ne $limitRaw) {
        [void]$commandArgsList.Add("--limit")
        [void]$commandArgsList.Add([string]$limitRaw)
      }

      Add-SilmarilCommonStepFlags -Args $commandArgsList -Port $stepPort -TargetId $stepTargetId -UrlMatch $stepUrlMatch -UrlContains $stepUrlContains -TitleMatch $stepTitleMatch -TitleContains $stepTitleContains -TimeoutMs $stepTimeoutMs -PollMs $stepPollMs
    }
    default {
      throw "Unsupported run step action '$actionRaw'. Supported actions: openbrowser, openUrl, wait-for, click, query"
    }
  }

  $maxAttempts = $stepRetries + 1
  $attempt = 0
  $stepSuccess = $false
  $lastPayload = $null

  while ($attempt -lt $maxAttempts) {
    $attempt += 1
    $invocation = Invoke-SilmarilJsonCommand -CommandName $commandName -CommandArgs @($commandArgsList)
    $payload = $invocation.payload
    $lastPayload = $payload

    $stepLog = "step=$stepId action=$action attempt=$attempt ok=$($payload.ok)"
    $runLog.Add($stepLog)

    if ($payload.ok) {
      $stepSuccess = $true
      break
    }

    if ($attempt -lt $maxAttempts -and $stepRetryDelayMs -gt 0) {
      Start-Sleep -Milliseconds $stepRetryDelayMs
    }
  }

  $stepFileName = "{0:D2}-{1}.json" -f ($stepIndex + 1), $action.Replace("/", "-")
  $stepPath = Join-Path -Path $stepsDir -ChildPath $stepFileName

  $stepRecord = [ordered]@{
    id          = $stepId
    action      = $action
    command     = $commandName
    args        = @($commandArgsList)
    attempts    = $attempt
    success     = $stepSuccess
    payload     = $lastPayload
    port        = $stepPort
    targetId    = $stepTargetId
    urlMatch    = $stepUrlMatch
    urlContains = $stepUrlContains
    titleMatch  = $stepTitleMatch
    titleContains = $stepTitleContains
    timeoutMs   = $stepTimeoutMs
    pollMs      = $stepPollMs
    retries     = $stepRetries
    retryDelayMs = $stepRetryDelayMs
  }

  Write-SilmarilJson -Value $stepRecord -Depth 30 | Set-Content -LiteralPath $stepPath -Encoding UTF8
  $stepResults.Add($stepRecord)

  if (-not $stepSuccess) {
    $message = [string](Get-SilmarilOptionalValue -Object $lastPayload -Name "message" -Default "Step failed")
    throw "Run failed at step '$stepId' ($action): $message"
  }

  $finalSnapshotPort = $stepPort
  $finalSnapshotTargetId = $stepTargetId
  $finalSnapshotUrlMatch = $stepUrlMatch
  $finalSnapshotUrlContains = $stepUrlContains
  $finalSnapshotTitleMatch = $stepTitleMatch
  $finalSnapshotTitleContains = $stepTitleContains
}

$finalDomArgs = New-Object System.Collections.ArrayList
Add-SilmarilCommonStepFlags -Args $finalDomArgs -Port $finalSnapshotPort -TargetId $finalSnapshotTargetId -UrlMatch $finalSnapshotUrlMatch -UrlContains $finalSnapshotUrlContains -TitleMatch $finalSnapshotTitleMatch -TitleContains $finalSnapshotTitleContains -TimeoutMs $defaults.timeoutMs -PollMs $defaults.pollMs
$domResult = Invoke-SilmarilJsonCommand -CommandName "get-dom" -CommandArgs @($finalDomArgs)

if ($domResult.payload.ok) {
  $domHtml = [string](Get-SilmarilOptionalValue -Object $domResult.payload -Name "html" -Default "")
  if (-not [string]::IsNullOrWhiteSpace($domHtml)) {
    $domPath = Join-Path -Path $artifactsDir -ChildPath "final-dom.html"
    Set-Content -LiteralPath $domPath -Value $domHtml -Encoding UTF8
    $runLog.Add("saved final-dom.html")
  }
}

$endedAt = (Get-Date).ToString("o")
$summary = [ordered]@{
  ok            = $true
  command       = "run"
  runName       = $runName
  flowFile      = $flowFile
  artifactsDir  = $artifactsDir
  startedAt     = $startedAt
  endedAt       = $endedAt
  stepsTotal    = $stepResults.Count
  stepsSucceeded = @($stepResults | Where-Object { $_.success }).Count
  defaults      = $defaults
}

$summaryPath = Join-Path -Path $artifactsDir -ChildPath "summary.json"
Write-SilmarilJson -Value $summary -Depth 30 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

$logPath = Join-Path -Path $artifactsDir -ChildPath "run.log"
$runLog | Set-Content -LiteralPath $logPath -Encoding UTF8

Write-SilmarilCommandResult -Command "run" -Text "Run completed: $($stepResults.Count) step(s). Artifacts: $artifactsDir" -Data @{
  flowFile      = $flowFile
  artifactsDir  = $artifactsDir
  stepsTotal    = $stepResults.Count
  summaryPath   = $summaryPath
  logPath       = $logPath
}
