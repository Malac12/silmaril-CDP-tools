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

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains
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

  var firstMatch = stats.matchedCount > 0 ? silmarilDescribeElement(stats.nodes[0]) : null;
  var visibleMatch = stats.visibleCount > 0 ? stats.visibleNodes[0] : null;
  if (!visibleMatch) {
    var recovery = silmarilCollectRecoveryCandidates(document, sel, 'action', 8);
    return {
      ok: false,
      reason: stats.matchedCount > 0 ? 'not_visible' : 'not_found',
      actionability: {
        matchedCount: stats.matchedCount,
        visibleCount: stats.visibleCount,
        firstMatch: firstMatch,
        recovery: recovery
      }
    };
  }

  var descriptor = silmarilDescribeElement(visibleMatch);
  if (descriptor && descriptor.disabled) {
    return {
      ok: false,
      reason: 'disabled',
      actionability: {
        matchedCount: stats.matchedCount,
        visibleCount: stats.visibleCount,
        chosenElement: descriptor,
        firstMatch: firstMatch,
        recovery: silmarilCollectRecoveryCandidates(document, sel, 'action', 8)
      }
    };
  }
  if (descriptor && descriptor.pointerEvents === 'none') {
    return {
      ok: false,
      reason: 'not_actionable',
      actionability: {
        matchedCount: stats.matchedCount,
        visibleCount: stats.visibleCount,
        chosenElement: descriptor,
        firstMatch: firstMatch,
        recovery: silmarilCollectRecoveryCandidates(document, sel, 'action', 8)
      }
    };
  }

  if (typeof visibleMatch.scrollIntoView === 'function') {
    visibleMatch.scrollIntoView({ block:'center', inline:'center' });
  }
  if (typeof visibleMatch.focus === 'function') {
    visibleMatch.focus();
  }
  visibleMatch.click();
  return {
    ok: true,
    actionability: {
      matchedCount: stats.matchedCount,
      visibleCount: stats.visibleCount,
      chosenElement: descriptor,
      firstMatch: firstMatch
    }
  };
})()
"@

$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
if ($visualCursor) {
  try {
    Invoke-SilmarilVisualCursorCue -Target $target -Selector $selector -Mode "click" -TimeoutSec $timeoutSec | Out-Null
  }
  catch {
    Write-SilmarilTrace -Message ("Visual cursor cue failed for click selector '{0}': {1}" -f $selectorInput, $_.Exception.Message)
  }
}
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains -AllowTargetRefresh
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "click"
if ($null -eq $value) {
  throw "click result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_selector") {
    $detail = if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) { [string]$value.message } else { "" }
    throw (New-SilmarilSelectorStructuredErrorMessage -CommandName "click" -InputSelector $selectorInput -NormalizedSelector $selector -DetailMessage $detail)
  }
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "not_found") {
    $actionability = if (($valueProps -contains "actionability") -and $null -ne $value.actionability) { $value.actionability } else { $null }
    $recovery = $null
    if ($null -ne $actionability -and ($actionability.PSObject.Properties.Name -contains "recovery")) {
      $recovery = $actionability.recovery
    }
    throw (New-SilmarilSelectorNotFoundStructuredErrorMessage -CommandName "click" -InputSelector $selectorInput -NormalizedSelector $selector -Recovery $recovery)
  }

  $actionability = if (($valueProps -contains "actionability") -and $null -ne $value.actionability) { $value.actionability } else { $null }
  $reason = if (($valueProps -contains "reason") -and $null -ne $value.reason) { [string]$value.reason } else { "not_actionable" }
  throw (New-SilmarilActionabilityStructuredErrorMessage -CommandName "click" -InputSelector $selectorInput -NormalizedSelector $selector -Reason $reason -Actionability $actionability)
}

$data = [ordered]@{
  selector           = $selectorInput
  normalizedSelector = $selector
  visualCursor       = $visualCursor
  port               = $port
  targetId           = $targetId
  urlMatch           = $urlMatch
  urlContains        = $urlContains
  titleMatch         = $titleMatch
  titleContains      = $titleContains
}
if (($valueProps -contains "actionability") -and $null -ne $value.actionability) {
  $data["actionability"] = $value.actionability
}

$data = Add-SilmarilRuntimeRecoveryMetadata -Data $data -InputObject $evalResult
$data = Add-SilmarilSelectorResolutionMetadata -Data $data -Resolution $selectorResolution
$data = Add-SilmarilTargetMetadata -Data $data -TargetContext $targetContext

Write-SilmarilCommandResult -Command "click" -Text "Clicked selector: $selectorInput" -Data $data
