param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -ne 3) {
  throw "set-html requires exactly three arguments: ""selector"" ""html"" --yes"
}

$selector = $RemainingArgs[0]
$htmlValue = $RemainingArgs[1]
$confirmation = $RemainingArgs[2]

if ([string]::IsNullOrWhiteSpace($selector)) {
  throw "Selector cannot be empty."
}

if ($confirmation -ne "--yes") {
  throw "set-html requires explicit confirmation flag --yes"
}

$selectorJs = $selector | ConvertTo-Json -Compress
$htmlJs = $htmlValue | ConvertTo-Json -Compress
$expression = "(function(){ var sel = $selectorJs; var html = $htmlJs; var el = document.querySelector(sel); if (!el) return { ok: false, reason: 'not_found' }; el.innerHTML = html; return { ok: true, outerHTML: el.outerHTML }; })()"

$target = Get-SilmarilPreferredPageTarget -Port 9222
$evalResult = Invoke-SilmarilCdpCommand -Target $target -Method "Runtime.evaluate" -Params @{
  expression    = $expression
  returnByValue = $true
  awaitPromise  = $true
}

if (-not $evalResult) {
  throw "No mutation result returned from CDP."
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
          throw "Mutation result value is null."
        }

        $valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
        if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
          throw "No element matched selector: $selector"
        }

        Write-Host "Updated innerHTML for selector: $selector"
        exit 0
      }

      if ($itemProps -contains "result") {
        $nested = $item.result
        if ($null -ne $nested) {
          $nestedProps = @(Get-SilmarilPropertyNames -InputObject $nested)
          if ($nestedProps -contains "value") {
            $value = $nested.value
            if ($null -eq $value) {
              throw "Mutation result value is null."
            }

            $valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
            if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
              throw "No element matched selector: $selector"
            }

            Write-Host "Updated innerHTML for selector: $selector"
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
  throw "Mutation result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  throw "No element matched selector: $selector"
}

Write-Host "Updated innerHTML for selector: $selector"
