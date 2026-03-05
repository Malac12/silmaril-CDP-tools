param(
  [switch]$Integration
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$unitPath = Join-Path $repoRoot 'tests\Unit'
$integrationPath = Join-Path $repoRoot 'tests\Integration'

$config = New-PesterConfiguration
$config.Run.Path = @($unitPath)
$config.Output.Verbosity = 'Detailed'
$config.Run.PassThru = $true

if ($Integration) {
  $env:SILMARIL_RUN_INTEGRATION = '1'
  $config.Run.Path += @($integrationPath)
}

$result = Invoke-Pester -Configuration $config
if ($null -eq $result) {
  throw 'Pester returned no result.'
}

if ($result.FailedCount -gt 0) {
  exit 1
}
