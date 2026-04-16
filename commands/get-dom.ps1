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
  $expression = "(function(){ var sel = $selectorJs; var el = document.querySelector(sel); return el ? el.outerHTML : null; })()"
}

$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "get-dom"
if ($null -eq $value) {
  if ($selector) {
    throw "No element matched selector: $selectorInput"
  }
  throw "No DOM content returned."
}

$resultData = [ordered]@{
  html     = [string]$value
  port     = $port
  targetId = $targetId
  urlMatch = $urlMatch
}
if ($selector) {
  $resultData["selector"] = $selectorInput
  $resultData["normalizedSelector"] = $selector
}

if ($null -ne $selectorResolution) {
  $resultData = Add-SilmarilSelectorResolutionMetadata -Data $resultData -Resolution $selectorResolution
}

Write-SilmarilCommandResult -Command "get-dom" -Text ([string]$value) -Data (Add-SilmarilTargetMetadata -Data $resultData -TargetContext $targetContext)
