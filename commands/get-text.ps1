param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -ne 1) {
  throw "get-text requires exactly one selector argument."
}

$selector = $RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selector)) {
  throw "Selector cannot be empty."
}

$selectorJs = $selector | ConvertTo-Json -Compress
$expression = "(function(){ var sel = $selectorJs; var el = document.querySelector(sel); if (!el) return null; var txt = (typeof el.innerText === 'string') ? el.innerText : el.textContent; return txt == null ? '' : txt; })()"

$target = Get-SilmarilPreferredPageTarget -Port 9222
$evalResult = Invoke-SilmarilCdpCommand -Target $target -Method "Runtime.evaluate" -Params @{
  expression    = $expression
  returnByValue = $true
  awaitPromise  = $true
}

if (-not $evalResult) {
  throw "No text result returned from CDP."
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
        $textValue = $item.value
        if ($null -ne $textValue) {
          Write-Output ([string]$textValue)
          exit 0
        }
      }

      if ($itemProps -contains "result") {
        $nested = $item.result
        if ($null -ne $nested) {
          $nestedProps = @(Get-SilmarilPropertyNames -InputObject $nested)
          if ($nestedProps -contains "value") {
            $textValue = $nested.value
            if ($null -ne $textValue) {
              Write-Output ([string]$textValue)
              exit 0
            }
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

$text = $runtimeResult.value
if ($null -eq $text) {
  throw "No element matched selector: $selector"
}

Write-Output ([string]$text)
