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

if ($RemainingArgs.Count -ne 0) {
  throw "get-source takes no positional arguments. Supported flags: --port, --target-id, --url-match, --timeout-ms"
}

$expression = @"
(async function () {
  const current = window.location.href || '';
  const requestUrl = current.split('#')[0];
  const response = await fetch(requestUrl, {
    method: 'GET',
    credentials: 'include',
    cache: 'no-store'
  });

  if (!response.ok) {
    throw new Error('fetch failed with HTTP ' + response.status);
  }

  return await response.text();
})()
"@

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains
$target = $targetContext.Target
$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 5000 -MinSeconds 15
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains -AllowTargetRefresh
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "get-source"
if ($null -eq $value) {
  throw "No source HTML returned."
}

Write-SilmarilCommandResult -Command "get-source" -Text ([string]$value) -Data (Add-SilmarilTargetMetadata -Data @{
  html     = [string]$value
  port     = $port
  targetId = $targetId
  urlMatch = $urlMatch
  urlContains = $urlContains
  titleMatch = $titleMatch
  titleContains = $titleContains
} -TargetContext $targetContext)
