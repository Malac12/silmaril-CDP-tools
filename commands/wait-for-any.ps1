param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -lt 1) {
  throw "wait-for-any requires at least one selector argument."
}

$includeCounts = $false
$selectors = @()
foreach ($arg in $RemainingArgs) {
  if ([string]::Equals([string]$arg, "--counts", [System.StringComparison]::OrdinalIgnoreCase)) {
    $includeCounts = $true
    continue
  }

  if ([string]$arg -like "--*") {
    throw "Unsupported flag '$arg'. Supported flag: --counts"
  }

  if ([string]::IsNullOrWhiteSpace([string]$arg)) {
    throw "Selector cannot be empty."
  }

  $selectors += [string]$arg
}

if ($selectors.Count -lt 1) {
  throw "wait-for-any requires at least one selector argument."
}

function Get-SilmarilEvalValue {
  param(
    [object]$EvalResult,
    [string]$CommandName
  )

  if (-not $EvalResult) {
    throw "No $CommandName result returned from CDP."
  }

  $evalProps = @(Get-SilmarilPropertyNames -InputObject $EvalResult)
  $runtimeResult = $null
  if ($evalProps -contains "result") {
    $runtimeResult = $EvalResult.result
  }
  else {
    $runtimeResult = $EvalResult
  }

  if (-not $runtimeResult) {
    throw "No runtime result payload from CDP."
  }

  $runtimeProps = @(Get-SilmarilPropertyNames -InputObject $runtimeResult)
  if ($runtimeProps -contains "value") {
    return $runtimeResult.value
  }

  if (($runtimeResult -is [System.Collections.IEnumerable]) -and -not ($runtimeResult -is [string])) {
    foreach ($item in @($runtimeResult)) {
      if (-not $item) {
        continue
      }

      $itemProps = @(Get-SilmarilPropertyNames -InputObject $item)
      if ($itemProps -contains "value") {
        return $item.value
      }

      if ($itemProps -contains "result") {
        $nested = $item.result
        if ($null -ne $nested) {
          $nestedProps = @(Get-SilmarilPropertyNames -InputObject $nested)
          if ($nestedProps -contains "value") {
            return $nested.value
          }
        }
      }
    }
  }

  if (($evalProps -contains "exceptionDetails") -and $null -ne $EvalResult.exceptionDetails) {
    throw "Runtime.evaluate returned exceptionDetails instead of value."
  }

  throw "Runtime.evaluate result does not contain 'value'."
}

$selectorsJs = $selectors | ConvertTo-Json -Compress
$includeCountsJs = if ($includeCounts) { "true" } else { "false" }
$joinedSelectors = $selectors -join " | "
$expression = "(async function(){ var sels = $selectorsJs; var includeCounts = $includeCountsJs; var timeoutMs = 10000; var intervalMs = 200; var started = Date.now(); var isVisible = function(el){ if (!el || !el.isConnected) return false; var style = window.getComputedStyle(el); if (!style) return false; if (style.display === 'none') return false; if (style.visibility === 'hidden' || style.visibility === 'collapse') return false; if (parseFloat(style.opacity || '1') === 0) return false; var rect = el.getBoundingClientRect(); return rect.width > 0 && rect.height > 0; }; var collectCounts = function(){ var out = {}; for (var i = 0; i < sels.length; i++) { var sel = sels[i]; try { out[sel] = document.querySelectorAll(sel).length; } catch (_) { out[sel] = -1; } } return out; }; while ((Date.now() - started) <= timeoutMs) { for (var i = 0; i < sels.length; i++) { var sel = sels[i]; var nodes = null; try { nodes = document.querySelectorAll(sel); } catch (e) { return { ok: false, reason: 'invalid_selector', selector: sel, message: String((e && e.message) ? e.message : e), elapsedMs: Date.now() - started }; } for (var j = 0; j < nodes.length; j++) { if (isVisible(nodes[j])) { var payload = { ok: true, matchedSelector: sel, elapsedMs: Date.now() - started }; if (includeCounts) { payload.counts = collectCounts(); } return payload; } } } await new Promise(function(resolve){ setTimeout(resolve, intervalMs); }); } var timeoutPayload = { ok: false, reason: 'timeout', elapsedMs: Date.now() - started, selectors: sels }; if (includeCounts) { timeoutPayload.counts = collectCounts(); } return timeoutPayload; })()"

$target = Get-SilmarilPreferredPageTarget -Port 9222
$evalResult = Invoke-SilmarilCdpCommand -Target $target -Method "Runtime.evaluate" -Params @{
  expression    = $expression
  returnByValue = $true
  awaitPromise  = $true
} -TimeoutSec 20

$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "wait-for-any"
if ($null -eq $value) {
  throw "wait-for-any result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_selector") {
    $badSelector = ""
    if ($valueProps -contains "selector" -and -not [string]::IsNullOrWhiteSpace([string]$value.selector)) {
      $badSelector = [string]$value.selector
    }

    $message = "Invalid selector in wait-for-any: $badSelector"
    if ($valueProps -contains "message" -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) {
      $message = "$message. $($value.message)"
    }
    throw $message
  }

  throw "Timed out waiting for any selector: $joinedSelectors"
}

$matchedSelector = ""
if ($valueProps -contains "matchedSelector" -and -not [string]::IsNullOrWhiteSpace([string]$value.matchedSelector)) {
  $matchedSelector = [string]$value.matchedSelector
}
elseif ($selectors.Count -gt 0) {
  $matchedSelector = [string]$selectors[0]
}

$elapsed = 0
if ($valueProps -contains "elapsedMs" -and $null -ne $value.elapsedMs) {
  $elapsed = [int]$value.elapsedMs
}

$resultData = [ordered]@{
  selectors       = $selectors
  matchedSelector = $matchedSelector
  elapsedMs       = $elapsed
}

if ($includeCounts -and ($valueProps -contains "counts") -and $null -ne $value.counts) {
  $resultData["counts"] = $value.counts
}

Write-SilmarilCommandResult -Command "wait-for-any" -Text "Selector found (any): $matchedSelector ($elapsed ms)" -Data $resultData -UseHost

