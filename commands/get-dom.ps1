param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$timeoutMs = [int]$common.TimeoutMs

if ($RemainingArgs.Count -gt 1) {
  throw "get-dom takes zero arguments (full page) or one selector argument. Supported flags: --port, --target-id, --url-match, --timeout-ms"
}

$selector = $null
$expression = "document.documentElement ? document.documentElement.outerHTML : ''"
if ($RemainingArgs.Count -eq 1) {
  $selector = [string]$RemainingArgs[0]
  if ([string]::IsNullOrWhiteSpace($selector)) {
    throw "Selector cannot be empty."
  }

  $selectorJs = $selector | ConvertTo-Json -Compress
  $expression = "(function(){ var sel = $selectorJs; var el = document.querySelector(sel); return el ? el.outerHTML : null; })()"
}

$target = Get-SilmarilPreferredPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "get-dom"
if ($null -eq $value) {
  if ($selector) {
    throw "No element matched selector: $selector"
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
  $resultData["selector"] = $selector
}

Write-SilmarilCommandResult -Command "get-dom" -Text ([string]$value) -Data $resultData
