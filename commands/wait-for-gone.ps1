param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -ne 1) {
  throw "wait-for-gone requires exactly one selector argument."
}

$selector = $RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selector)) {
  throw "Selector cannot be empty."
}

$selectorJs = $selector | ConvertTo-Json -Compress
$expression = "(async function(){ var sel = $selectorJs; var timeoutMs = 10000; var intervalMs = 200; var started = Date.now(); var isVisible = function(el){ if (!el || !el.isConnected) return false; var style = window.getComputedStyle(el); if (!style) return false; if (style.display === 'none') return false; if (style.visibility === 'hidden' || style.visibility === 'collapse') return false; if (parseFloat(style.opacity || '1') === 0) return false; var rect = el.getBoundingClientRect(); return rect.width > 0 && rect.height > 0; }; while ((Date.now() - started) <= timeoutMs) { var nodes = document.querySelectorAll(sel); var foundVisible = false; for (var i = 0; i < nodes.length; i++) { if (isVisible(nodes[i])) { foundVisible = true; break; } } if (!foundVisible) { return { ok: true, elapsedMs: Date.now() - started }; } await new Promise(function(resolve){ setTimeout(resolve, intervalMs); }); } return { ok: false, reason: 'timeout', elapsedMs: Date.now() - started }; })()"

$target = Get-SilmarilPreferredPageTarget -Port 9222
$evalResult = Invoke-SilmarilCdpCommand -Target $target -Method "Runtime.evaluate" -Params @{
  expression    = $expression
  returnByValue = $true
  awaitPromise  = $true
} -TimeoutSec 20

if (-not $evalResult) {
  throw "No wait-for-gone result returned from CDP."
}

$evalProps = @(Get-SilmarilPropertyNames -InputObject $evalResult)
$runtimeResult = $null
if ($evalProps -contains "result") {
  $runtimeResult = $evalResult.result
}
else {
  $runtimeResult = $evalResult
}

if (-not $runtimeResult) {
  throw "No runtime result payload from CDP."
}

$runtimeProps = @(Get-SilmarilPropertyNames -InputObject $runtimeResult)
if (-not ($runtimeProps -contains "value")) {
  if (($runtimeResult -is [System.Collections.IEnumerable]) -and -not ($runtimeResult -is [string])) {
    foreach ($item in @($runtimeResult)) {
      if (-not $item) {
        continue
      }

      $itemProps = @(Get-SilmarilPropertyNames -InputObject $item)
      if ($itemProps -contains "value") {
        $value = $item.value
        if ($null -eq $value) {
          throw "wait-for-gone result value is null."
        }

        $valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
        if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
          throw "Timed out waiting for selector to disappear: $selector"
        }

        $elapsed = 0
        if ($valueProps -contains "elapsedMs" -and $null -ne $value.elapsedMs) {
          $elapsed = [int]$value.elapsedMs
        }
        Write-SilmarilCommandResult -Command "wait-for-gone" -Text "Selector gone: $selector ($elapsed ms)" -Data @{ selector = $selector; elapsedMs = $elapsed } -UseHost
        exit 0
      }

      if ($itemProps -contains "result") {
        $nested = $item.result
        if ($null -ne $nested) {
          $nestedProps = @(Get-SilmarilPropertyNames -InputObject $nested)
          if ($nestedProps -contains "value") {
            $value = $nested.value
            if ($null -eq $value) {
              throw "wait-for-gone result value is null."
            }

            $valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
            if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
              throw "Timed out waiting for selector to disappear: $selector"
            }

            $elapsed = 0
            if ($valueProps -contains "elapsedMs" -and $null -ne $value.elapsedMs) {
              $elapsed = [int]$value.elapsedMs
            }
            Write-SilmarilCommandResult -Command "wait-for-gone" -Text "Selector gone: $selector ($elapsed ms)" -Data @{ selector = $selector; elapsedMs = $elapsed } -UseHost
            exit 0
          }
        }
      }
    }
  }

  if (($evalProps -contains "exceptionDetails") -and $null -ne $evalResult.exceptionDetails) {
    throw "Runtime.evaluate returned exceptionDetails instead of value."
  }
  throw "Runtime.evaluate result does not contain 'value'."
}

$value = $runtimeResult.value
if ($null -eq $value) {
  throw "wait-for-gone result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  throw "Timed out waiting for selector to disappear: $selector"
}

$elapsed = 0
if ($valueProps -contains "elapsedMs" -and $null -ne $value.elapsedMs) {
  $elapsed = [int]$value.elapsedMs
}

Write-SilmarilCommandResult -Command "wait-for-gone" -Text "Selector gone: $selector ($elapsed ms)" -Data @{ selector = $selector; elapsedMs = $elapsed } -UseHost

