param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$timeoutMs = [int]$common.TimeoutMs

$usage = "type requires: ""selector"" ""text"" --yes, or ""selector"" --text-file ""path"" --yes"
if ($RemainingArgs.Count -lt 3) {
  throw $usage
}

$selector = [string]$RemainingArgs[0]
$confirmation = [string]$RemainingArgs[$RemainingArgs.Count - 1]

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
  if ($hasFileFlag) {
    break
  }
}

if ($hasFileFlag) {
  if ($payloadArgs.Count -ne 2) {
    throw "type does not allow combining inline text with --text-file. Use either type ""selector"" ""text"" --yes or type ""selector"" --text-file ""path"" --yes"
  }

  $flag = [string]$payloadArgs[0]
  if (-not ($fileFlags | Where-Object { [string]::Equals($flag, $_, [System.StringComparison]::OrdinalIgnoreCase) })) {
    throw "type file mode requires --text-file ""path""."
  }

  $rawPath = [string]$payloadArgs[1]
  if ([string]::IsNullOrWhiteSpace($rawPath)) {
    throw "type --text-file requires a non-empty file path."
  }

  $loaded = Read-SilmarilTextFile -Path $rawPath -Label "Text" -MaxBytes $maxPayloadBytes
  $filePath = [string]$loaded.path
  $inputMode = "file"
  $textValue = [string]$loaded.content
  $payloadBytes = [int64]$loaded.bytes
}
else {
  $textValue = ($payloadArgs -join " ")
  if ([string]::IsNullOrWhiteSpace($textValue)) {
    throw "Text value cannot be empty."
  }

  $payloadBytes = [System.Text.Encoding]::UTF8.GetByteCount($textValue)
}

$selectorJs = $selector | ConvertTo-Json -Compress
$textJs = $textValue | ConvertTo-Json -Compress
$expression = "(function(){ var sel = $selectorJs; var txt = $textJs; var el = document.querySelector(sel); if (!el) return { ok: false, reason: 'not_found' }; var tag = (el.tagName || '').toLowerCase(); var isEditable = !!el.isContentEditable || tag === 'input' || tag === 'textarea'; if (!isEditable) return { ok: false, reason: 'not_editable' }; if (typeof el.scrollIntoView === 'function') { el.scrollIntoView({block:'center', inline:'center'}); } if (typeof el.focus === 'function') { el.focus(); } if ('value' in el) { el.value = txt; if (typeof el.setSelectionRange === 'function') { try { var n = el.value.length; el.setSelectionRange(n, n); } catch (_) {} } } else { el.textContent = txt; } el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); return { ok: true }; })()"

$target = Get-SilmarilPreferredPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "type"
if ($null -eq $value) {
  throw "type result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "not_found") {
    throw "No element matched selector: $selector"
  }
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "not_editable") {
    throw "Element is not editable for selector: $selector"
  }

  throw "type failed for selector: $selector"
}

$data = [ordered]@{
  selector    = $selector
  inputMode   = $inputMode
  bytes       = $payloadBytes
  port        = $port
  targetId    = $targetId
  urlMatch    = $urlMatch
}

if ($inputMode -eq "file" -and -not [string]::IsNullOrWhiteSpace($filePath)) {
  $data["filePath"] = $filePath
}

Write-SilmarilCommandResult -Command "type" -Text "Typed into selector: $selector" -Data $data -UseHost

