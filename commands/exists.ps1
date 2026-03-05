param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -ne 1) {
  throw "exists requires exactly one selector argument."
}

$selector = $RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selector)) {
  throw "Selector cannot be empty."
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
  if (($evalProps -contains "exceptionDetails") -and $null -ne $EvalResult.exceptionDetails) {
    throw "Runtime.evaluate reported exceptionDetails for '$CommandName'."
  }

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

  throw "Runtime.evaluate result does not contain 'value'."
}

$selectorJs = $selector | ConvertTo-Json -Compress
$expression = "(function(){ var sel = $selectorJs; return !!document.querySelector(sel); })()"

$target = Get-SilmarilPreferredPageTarget -Port 9222
$evalResult = Invoke-SilmarilCdpCommand -Target $target -Method "Runtime.evaluate" -Params @{
  expression    = $expression
  returnByValue = $true
  awaitPromise  = $true
}

$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "exists"
$exists = [bool]$value

if ($exists) {
  Write-SilmarilCommandResult -Command "exists" -Text "true" -Data @{ selector = $selector; exists = $true }
  exit 0
}

Write-SilmarilCommandResult -Command "exists" -Text "false" -Data @{ selector = $selector; exists = $false }
exit 1

