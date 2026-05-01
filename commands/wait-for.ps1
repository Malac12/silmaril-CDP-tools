param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout -AllowPoll
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$timeoutMs = [int]$common.TimeoutMs
$pollMs = [int]$common.PollMs

if ($RemainingArgs.Count -ne 1) {
  throw "wait-for requires exactly one selector argument. Supported flags: --port, --target-id, --url-match, --timeout-ms, --poll-ms"
}

$selectorInput = [string]$RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selectorInput)) {
  throw "Selector cannot be empty."
}

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$target = $targetContext.Target
$selectorResolution = Resolve-SilmarilSelectorInput -InputValue $selectorInput -Port $port -TargetContext $targetContext -TimeoutMs $timeoutMs
$selector = [string]$selectorResolution.resolvedSelector
$value = Invoke-SilmarilSelectorWait -Target $target -Selectors @($selector) -Mode "visible" -TimeoutMs $timeoutMs -PollMs $pollMs -CommandName "wait-for" -Port $port -TargetId $targetId -UrlMatch $urlMatch
if ($null -eq $value) {
  throw "wait-for result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_selector") {
    $detail = if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) { [string]$value.message } else { "" }
    throw (New-SilmarilSelectorStructuredErrorMessage -CommandName "wait-for" -InputSelector $selectorInput -NormalizedSelector $selector -DetailMessage $detail)
  }

  throw "Timed out waiting for selector: $selectorInput"
}

$elapsed = 0
if (($valueProps -contains "elapsedMs") -and $null -ne $value.elapsedMs) {
  $elapsed = [int]$value.elapsedMs
}

$resultData = [ordered]@{
  selector            = $selectorInput
  normalizedSelector  = $selector
  elapsedMs           = $elapsed
  port                = $port
  timeoutMs           = $timeoutMs
  pollMs              = $pollMs
  targetId            = $targetId
  urlMatch            = $urlMatch
}
if (($valueProps -contains "matchedCount") -and $null -ne $value.matchedCount) {
  $resultData["matchedCount"] = [int]$value.matchedCount
}
if (($valueProps -contains "visibleCount") -and $null -ne $value.visibleCount) {
  $resultData["visibleCount"] = [int]$value.visibleCount
}

$resultData = Add-SilmarilRuntimeRecoveryMetadata -Data $resultData -InputObject $value
$resultData = Add-SilmarilSelectorResolutionMetadata -Data $resultData -Resolution $selectorResolution
$resultData = Add-SilmarilTargetMetadata -Data $resultData -TargetContext $targetContext

Write-SilmarilCommandResult -Command "wait-for" -Text "Selector found: $selectorInput ($elapsed ms)" -Data $resultData -UseHost
