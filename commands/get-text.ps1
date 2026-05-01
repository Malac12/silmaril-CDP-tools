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

if ($RemainingArgs.Count -ne 1) {
  throw "get-text requires exactly one selector argument. Supported flags: --port, --target-id, --url-match, --timeout-ms"
}

$selectorInput = [string]$RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selectorInput)) {
  throw "Selector cannot be empty."
}

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
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
  var el = stats.visibleCount > 0 ? stats.visibleNodes[0] : (stats.matchedCount > 0 ? stats.nodes[0] : null);
  if (!el) {
    return null;
  }
  var txt = (typeof el.innerText === 'string') ? el.innerText : el.textContent;
  return {
    ok: true,
    text: txt == null ? '' : String(txt),
    matchedCount: stats.matchedCount,
    visibleCount: stats.visibleCount
  };
})()
"@

$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec -Port $port -TargetId $targetId -UrlMatch $urlMatch -AllowTargetRefresh
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "get-text"

if ($null -eq $value) {
  throw "No element matched selector: $selectorInput"
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_selector") {
    $detail = if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) { [string]$value.message } else { "" }
    throw (New-SilmarilSelectorStructuredErrorMessage -CommandName "get-text" -InputSelector $selectorInput -NormalizedSelector $selector -DetailMessage $detail)
  }

  throw "get-text failed for selector: $selectorInput"
}

$textValue = if (($valueProps -contains "text") -and $null -ne $value.text) { [string]$value.text } else { [string]$value }
$resultData = [ordered]@{
  selector           = $selectorInput
  normalizedSelector = $selector
  text               = $textValue
  port               = $port
  targetId           = $targetId
  urlMatch           = $urlMatch
}
if (($valueProps -contains "matchedCount") -and $null -ne $value.matchedCount) {
  $resultData["matchedCount"] = [int]$value.matchedCount
}
if (($valueProps -contains "visibleCount") -and $null -ne $value.visibleCount) {
  $resultData["visibleCount"] = [int]$value.visibleCount
}

$resultData = Add-SilmarilRuntimeRecoveryMetadata -Data $resultData -InputObject $evalResult
$resultData = Add-SilmarilSelectorResolutionMetadata -Data $resultData -Resolution $selectorResolution
$resultData = Add-SilmarilTargetMetadata -Data $resultData -TargetContext $targetContext

Write-SilmarilCommandResult -Command "get-text" -Text $textValue -Data $resultData
