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

if ($RemainingArgs.Count -ne 2) {
  throw "click requires exactly two arguments: ""selector"" --yes. Supported flags: --port, --target-id, --url-match, --timeout-ms"
}

$selectorInput = [string]$RemainingArgs[0]
$confirmation = [string]$RemainingArgs[1]

if ([string]::IsNullOrWhiteSpace($selectorInput)) {
  throw "Selector cannot be empty."
}
$selector = Normalize-SilmarilSelector -Selector $selectorInput

if ($confirmation -ne "--yes") {
  throw "click requires explicit confirmation flag --yes"
}

$selectorJs = $selector | ConvertTo-Json -Compress
$expression = "(function(){ var sel = $selectorJs; var el = document.querySelector(sel); if (!el) return { ok: false, reason: 'not_found' }; if (typeof el.scrollIntoView === 'function') { el.scrollIntoView({block:'center', inline:'center'}); } if (typeof el.focus === 'function') { el.focus(); } el.click(); return { ok: true }; })()"

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$target = $targetContext.Target
$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "click"
if ($null -eq $value) {
  throw "click result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "not_found") {
    throw "No element matched selector: $selectorInput"
  }

  throw "Click failed for selector: $selectorInput"
}

Write-SilmarilCommandResult -Command "click" -Text "Clicked selector: $selectorInput" -Data (Add-SilmarilTargetMetadata -Data @{
  selector = $selectorInput
  normalizedSelector = $selector
  port     = $port
  targetId = $targetId
  urlMatch = $urlMatch
} -TargetContext $targetContext)

