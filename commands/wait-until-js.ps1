param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -ne 1) {
  throw "wait-until-js requires exactly one expression argument."
}

$jsCondition = $RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($jsCondition)) {
  throw "Expression cannot be empty."
}

$conditionJs = $jsCondition | ConvertTo-Json -Compress
$expression = "(async function(){ var cond = $conditionJs; var timeoutMs = 10000; var intervalMs = 200; var started = Date.now(); var lastError = ''; while ((Date.now() - started) <= timeoutMs) { try { var fn = new Function('return (' + cond + ');'); var value = fn(); if (value) { return { ok: true, elapsedMs: Date.now() - started, valuePreview: String(value) }; } } catch (e) { lastError = String((e && e.message) ? e.message : e); } await new Promise(function(resolve){ setTimeout(resolve, intervalMs); }); } return { ok: false, reason: 'timeout', elapsedMs: Date.now() - started, lastError: lastError }; })()"

$target = Get-SilmarilPreferredPageTarget -Port 9222
$evalResult = Invoke-SilmarilCdpCommand -Target $target -Method "Runtime.evaluate" -Params @{
  expression    = $expression
  returnByValue = $true
  awaitPromise  = $true
} -TimeoutSec 20

if (-not $evalResult) {
  throw "No wait-until-js result returned from CDP."
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
        if ($valueProps -contains "elapsedMs" -and $null -ne $value.elapsedMs) {
          $elapsed = [int]$value.elapsedMs
        }
        Write-SilmarilCommandResult -Command "wait-until-js" -Text "JS condition matched ($elapsed ms)" -Data @{ expression = $jsCondition; elapsedMs = $elapsed } -UseHost
        exit 0
      }

      if ($itemProps -contains "result") {
        $nested = $item.result
        if ($null -ne $nested) {
          $nestedProps = @(Get-SilmarilPropertyNames -InputObject $nested)
          if ($nestedProps -contains "value") {
            $value = $nested.value
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
            if ($valueProps -contains "elapsedMs" -and $null -ne $value.elapsedMs) {
              $elapsed = [int]$value.elapsedMs
            }
            Write-SilmarilCommandResult -Command "wait-until-js" -Text "JS condition matched ($elapsed ms)" -Data @{ expression = $jsCondition; elapsedMs = $elapsed } -UseHost
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
if ($valueProps -contains "elapsedMs" -and $null -ne $value.elapsedMs) {
  $elapsed = [int]$value.elapsedMs
}

Write-SilmarilCommandResult -Command "wait-until-js" -Text "JS condition matched ($elapsed ms)" -Data @{ expression = $jsCondition; elapsedMs = $elapsed } -UseHost

