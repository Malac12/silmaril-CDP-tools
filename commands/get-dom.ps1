param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -gt 1) {
  throw "get-dom takes zero arguments (full page) or one selector argument."
}

$selector = $null
$expression = "document.documentElement ? document.documentElement.outerHTML : ''"
if ($RemainingArgs.Count -eq 1) {
  $selector = $RemainingArgs[0]
  if ([string]::IsNullOrWhiteSpace($selector)) {
    throw "Selector cannot be empty."
  }

  $selectorJs = $selector | ConvertTo-Json -Compress
  $expression = "(function(){ var sel = $selectorJs; var el = document.querySelector(sel); return el ? el.outerHTML : null; })()"
}

$target = Get-SilmarilPreferredPageTarget -Port 9222
$evalResult = Invoke-SilmarilCdpCommand -Target $target -Method "Runtime.evaluate" -Params @{
  expression    = $expression
  returnByValue = $true
  awaitPromise  = $true
}

if (-not $evalResult) {
  throw "No DOM result returned from CDP."
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
        $domValue = $item.value
        if ($null -ne $domValue) {
          Write-SilmarilCommandResult -Command "get-dom" -Text ([string]$domValue) -Data @{ selector = $selector; dom = [string]$domValue }
          exit 0
        }
      }

      if ($itemProps -contains "result") {
        $nested = $item.result
        if ($null -ne $nested) {
          $nestedProps = @(Get-SilmarilPropertyNames -InputObject $nested)
          if ($nestedProps -contains "value") {
            $domValue = $nested.value
            if ($null -ne $domValue) {
              Write-SilmarilCommandResult -Command "get-dom" -Text ([string]$domValue) -Data @{ selector = $selector; dom = [string]$domValue }
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

$domValue = $runtimeResult.value
if ($null -eq $domValue) {
  if ($RemainingArgs.Count -eq 1) {
    throw "No element matched selector: $($RemainingArgs[0])"
  }
  throw "DOM result was null."
}

Write-SilmarilCommandResult -Command "get-dom" -Text ([string]$domValue) -Data @{ selector = $selector; dom = [string]$domValue }

