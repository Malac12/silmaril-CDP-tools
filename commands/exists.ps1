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

if ($RemainingArgs.Count -ne 1) {
  throw "exists requires exactly one selector argument. Supported flags: --port, --target-id, --url-match, --timeout-ms"
}

$selector = [string]$RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selector)) {
  throw "Selector cannot be empty."
}

$selectorJs = $selector | ConvertTo-Json -Compress
$expression = "(function(){ var sel = $selectorJs; return !!document.querySelector(sel); })()"

$target = Get-SilmarilPreferredPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "exists"
$exists = [bool]$value

if ($exists) {
  Write-SilmarilCommandResult -Command "exists" -Text "true" -Data @{ selector = $selector; exists = $true; port = $port; targetId = $targetId; urlMatch = $urlMatch }
  exit 0
}

Write-SilmarilCommandResult -Command "exists" -Text "false" -Data @{ selector = $selector; exists = $false; port = $port; targetId = $targetId; urlMatch = $urlMatch }
exit 1
