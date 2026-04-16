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

if ($RemainingArgs.Count -lt 2) {
  throw "click requires: ""selector"" --yes [--visual-cursor]. Supported flags: --port, --target-id, --url-match, --timeout-ms"
}

$selectorInput = [string]$RemainingArgs[0]

if ([string]::IsNullOrWhiteSpace($selectorInput)) {
  throw "Selector cannot be empty."
}

$confirmClick = $false
$visualCursor = $false

for ($i = 1; $i -lt $RemainingArgs.Count; $i++) {
  $arg = [string]$RemainingArgs[$i]
  $argLower = $arg.ToLowerInvariant()

  switch ($argLower) {
    "--yes" {
      $confirmClick = $true
      continue
    }
    "--visual-cursor" {
      $visualCursor = $true
      continue
    }
    default {
      throw "Unexpected argument '$arg'. click requires: ""selector"" --yes [--visual-cursor]"
    }
  }
}

if (-not $confirmClick) {
  throw "click requires explicit confirmation flag --yes"
}

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$target = $targetContext.Target
$selectorResolution = Resolve-SilmarilSelectorInput -InputValue $selectorInput -Port $port -TargetContext $targetContext -TimeoutMs $timeoutMs
$selector = [string]$selectorResolution.resolvedSelector
$selectorJs = $selector | ConvertTo-Json -Compress
$expression = "(function(){ var sel = $selectorJs; var el = document.querySelector(sel); if (!el) return { ok: false, reason: 'not_found' }; if (typeof el.scrollIntoView === 'function') { el.scrollIntoView({block:'center', inline:'center'}); } if (typeof el.focus === 'function') { el.focus(); } el.click(); return { ok: true }; })()"

$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
if ($visualCursor) {
  try {
    Invoke-SilmarilVisualCursorCue -Target $target -Selector $selector -Mode "click" -TimeoutSec $timeoutSec | Out-Null
  }
  catch {
    Write-SilmarilTrace -Message ("Visual cursor cue failed for click selector '{0}': {1}" -f $selectorInput, $_.Exception.Message)
  }
}
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

Write-SilmarilCommandResult -Command "click" -Text "Clicked selector: $selectorInput" -Data (Add-SilmarilTargetMetadata -Data (Add-SilmarilSelectorResolutionMetadata -Data @{
  selector = $selectorInput
  normalizedSelector = $selector
  visualCursor = $visualCursor
  port     = $port
  targetId = $targetId
  urlMatch = $urlMatch
} -Resolution $selectorResolution) -TargetContext $targetContext)

