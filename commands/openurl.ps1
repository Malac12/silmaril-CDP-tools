param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -ne 1) {
  throw "openUrl requires exactly one URL argument."
}

$rawTarget = $RemainingArgs[0]
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

$endpoint = "http://127.0.0.1:9222/json/new?$endpointUrl"

try {
  Invoke-RestMethod -Method Put -Uri $endpoint -TimeoutSec 5 | Out-Null
}
catch {
  try {
    Invoke-RestMethod -Method Get -Uri $endpoint -TimeoutSec 5 | Out-Null
  }
  catch {
    throw "Unable to open URL via CDP on port 9222. Start browser first: silmaril.cmd openbrowser"
  }
}

Write-SilmarilCommandResult -Command "openurl" -Text "Opened URL via CDP: $url" -Data @{ url = $url } -UseHost

