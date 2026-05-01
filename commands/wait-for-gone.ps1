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
$urlContains = [string]$common.UrlContains
$titleMatch = [string]$common.TitleMatch
$titleContains = [string]$common.TitleContains
$timeoutMs = [int]$common.TimeoutMs
$pollMs = [int]$common.PollMs

if ($RemainingArgs.Count -ne 1) {
  throw "wait-for-gone requires exactly one selector argument. Supported flags: --port, --target-id, --url-match, --timeout-ms, --poll-ms"
}

$selectorInput = [string]$RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selectorInput)) {
  throw "Selector cannot be empty."
}

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains
$target = $targetContext.Target
$selectorResolution = Resolve-SilmarilSelectorInput -InputValue $selectorInput -Port $port -TargetContext $targetContext -TimeoutMs $timeoutMs
$selector = [string]$selectorResolution.resolvedSelector
$value = Invoke-SilmarilSelectorWait -Target $target -Selectors @($selector) -Mode "gone" -TimeoutMs $timeoutMs -PollMs $pollMs -CommandName "wait-for-gone" -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains
if ($null -eq $value) {
  throw "wait-for-gone result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_selector") {
    $detail = if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) { [string]$value.message } else { "" }
    throw (New-SilmarilSelectorStructuredErrorMessage -CommandName "wait-for-gone" -InputSelector $selectorInput -NormalizedSelector $selector -DetailMessage $detail)
  }

  throw "Timed out waiting for selector to disappear: $selectorInput"
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
  urlContains         = $urlContains
  titleMatch          = $titleMatch
  titleContains       = $titleContains
}

$resultData = Add-SilmarilRuntimeRecoveryMetadata -Data $resultData -InputObject $value
$resultData = Add-SilmarilSelectorResolutionMetadata -Data $resultData -Resolution $selectorResolution
$resultData = Add-SilmarilTargetMetadata -Data $resultData -TargetContext $targetContext

Write-SilmarilCommandResult -Command "wait-for-gone" -Text "Selector gone: $selectorInput ($elapsed ms)" -Data $resultData -UseHost
