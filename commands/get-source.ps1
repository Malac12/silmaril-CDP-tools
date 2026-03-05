param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -ne 0) {
  throw "get-source takes no arguments."
}

$target = Get-SilmarilPreferredPageTarget -Port 9222

$expression = @"
(async function () {
  const current = window.location.href || '';
  const requestUrl = current.split('#')[0];
  const response = await fetch(requestUrl, {
    method: 'GET',
    credentials: 'include',
    cache: 'no-store'
  });

  if (!response.ok) {
    throw new Error('fetch failed with HTTP ' + response.status);
  }

  return await response.text();
})()
"@

$evalResult = Invoke-SilmarilCdpCommand -Target $target -Method "Runtime.evaluate" -Params @{
  expression    = $expression
  returnByValue = $true
  awaitPromise  = $true
}

if (-not $evalResult) {
  throw "No source result returned from CDP."
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
if (($runtimeProps -contains "exceptionDetails") -and $null -ne $runtimeResult.exceptionDetails) {
  throw "Runtime.evaluate returned exceptionDetails while reading source."
}

if (-not ($runtimeProps -contains "value")) {
  if (($runtimeResult -is [System.Collections.IEnumerable]) -and -not ($runtimeResult -is [string])) {
    foreach ($item in @($runtimeResult)) {
      if (-not $item) {
        continue
      }

      $itemProps = @(Get-SilmarilPropertyNames -InputObject $item)
      if ($itemProps -contains "value") {
        $sourceValue = $item.value
        if ($null -ne $sourceValue) {
          Write-SilmarilCommandResult -Command "get-source" -Text ([string]$sourceValue) -Data @{ source = [string]$sourceValue }
          exit 0
        }
      }

      if ($itemProps -contains "result") {
        $nested = $item.result
        if ($null -ne $nested) {
          $nestedProps = @(Get-SilmarilPropertyNames -InputObject $nested)
          if ($nestedProps -contains "value") {
            $sourceValue = $nested.value
            if ($null -ne $sourceValue) {
              Write-SilmarilCommandResult -Command "get-source" -Text ([string]$sourceValue) -Data @{ source = [string]$sourceValue }
              exit 0
            }
          }
        }
      }
    }
  }

  throw "Runtime.evaluate source result does not contain 'value'."
}

$source = $runtimeResult.value
if ($null -eq $source) {
  throw "Source content is null."
}

Write-SilmarilCommandResult -Command "get-source" -Text ([string]$source) -Data @{ source = [string]$source }

