param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

$usage = "type requires: ""selector"" ""text"" --yes, or ""selector"" --text-file ""path"" --yes"
if ($RemainingArgs.Count -lt 3) {
  throw $usage
}

$selector = $RemainingArgs[0]
$confirmation = $RemainingArgs[$RemainingArgs.Count - 1]

if ([string]::IsNullOrWhiteSpace($selector)) {
  throw "Selector cannot be empty."
}

if ($confirmation -ne "--yes") {
  throw "type requires explicit confirmation flag --yes"
}

$payloadArgs = @()
if ($RemainingArgs.Count -gt 2) {
  $payloadArgs = $RemainingArgs[1..($RemainingArgs.Count - 2)]
}

$maxPayloadBytes = 1048576
$textValue = $null
$inputMode = "inline"
$filePath = $null
$payloadBytes = 0

$fileFlags = @("--text-file", "--file")
$hasFileFlag = $false
foreach ($arg in $payloadArgs) {
  foreach ($fileFlag in $fileFlags) {
    if ([string]::Equals([string]$arg, $fileFlag, [System.StringComparison]::OrdinalIgnoreCase)) {
      $hasFileFlag = $true
      break
    }
  }
  if ($hasFileFlag) { break }
}

if ($payloadArgs.Count -eq 1) {
  $arg0 = [string]$payloadArgs[0]
  if ($hasFileFlag) {
    throw "type file mode requires a file path after --text-file/--file"
  }

  $textValue = $arg0
  $payloadBytes = [System.Text.Encoding]::UTF8.GetByteCount($textValue)
}
elseif ($payloadArgs.Count -eq 2) {
  $flag = [string]$payloadArgs[0]
  if (
    [string]::Equals($flag, "--text-file", [System.StringComparison]::OrdinalIgnoreCase) -or
    [string]::Equals($flag, "--file", [System.StringComparison]::OrdinalIgnoreCase)
  ) {
    $loaded = Read-SilmarilTextFile -Path ([string]$payloadArgs[1]) -Label "Text" -MaxBytes $maxPayloadBytes
    $filePath = [string]$loaded.path
    $textValue = [string]$loaded.content
    $payloadBytes = [int64]$loaded.bytes
    $inputMode = "file"
  }
  else {
    if ($hasFileFlag) {
      throw "type does not allow combining inline text with --text-file/--file"
    }
    throw $usage
  }
}
else {
  if ($hasFileFlag) {
    throw "type does not allow combining inline text with --text-file/--file"
  }
  throw $usage
}

$selectorJs = $selector | ConvertTo-Json -Compress
$textJs = $textValue | ConvertTo-Json -Compress
$expression = "(function(){ var sel = $selectorJs; var txt = $textJs; var el = document.querySelector(sel); if (!el) return { ok: false, reason: 'not_found' }; var tag = (el.tagName || '').toLowerCase(); var isEditable = !!el.isContentEditable || tag === 'input' || tag === 'textarea'; if (!isEditable) return { ok: false, reason: 'not_editable' }; if (typeof el.scrollIntoView === 'function') { el.scrollIntoView({block:'center', inline:'center'}); } if (typeof el.focus === 'function') { el.focus(); } if ('value' in el) { el.value = txt; if (typeof el.setSelectionRange === 'function') { try { var n = el.value.length; el.setSelectionRange(n, n); } catch (_) {} } } else { el.textContent = txt; } el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); return { ok: true }; })()"

$target = Get-SilmarilPreferredPageTarget -Port 9222
$evalResult = Invoke-SilmarilCdpCommand -Target $target -Method "Runtime.evaluate" -Params @{
  expression    = $expression
  returnByValue = $true
  awaitPromise  = $true
}

if (-not $evalResult) {
  throw "No type result returned from CDP."
}

$resultData = [ordered]@{
  selector  = $selector
  inputMode = $inputMode
  bytes     = $payloadBytes
  text      = $textValue
}
if ($inputMode -eq "file" -and -not [string]::IsNullOrWhiteSpace($filePath)) {
  $resultData["filePath"] = $filePath
  $resultData["textFile"] = $filePath
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
          throw "Type result value is null."
        }

        $valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
        if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
          if (($valueProps -contains "reason") -and $value.reason -eq "not_editable") {
            throw "Matched element is not editable: $selector"
          }
          throw "No element matched selector: $selector"
        }

        Write-SilmarilCommandResult -Command "type" -Text "Typed text into selector: $selector" -Data $resultData -UseHost
        exit 0
      }

      if ($itemProps -contains "result") {
        $nested = $item.result
        if ($null -ne $nested) {
          $nestedProps = @(Get-SilmarilPropertyNames -InputObject $nested)
          if ($nestedProps -contains "value") {
            $value = $nested.value
            if ($null -eq $value) {
              throw "Type result value is null."
            }

            $valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
            if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
              if (($valueProps -contains "reason") -and $value.reason -eq "not_editable") {
                throw "Matched element is not editable: $selector"
              }
              throw "No element matched selector: $selector"
            }

            Write-SilmarilCommandResult -Command "type" -Text "Typed text into selector: $selector" -Data $resultData -UseHost
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
  throw "Type result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and $value.reason -eq "not_editable") {
    throw "Matched element is not editable: $selector"
  }
  throw "No element matched selector: $selector"
}

Write-SilmarilCommandResult -Command "type" -Text "Typed text into selector: $selector" -Data $resultData -UseHost

