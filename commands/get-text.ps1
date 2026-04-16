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
$expression = "(function(){ var sel = $selectorJs; var el = document.querySelector(sel); if (!el) return null; var txt = (typeof el.innerText === 'string') ? el.innerText : el.textContent; return txt == null ? '' : txt; })()"

$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "get-text"

if ($null -eq $value) {
  throw "No element matched selector: $selectorInput"
}

Write-SilmarilCommandResult -Command "get-text" -Text ([string]$value) -Data (Add-SilmarilTargetMetadata -Data (Add-SilmarilSelectorResolutionMetadata -Data @{
  selector = $selectorInput
  text     = [string]$value
  port     = $port
  targetId = $targetId
  urlMatch = $urlMatch
  normalizedSelector = $selector
} -Resolution $selectorResolution) -TargetContext $targetContext)
