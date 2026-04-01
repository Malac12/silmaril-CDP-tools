param(
  [switch]$Integration,
  [switch]$Live,
  [switch]$LiveAuth
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$unitPath = Join-Path $repoRoot 'tests/Unit'
$integrationPath = Join-Path $repoRoot 'tests/Integration'
$livePath = Join-Path $repoRoot 'tests/Live'

$paths = @($unitPath)
$config = New-PesterConfiguration
$config.Run.Path = $paths
$config.Output.Verbosity = 'Detailed'
$config.Run.PassThru = $true

if ($Integration) {
  $env:SILMARIL_RUN_INTEGRATION = '1'
  $paths += @($integrationPath)
}

if ($Live -or $LiveAuth) {
  $env:SILMARIL_RUN_LIVE = '1'
  $paths += @($livePath)
}

if ($LiveAuth) {
  $env:SILMARIL_RUN_LIVE_AUTH = '1'
}

$config.Run.Path = $paths

$result = Invoke-Pester -Configuration $config
if ($null -eq $result) {
  throw 'Pester returned no result.'
}

if ($result.FailedCount -gt 0) {
  exit 1
}
