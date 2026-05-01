param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$urlContains = [string]$common.UrlContains
$titleMatch = [string]$common.TitleMatch
$titleContains = [string]$common.TitleContains
$timeoutMs = [int]$common.TimeoutMs

$usage = "set-text requires: ""selector"" ""text"" --yes, or ""selector"" --text-file ""path"" --yes"
if ($RemainingArgs.Count -lt 3) {
  throw $usage
}

$selectorInput = [string]$RemainingArgs[0]
$confirmation = [string]$RemainingArgs[$RemainingArgs.Count - 1]
if ([string]::IsNullOrWhiteSpace($selectorInput)) {
  throw "Selector cannot be empty."
}
$selector = Normalize-SilmarilSelector -Selector $selectorInput

if ($confirmation -ne "--yes") {
  throw "set-text requires explicit confirmation flag --yes"
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
    throw "set-text does not allow combining inline text with --text-file. Use either set-text ""selector"" ""text"" --yes or set-text ""selector"" --text-file ""path"" --yes"
  }

  $flag = [string]$payloadArgs[0]
  if (-not ($fileFlags | Where-Object { [string]::Equals($flag, $_, [System.StringComparison]::OrdinalIgnoreCase) })) {
    throw "set-text file mode requires --text-file ""path""."
  }

  $rawPath = [string]$payloadArgs[1]
  if ([string]::IsNullOrWhiteSpace($rawPath)) {
    throw "set-text --text-file requires a non-empty file path."
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
$domSupport = Get-SilmarilDomSupportScript
$expression = @"
(function(){
  var sel = $selectorJs;
  var txt = $textJs;
$domSupport
  var el = document.querySelector(sel);
  if (!el) {
    return {
      ok: false,
      reason: 'not_found',
      recovery: silmarilCollectRecoveryCandidates(document, sel, 'any', 8)
    };
  }
  el.textContent = txt;
  return { ok: true };
})()
"@

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains
$target = $targetContext.Target
$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains -AllowTargetRefresh
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "set-text"
if ($null -eq $value) {
  throw "set-text result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "not_found") {
    $recovery = if (($valueProps -contains "recovery") -and $null -ne $value.recovery) { $value.recovery } else { $null }
    throw (New-SilmarilSelectorNotFoundStructuredErrorMessage -CommandName "set-text" -InputSelector $selectorInput -NormalizedSelector $selector -Recovery $recovery)
  }

  throw "set-text failed for selector: $selectorInput"
}

$data = [ordered]@{
  selector    = $selectorInput
  normalizedSelector = $selector
  inputMode   = $inputMode
  bytes       = $payloadBytes
  port        = $port
  targetId    = $targetId
  urlMatch    = $urlMatch
  urlContains = $urlContains
  titleMatch = $titleMatch
  titleContains = $titleContains
}

if ($inputMode -eq "file" -and -not [string]::IsNullOrWhiteSpace($filePath)) {
  $data["filePath"] = $filePath
}

Write-SilmarilCommandResult -Command "set-text" -Text "Text updated for selector: $selectorInput" -Data (Add-SilmarilTargetMetadata -Data $data -TargetContext $targetContext) -UseHost
