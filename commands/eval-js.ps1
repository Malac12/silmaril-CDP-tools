param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if (-not $RemainingArgs) {
  $RemainingArgs = @()
}

# Defensive compatibility: allow direct command invocation with a trailing
# global --json flag (normally stripped by the top-level dispatcher).
if (
  $RemainingArgs.Count -gt 0 -and
  [string]::Equals([string]$RemainingArgs[$RemainingArgs.Count - 1], "--json", [System.StringComparison]::OrdinalIgnoreCase)
) {
  if ($RemainingArgs.Count -eq 1) {
    $RemainingArgs = @()
  }
  else {
    $RemainingArgs = $RemainingArgs[0..($RemainingArgs.Count - 2)]
  }
}

$hadTimeoutFlag = $false
foreach ($arg in $RemainingArgs) {
  if ([string]::Equals([string]$arg, "--timeout-ms", [System.StringComparison]::OrdinalIgnoreCase)) {
    $hadTimeoutFlag = $true
    break
  }
}

$resultJsonStrict = $false
$filteredArgs = @()
foreach ($arg in $RemainingArgs) {
  if ([string]::Equals([string]$arg, "--result-json", [System.StringComparison]::OrdinalIgnoreCase)) {
    $resultJsonStrict = $true
    continue
  }
  $filteredArgs += [string]$arg
}
$RemainingArgs = $filteredArgs

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout -DefaultPort 9222 -DefaultTimeoutMs 20000
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$timeoutMs = [int]$common.TimeoutMs

if ($RemainingArgs.Count -lt 2) {
  throw "eval-js requires expression and confirmation flag --yes, or --file <path> --yes"
}

$confirmation = [string]$RemainingArgs[$RemainingArgs.Count - 1]
if ($confirmation -ne "--yes") {
  throw "eval-js requires explicit confirmation flag --yes"
}

$payloadParts = @()
if ($RemainingArgs.Count -gt 1) {
  $payloadParts = $RemainingArgs[0..($RemainingArgs.Count - 2)]
}

if ($payloadParts.Count -eq 0) {
  throw "Expression cannot be empty."
}

$maxPayloadBytes = 1048576
$expressionInput = $null
$inputMode = "inline"
$filePath = $null
$payloadBytes = 0

$hasFileFlag = $false
foreach ($part in $payloadParts) {
  if ([string]::Equals([string]$part, "--file", [System.StringComparison]::OrdinalIgnoreCase)) {
    $hasFileFlag = $true
    break
  }
}

if ($hasFileFlag) {
  if (
    $payloadParts.Count -ne 2 -or
    -not [string]::Equals([string]$payloadParts[0], "--file", [System.StringComparison]::OrdinalIgnoreCase)
  ) {
    throw "eval-js does not allow combining inline expression with --file. Use either eval-js ""expression"" --yes or eval-js --file ""path"" --yes"
  }

  $rawPath = [string]$payloadParts[1]
  if ([string]::IsNullOrWhiteSpace($rawPath)) {
    throw "eval-js --file requires a non-empty file path."
  }

  $loaded = Read-SilmarilTextFile -Path $rawPath -Label "JavaScript" -MaxBytes $maxPayloadBytes
  $filePath = [string]$loaded.path
  $inputMode = "file"
  $expressionInput = [string]$loaded.content
  $payloadBytes = [int64]$loaded.bytes
}
else {
  $expressionInput = ($payloadParts -join " ").Trim()
  if ([string]::IsNullOrWhiteSpace($expressionInput)) {
    throw "Expression cannot be empty."
  }

  $payloadBytes = [System.Text.Encoding]::UTF8.GetByteCount($expressionInput)
}

$attemptUsed = 0
$effectiveTimeoutSec = 0

function Get-SilmarilEvalRemoteObject {
  param(
    [object]$EvalResult
  )

  if (-not $EvalResult) {
    throw "No eval-js result returned from CDP."
  }

  $evalProps = @(Get-SilmarilPropertyNames -InputObject $EvalResult)
  if (($evalProps -contains "exceptionDetails") -and $null -ne $EvalResult.exceptionDetails) {
    $details = $EvalResult.exceptionDetails
    $detailProps = @(Get-SilmarilPropertyNames -InputObject $details)

    if (($detailProps -contains "exception") -and $null -ne $details.exception) {
      $ex = $details.exception
      $exProps = @(Get-SilmarilPropertyNames -InputObject $ex)
      if (($exProps -contains "description") -and -not [string]::IsNullOrWhiteSpace([string]$ex.description)) {
        throw "JavaScript exception: $($ex.description)"
      }
      if (($exProps -contains "value") -and -not [string]::IsNullOrWhiteSpace([string]$ex.value)) {
        throw "JavaScript exception: $($ex.value)"
      }
    }

    if (($detailProps -contains "text") -and -not [string]::IsNullOrWhiteSpace([string]$details.text)) {
      throw "JavaScript exception: $($details.text)"
    }

    throw "JavaScript exception in evaluated expression."
  }

  $candidate = $null
  if ($evalProps -contains "result") {
    $candidate = $EvalResult.result
  }
  else {
    $candidate = $EvalResult
  }

  if (-not $candidate) {
    throw "No runtime result payload from CDP."
  }

  $candidateProps = @(Get-SilmarilPropertyNames -InputObject $candidate)
  if ($candidateProps -contains "type") {
    return $candidate
  }

  if (($candidate -is [System.Collections.IEnumerable]) -and -not ($candidate -is [string])) {
    foreach ($item in @($candidate)) {
      if (-not $item) {
        continue
      }

      $itemProps = @(Get-SilmarilPropertyNames -InputObject $item)
      if ($itemProps -contains "type") {
        return $item
      }

      if ($itemProps -contains "result") {
        $nested = $item.result
        if ($null -ne $nested) {
          $nestedProps = @(Get-SilmarilPropertyNames -InputObject $nested)
          if ($nestedProps -contains "type") {
            return $nested
          }
        }
      }
    }
  }

  throw "Runtime.evaluate payload did not include a remote object."
}

function Write-SilmarilEvalResult {
  param(
    [string]$Kind,
    [object]$Value,
    [string]$PlainText,
    [hashtable]$Extra = @{}
  )

  if (Test-SilmarilJsonOutput) {
    $payload = [ordered]@{
      ok               = $true
      command          = "eval-js"
      inputMode        = $inputMode
      mode             = $inputMode
      bytes            = $payloadBytes
      resultJsonStrict = $resultJsonStrict
      kind             = $Kind
      value            = $Value
      attempt          = $attemptUsed
      timeoutSec       = $effectiveTimeoutSec
      port             = $port
      targetId         = $targetId
      urlMatch         = $urlMatch
      timeoutMs        = $timeoutMs
    }

    if ($inputMode -eq "file" -and -not [string]::IsNullOrWhiteSpace($filePath)) {
      $payload["filePath"] = $filePath
      $payload["file"] = $filePath
    }

    foreach ($key in @($Extra.Keys)) {
      $payload[$key] = $Extra[$key]
    }

    Write-SilmarilJson -Value $payload -Depth 20
    return
  }

  Write-Output $PlainText
}

function ConvertTo-SilmarilStrictJsonValue {
  param(
    [object]$Candidate
  )

  $parsed = $Candidate
  if ($Candidate -is [string]) {
    $raw = [string]$Candidate
    if ([string]::IsNullOrWhiteSpace($raw)) {
      throw "eval-js --result-json requires non-empty JSON object/array result."
    }

    try {
      $parsed = $raw | ConvertFrom-Json
    }
    catch {
      throw "eval-js --result-json expected valid JSON object/array string result."
    }
  }

  if ($null -eq $parsed) {
    throw "eval-js --result-json requires JSON object/array result, but got null."
  }

  if (
    ($parsed -is [string]) -or
    ($parsed -is [bool]) -or
    ($parsed -is [int]) -or
    ($parsed -is [long]) -or
    ($parsed -is [double]) -or
    ($parsed -is [decimal])
  ) {
    throw "eval-js --result-json requires JSON object/array result, not primitive."
  }

  if ($parsed -is [System.Collections.IDictionary] -or $parsed -is [pscustomobject]) {
    return $parsed
  }

  if (($parsed -is [System.Collections.IEnumerable]) -and -not ($parsed -is [string])) {
    return @($parsed)
  }

  throw "eval-js --result-json requires JSON object/array result."
}

$target = Get-SilmarilPreferredPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch

$baseTimeoutSec = 0
if ($hadTimeoutFlag) {
  $baseTimeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 5000 -MinSeconds 5
}
else {
  $baseTimeoutSec = if ($inputMode -eq "file") { 45 } else { 20 }
}

$maxAttempts = if ($inputMode -eq "file") { 2 } else { 1 }
$evalResult = $null
$lastError = $null

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
  $timeoutSec = if ($attempt -eq 1) { $baseTimeoutSec } else { [Math]::Max(($baseTimeoutSec * 2), 90) }
  try {
    $evalResult = Invoke-SilmarilCdpCommand -Target $target -Method "Runtime.evaluate" -Params @{
      expression    = $expressionInput
      returnByValue = $true
      awaitPromise  = $true
    } -TimeoutSec $timeoutSec

    $attemptUsed = $attempt
    $effectiveTimeoutSec = $timeoutSec
    $lastError = $null
    break
  }
  catch {
    $lastError = $_.Exception
    $message = [string]$lastError.Message
    $isCdpTimeout = $message.StartsWith("Timed out waiting for CDP response", [System.StringComparison]::OrdinalIgnoreCase)

    if ($inputMode -eq "file" -and $isCdpTimeout -and $attempt -lt $maxAttempts) {
      Start-Sleep -Milliseconds 300
      continue
    }

    throw
  }
}

if ($null -eq $evalResult) {
  if ($null -ne $lastError) {
    throw $lastError
  }
  throw "No eval-js result returned from CDP."
}

$remoteObject = Get-SilmarilEvalRemoteObject -EvalResult $evalResult
$remoteProps = @(Get-SilmarilPropertyNames -InputObject $remoteObject)

if ($remoteProps -contains "value") {
  $value = $remoteObject.value
  if ($resultJsonStrict) {
    $strictValue = ConvertTo-SilmarilStrictJsonValue -Candidate $value
    $strictText = $strictValue | ConvertTo-Json -Depth 20 -Compress
    Write-SilmarilEvalResult -Kind "json" -Value $strictValue -PlainText $strictText
    exit 0
  }

  if ($null -eq $value) {
    Write-SilmarilEvalResult -Kind "null" -Value $null -PlainText "null"
    exit 0
  }

  if ($value -is [string]) {
    Write-SilmarilEvalResult -Kind "string" -Value $value -PlainText $value
    exit 0
  }

  if ($value -is [bool] -or $value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
    Write-SilmarilEvalResult -Kind "primitive" -Value $value -PlainText ([string]$value)
    exit 0
  }

  $textJson = $value | ConvertTo-Json -Depth 20 -Compress
  Write-SilmarilEvalResult -Kind "json" -Value $value -PlainText $textJson
  exit 0
}

if ($remoteProps -contains "unserializableValue") {
  if ($resultJsonStrict) {
    throw "eval-js --result-json requires JSON object/array result."
  }
  $uv = [string]$remoteObject.unserializableValue
  Write-SilmarilEvalResult -Kind "unserializable" -Value $uv -PlainText $uv
  exit 0
}

if (($remoteProps -contains "type") -and [string]$remoteObject.type -eq "undefined") {
  if ($resultJsonStrict) {
    throw "eval-js --result-json requires JSON object/array result, but got undefined."
  }
  Write-SilmarilEvalResult -Kind "undefined" -Value $null -PlainText "undefined" -Extra @{ raw = "undefined" }
  exit 0
}

if ($remoteProps -contains "description") {
  if ($resultJsonStrict) {
    throw "eval-js --result-json requires JSON object/array result."
  }
  $desc = [string]$remoteObject.description
  Write-SilmarilEvalResult -Kind "description" -Value $desc -PlainText $desc
  exit 0
}

throw "Unable to serialize JavaScript result."

