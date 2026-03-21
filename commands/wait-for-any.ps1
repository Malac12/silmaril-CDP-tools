param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout -AllowPoll
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$timeoutMs = [int]$common.TimeoutMs
$pollMs = [int]$common.PollMs

if ($RemainingArgs.Count -lt 1) {
  throw "wait-for-any requires at least one selector argument."
}

$includeCounts = $false
$selectors = @()
foreach ($arg in $RemainingArgs) {
  if ([string]::Equals([string]$arg, "--counts", [System.StringComparison]::OrdinalIgnoreCase)) {
    $includeCounts = $true
    continue
  }

  if ([string]$arg -like "--*") {
    throw "Unsupported flag '$arg'. Supported flags: --counts, --port, --target-id, --url-match, --timeout-ms, --poll-ms"
  }

  if ([string]::IsNullOrWhiteSpace([string]$arg)) {
    throw "Selector cannot be empty."
  }

  $selectors += [string]$arg
}

if ($selectors.Count -lt 1) {
  throw "wait-for-any requires at least one selector argument."
}

$normalizedSelectors = @($selectors | ForEach-Object { Normalize-SilmarilSelector -Selector ([string]$_) })
$joinedSelectors = $selectors -join " | "
$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$target = $targetContext.Target
$value = Invoke-SilmarilSelectorWait -Target $target -Selectors $normalizedSelectors -Mode "any-visible" -TimeoutMs $timeoutMs -PollMs $pollMs -IncludeCounts:$includeCounts -CommandName "wait-for-any"
if ($null -eq $value) {
  throw "wait-for-any result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_selector") {
    $badSelector = ""
    if (($valueProps -contains "selector") -and -not [string]::IsNullOrWhiteSpace([string]$value.selector)) {
      $badSelector = [string]$value.selector
    }

    $message = "Invalid selector in wait-for-any: $badSelector"
    if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) {
      $message = "$message. $($value.message)"
    }
    throw $message
  }

  throw "Timed out waiting for any selector: $joinedSelectors"
}

$matchedSelector = ""
if (($valueProps -contains "matchedSelector") -and -not [string]::IsNullOrWhiteSpace([string]$value.matchedSelector)) {
  $matchedSelector = [string]$value.matchedSelector
}
elseif ($selectors.Count -gt 0) {
  $matchedSelector = [string]$selectors[0]
}

$elapsed = 0
if (($valueProps -contains "elapsedMs") -and $null -ne $value.elapsedMs) {
  $elapsed = [int]$value.elapsedMs
}

$resultData = [ordered]@{
  selectors       = $selectors
  normalizedSelectors = $normalizedSelectors
  matchedSelector = $matchedSelector
  elapsedMs       = $elapsed
  port            = $port
  timeoutMs       = $timeoutMs
  pollMs          = $pollMs
  targetId        = $targetId
  urlMatch        = $urlMatch
}

if ($includeCounts -and ($valueProps -contains "counts") -and $null -ne $value.counts) {
  $resultData["counts"] = $value.counts
}

Write-SilmarilCommandResult -Command "wait-for-any" -Text "Selector found (any): $matchedSelector ($elapsed ms)" -Data (Add-SilmarilTargetMetadata -Data $resultData -TargetContext $targetContext) -UseHost
