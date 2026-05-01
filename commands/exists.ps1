param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$urlContains = [string]$common.UrlContains
$titleMatch = [string]$common.TitleMatch
$titleContains = [string]$common.TitleContains
$timeoutMs = [int]$common.TimeoutMs

if ($RemainingArgs.Count -ne 1) {
  throw "exists requires exactly one selector argument. Supported flags: --port, --target-id, --url-match, --timeout-ms"
}

$selectorInput = [string]$RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selectorInput)) {
  throw "Selector cannot be empty."
}

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains
$target = $targetContext.Target
$selectorResolution = Resolve-SilmarilSelectorInput -InputValue $selectorInput -Port $port -TargetContext $targetContext -TimeoutMs $timeoutMs
$selector = [string]$selectorResolution.resolvedSelector
$selectorJs = $selector | ConvertTo-Json -Compress
$domSupport = Get-SilmarilDomSupportScript
$expression = @"
(function(){
  var sel = $selectorJs;
$domSupport
  var stats = silmarilCollectSelectorStats(document, sel);
  if (!stats.ok) {
    return stats;
  }
  return {
    ok: true,
    exists: stats.matchedCount > 0,
    matchedCount: stats.matchedCount,
    visibleCount: stats.visibleCount,
    recovery: stats.matchedCount > 0 ? null : silmarilCollectRecoveryCandidates(document, sel, 'any', 8)
  };
})()
"@

$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains -AllowTargetRefresh
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "exists"
if ($null -eq $value) {
  throw "exists result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_selector") {
    $detail = if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) { [string]$value.message } else { "" }
    throw (New-SilmarilSelectorStructuredErrorMessage -CommandName "exists" -InputSelector $selectorInput -NormalizedSelector $selector -DetailMessage $detail)
  }
  throw "exists failed for selector: $selectorInput"
}

$exists = $false
if (($valueProps -contains "exists") -and $null -ne $value.exists) {
  $exists = [bool]$value.exists
}
else {
  $exists = [bool]$value
}

$resultData = [ordered]@{
  selector           = $selectorInput
  normalizedSelector = $selector
  exists             = $exists
  port               = $port
  targetId           = $targetId
  urlMatch           = $urlMatch
  urlContains        = $urlContains
  titleMatch         = $titleMatch
  titleContains      = $titleContains
}
if (($valueProps -contains "matchedCount") -and $null -ne $value.matchedCount) {
  $resultData["matchedCount"] = [int]$value.matchedCount
}
if (($valueProps -contains "visibleCount") -and $null -ne $value.visibleCount) {
  $resultData["visibleCount"] = [int]$value.visibleCount
}
if (($valueProps -contains "recovery") -and $null -ne $value.recovery) {
  $resultData["recovery"] = $value.recovery
  if (($value.recovery.PSObject.Properties.Name -contains "suggestedSelectors") -and $null -ne $value.recovery.suggestedSelectors) {
    $resultData["suggestedSelectors"] = @($value.recovery.suggestedSelectors)
  }
}

$resultData = Add-SilmarilRuntimeRecoveryMetadata -Data $resultData -InputObject $evalResult
$resultData = Add-SilmarilSelectorResolutionMetadata -Data $resultData -Resolution $selectorResolution
$resultData = Add-SilmarilTargetMetadata -Data $resultData -TargetContext $targetContext

$resultText = if ($exists) { "true" } else { "false" }
Write-SilmarilCommandResult -Command "exists" -Text $resultText -Data $resultData
if ($exists) {
  exit 0
}
exit 1
