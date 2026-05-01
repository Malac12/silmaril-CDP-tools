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
  throw "wait-until-js requires exactly one expression argument. Supported flags: --port, --target-id, --url-match, --timeout-ms, --poll-ms"
}

$jsCondition = [string]$RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($jsCondition)) {
  throw "Expression cannot be empty."
}

$conditionJs = $jsCondition | ConvertTo-Json -Compress
$timeoutJs = [string]$timeoutMs
$pollJs = [string]$pollMs
$expression = "(async function(){ var cond = $conditionJs; var timeoutMs = $timeoutJs; var intervalMs = $pollJs; var started = Date.now(); var lastError = ''; while ((Date.now() - started) <= timeoutMs) { try { var fn = new Function('return (' + cond + ');'); var value = fn(); if (value) { return { ok: true, elapsedMs: Date.now() - started, valuePreview: String(value) }; } } catch (e) { lastError = String((e && e.message) ? e.message : e); } await new Promise(function(resolve){ setTimeout(resolve, intervalMs); }); } return { ok: false, reason: 'timeout', elapsedMs: Date.now() - started, lastError: lastError }; })()"

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains
$target = $targetContext.Target
$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 5000 -MinSeconds 20
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains -AllowTargetRefresh
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "wait-until-js"
if ($null -eq $value) {
  throw "wait-until-js result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "lastError") -and -not [string]::IsNullOrWhiteSpace([string]$value.lastError)) {
    throw "Timed out waiting for JS condition. Last error: $($value.lastError)"
  }
  throw "Timed out waiting for JS condition."
}

$elapsed = 0
if (($valueProps -contains "elapsedMs") -and $null -ne $value.elapsedMs) {
  $elapsed = [int]$value.elapsedMs
}

Write-SilmarilCommandResult -Command "wait-until-js" -Text "JS condition matched ($elapsed ms)" -Data (Add-SilmarilTargetMetadata -Data @{
  expression = $jsCondition
  elapsedMs  = $elapsed
  port       = $port
  timeoutMs  = $timeoutMs
  pollMs     = $pollMs
  targetId   = $targetId
  urlMatch   = $urlMatch
  urlContains = $urlContains
  titleMatch = $titleMatch
  titleContains = $titleContains
} -TargetContext $targetContext) -UseHost
