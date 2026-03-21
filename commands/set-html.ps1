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

$usage = "set-html requires: ""selector"" ""html"" --yes, or ""selector"" --html-file ""path"" --yes"
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
  throw "set-html requires explicit confirmation flag --yes"
}

$payloadArgs = @()
if ($RemainingArgs.Count -gt 2) {
  $payloadArgs = $RemainingArgs[1..($RemainingArgs.Count - 2)]
}

$maxPayloadBytes = 1048576
$htmlValue = $null
$inputMode = "inline"
$filePath = $null
$payloadBytes = 0

$fileFlags = @("--html-file", "--file")
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
    throw "set-html does not allow combining inline html with --html-file. Use either set-html ""selector"" ""html"" --yes or set-html ""selector"" --html-file ""path"" --yes"
  }

  $flag = [string]$payloadArgs[0]
  if (-not ($fileFlags | Where-Object { [string]::Equals($flag, $_, [System.StringComparison]::OrdinalIgnoreCase) })) {
    throw "set-html file mode requires --html-file ""path""."
  }

  $rawPath = [string]$payloadArgs[1]
  if ([string]::IsNullOrWhiteSpace($rawPath)) {
    throw "set-html --html-file requires a non-empty file path."
  }

  $loaded = Read-SilmarilTextFile -Path $rawPath -Label "HTML" -MaxBytes $maxPayloadBytes
  $filePath = [string]$loaded.path
  $inputMode = "file"
  $htmlValue = [string]$loaded.content
  $payloadBytes = [int64]$loaded.bytes
}
else {
  $htmlValue = ($payloadArgs -join " ")
  if ([string]::IsNullOrWhiteSpace($htmlValue)) {
    throw "HTML value cannot be empty."
  }

  $payloadBytes = [System.Text.Encoding]::UTF8.GetByteCount($htmlValue)
}

$selectorJs = $selector | ConvertTo-Json -Compress
$htmlJs = $htmlValue | ConvertTo-Json -Compress
$expression = "(function(){ var sel = $selectorJs; var html = $htmlJs; var el = document.querySelector(sel); if (!el) return { ok: false, reason: 'not_found' }; el.innerHTML = html; return { ok: true, outerHTML: el.outerHTML }; })()"

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$target = $targetContext.Target
$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "set-html"
if ($null -eq $value) {
  throw "set-html result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "not_found") {
    throw "No element matched selector: $selectorInput"
  }

  throw "set-html failed for selector: $selectorInput"
}

$data = [ordered]@{
  selector    = $selectorInput
  normalizedSelector = $selector
  inputMode   = $inputMode
  bytes       = $payloadBytes
  port        = $port
  targetId    = $targetId
  urlMatch    = $urlMatch
}

if ($inputMode -eq "file" -and -not [string]::IsNullOrWhiteSpace($filePath)) {
  $data["filePath"] = $filePath
}

Write-SilmarilCommandResult -Command "set-html" -Text "HTML updated for selector: $selectorInput" -Data (Add-SilmarilTargetMetadata -Data $data -TargetContext $targetContext) -UseHost

