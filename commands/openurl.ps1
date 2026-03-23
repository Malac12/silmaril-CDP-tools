param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

$parsed = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTimeout -DefaultPort 9222 -DefaultTimeoutMs 5000
$RemainingArgs = @($parsed.RemainingArgs)
$port = [int]$parsed.Port
$timeoutMs = [int]$parsed.TimeoutMs
$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 1000 -MinSeconds 2

if ($RemainingArgs.Count -ne 1) {
  throw "openUrl requires exactly one URL argument. Supported flags: --port, --timeout-ms"
}

$rawTarget = [string]$RemainingArgs[0]
$resolvedPath = $null
if (-not [string]::IsNullOrWhiteSpace($rawTarget)) {
  $resolvedCandidate = Resolve-Path -LiteralPath $rawTarget -ErrorAction SilentlyContinue
  if ($resolvedCandidate) {
    $resolvedPath = $resolvedCandidate.Path
  }
}

$url = $null
if ($resolvedPath) {
  $url = ([System.Uri]::new($resolvedPath)).AbsoluteUri
}
else {
  $url = Normalize-SilmarilUrl -InputUrl $rawTarget
}

$endpointUrl = $url
if (-not $url.ToLowerInvariant().StartsWith("file:///")) {
  $endpointUrl = [System.Uri]::EscapeDataString($url)
}

$endpoint = "http://127.0.0.1:$port/json/new?$endpointUrl"

try {
  $response = Invoke-RestMethod -Method Put -Uri $endpoint -TimeoutSec $timeoutSec
}
catch {
  try {
    $response = Invoke-RestMethod -Method Get -Uri $endpoint -TimeoutSec $timeoutSec
  }
  catch {
    throw "Unable to open URL via CDP on port $port. Start browser first: silmaril.cmd openbrowser --port $port"
  }
}

$data = [ordered]@{
  url       = $url
  port      = $port
  timeoutMs = $timeoutMs
}
if ($null -ne $response) {
  $activation = Invoke-SilmarilActivateTarget -Port $port -TargetId ([string]$response.id)
  Save-SilmarilTargetState -Port $port -Target $response -SelectionMode "openurl-new-target"
  $data["resolvedTargetId"] = [string]$response.id
  $data["resolvedUrl"] = [string]$response.url
  $data["resolvedTitle"] = [string]$response.title
  $data["targetSelection"] = "openurl-new-target"
  $data["targetActivated"] = [bool]$activation.Activated
  if (-not [string]::IsNullOrWhiteSpace([string]$activation.Method)) {
    $data["targetActivationMethod"] = [string]$activation.Method
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$activation.Error)) {
    $data["targetActivationError"] = [string]$activation.Error
  }
}

Write-SilmarilCommandResult -Command "openurl" -Text "Opened URL via CDP: $url" -Data $data -UseHost
