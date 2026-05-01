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
$timeoutMs = [int]$common.TimeoutMs

if ($RemainingArgs.Count -gt 1) {
  throw "get-dom takes zero arguments (full page) or one selector argument. Supported flags: --port, --target-id, --url-match, --timeout-ms"
}

$selectorInput = $null
$selector = $null
$selectorResolution = $null
$expression = "document.documentElement ? document.documentElement.outerHTML : ''"

if ($RemainingArgs.Count -eq 1) {
  $selectorInput = [string]$RemainingArgs[0]
  if ([string]::IsNullOrWhiteSpace($selectorInput)) {
    throw "Selector cannot be empty."
  }
}

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$target = $targetContext.Target
if (-not [string]::IsNullOrWhiteSpace($selectorInput)) {
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
  var selectedMatch = stats.matchedCount > 0 ? 'first-dom' : 'none';
  var el = stats.matchedCount > 0 ? stats.nodes[0] : null;
  var selectedVisible = el ? silmarilIsVisible(el) : false;

  return el ? {
    ok: true,
    html: el.outerHTML,
    matchedCount: stats.matchedCount,
    visibleCount: stats.visibleCount,
    selectionPolicy: 'dom-first',
    selectedMatch: selectedMatch,
    selectedVisible: selectedVisible
  } : null;
})()
"@
}

$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec -Port $port -TargetId $targetId -UrlMatch $urlMatch -AllowTargetRefresh
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "get-dom"
if ($null -eq $value) {
  if ($selector) {
    throw "No element matched selector: $selectorInput"
  }
  throw "No DOM content returned."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_selector") {
    $detail = if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) { [string]$value.message } else { "" }
    throw (New-SilmarilSelectorStructuredErrorMessage -CommandName "get-dom" -InputSelector $selectorInput -NormalizedSelector $selector -DetailMessage $detail)
  }
  throw "get-dom failed for selector: $selectorInput"
}

$htmlValue = if (($valueProps -contains "html") -and $null -ne $value.html) { [string]$value.html } else { [string]$value }
$resultData = [ordered]@{
  html     = $htmlValue
  port     = $port
  targetId = $targetId
  urlMatch = $urlMatch
}
if ($selector) {
  $resultData["selector"] = $selectorInput
  $resultData["normalizedSelector"] = $selector
}
if (($valueProps -contains "matchedCount") -and $null -ne $value.matchedCount) {
  $resultData["matchedCount"] = [int]$value.matchedCount
}
if (($valueProps -contains "visibleCount") -and $null -ne $value.visibleCount) {
  $resultData["visibleCount"] = [int]$value.visibleCount
}
if (($valueProps -contains "selectionPolicy") -and $null -ne $value.selectionPolicy) {
  $resultData["selectionPolicy"] = [string]$value.selectionPolicy
}
if (($valueProps -contains "selectedMatch") -and $null -ne $value.selectedMatch) {
  $resultData["selectedMatch"] = [string]$value.selectedMatch
}
if (($valueProps -contains "selectedVisible") -and $null -ne $value.selectedVisible) {
  $resultData["selectedVisible"] = [bool]$value.selectedVisible
}

$resultData = Add-SilmarilRuntimeRecoveryMetadata -Data $resultData -InputObject $evalResult
if ($null -ne $selectorResolution) {
  $resultData = Add-SilmarilSelectorResolutionMetadata -Data $resultData -Resolution $selectorResolution
}
$resultData = Add-SilmarilTargetMetadata -Data $resultData -TargetContext $targetContext

Write-SilmarilCommandResult -Command "get-dom" -Text $htmlValue -Data $resultData
