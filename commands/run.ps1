param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if (-not $RemainingArgs) {
  $RemainingArgs = @()
}

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout -AllowPoll
$RemainingArgs = @($common.RemainingArgs)

$defaultPort = [int]$common.Port
$defaultTargetId = [string]$common.TargetId
$defaultUrlMatch = [string]$common.UrlMatch
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
        throw "Unsupported flag '$arg' for run. Supported flags: --artifacts-dir, --port, --target-id, --url-match, --timeout-ms, --poll-ms"
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
  timeoutMs    = $defaultTimeoutMs
  pollMs       = $defaultPollMs
  retries      = 0
  retryDelayMs = 300
}

if ($null -ne $settings) {
  $defaults.port = [int](Get-SilmarilOptionalValue -Object $settings -Name "port" -Default $defaults.port)
  $defaults.targetId = [string](Get-SilmarilOptionalValue -Object $settings -Name "targetId" -Default $defaults.targetId)
  $defaults.urlMatch = [string](Get-SilmarilOptionalValue -Object $settings -Name "urlMatch" -Default $defaults.urlMatch)
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
if (-not [string]::IsNullOrWhiteSpace($defaults.targetId) -and -not [string]::IsNullOrWhiteSpace($defaults.urlMatch)) {
  throw "Flow defaults cannot set both targetId and urlMatch."
}

if ([string]::IsNullOrWhiteSpace($artifactsDir)) {
  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $artifactsDir = Join-Path -Path $scriptRoot -ChildPath ("runs\\run-" + $timestamp)
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

  $args = @(
    "-NoProfile"
    "-ExecutionPolicy"
    "Bypass"
    "-File"
    $entryScript
    $CommandName
  )

  if ($CommandArgs) {
    $args += @($CommandArgs)
  }

  $args += "--json"

  $rawOutput = & powershell @args 2>&1
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
    [int]$TimeoutMs,
    [int]$PollMs,
    [switch]$IncludePoll
  )

  [void]$Args.Add("--port")
  [void]$Args.Add([string]$Port)

  if (-not [string]::IsNullOrWhiteSpace($TargetId)) {
    [void]$Args.Add("--target-id")
    [void]$Args.Add($TargetId)
  }
  elseif (-not [string]::IsNullOrWhiteSpace($UrlMatch)) {
    [void]$Args.Add("--url-match")
    [void]$Args.Add($UrlMatch)
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
  $stepUrlMatch = [string](Get-SilmarilOptionalValue -Object $step -Name "urlMatch" -Default $defaults.urlMatch)
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
  if (-not [string]::IsNullOrWhiteSpace($stepTargetId) -and -not [string]::IsNullOrWhiteSpace($stepUrlMatch)) {
    throw "Step '$stepId' cannot set both targetId and urlMatch."
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
      Add-SilmarilCommonStepFlags -Args $commandArgsList -Port $stepPort -TargetId "" -UrlMatch "" -TimeoutMs $stepTimeoutMs -PollMs $stepPollMs
    }
    "openbrowser" {
      $commandName = "openbrowser"
      $includePoll = $true
      Add-SilmarilCommonStepFlags -Args $commandArgsList -Port $stepPort -TargetId "" -UrlMatch "" -TimeoutMs $stepTimeoutMs -PollMs $stepPollMs -IncludePoll
    }
    "wait-for" {
      $selector = [string](Get-SilmarilOptionalValue -Object $step -Name "selector" -Default "")
      if ([string]::IsNullOrWhiteSpace($selector)) {
        throw "Step '$stepId' action wait-for requires selector."
      }

      $commandName = "wait-for"
      [void]$commandArgsList.Add($selector)
      $includePoll = $true
      Add-SilmarilCommonStepFlags -Args $commandArgsList -Port $stepPort -TargetId $stepTargetId -UrlMatch $stepUrlMatch -TimeoutMs $stepTimeoutMs -PollMs $stepPollMs -IncludePoll
    }
    "click" {
      $selector = [string](Get-SilmarilOptionalValue -Object $step -Name "selector" -Default "")
      if ([string]::IsNullOrWhiteSpace($selector)) {
        throw "Step '$stepId' action click requires selector."
      }

      $commandName = "click"
      [void]$commandArgsList.Add($selector)
      [void]$commandArgsList.Add("--yes")
      Add-SilmarilCommonStepFlags -Args $commandArgsList -Port $stepPort -TargetId $stepTargetId -UrlMatch $stepUrlMatch -TimeoutMs $stepTimeoutMs -PollMs $stepPollMs
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

      Add-SilmarilCommonStepFlags -Args $commandArgsList -Port $stepPort -TargetId $stepTargetId -UrlMatch $stepUrlMatch -TimeoutMs $stepTimeoutMs -PollMs $stepPollMs
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
}

$domResult = Invoke-SilmarilJsonCommand -CommandName "get-dom" -CommandArgs @(
  "--port", [string]$defaults.port,
  "--timeout-ms", [string]$defaults.timeoutMs
)

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
