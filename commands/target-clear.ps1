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

$confirm = $false
$filteredArgs = @()
foreach ($arg in $RemainingArgs) {
  $normalized = [string]$arg
  if ([string]::Equals($normalized, "--yes", [System.StringComparison]::OrdinalIgnoreCase)) {
    $confirm = $true
    continue
  }

  $filteredArgs += $normalized
}

if (-not $confirm) {
  throw "target-clear requires explicit confirmation flag --yes"
}

$common = Parse-SilmarilCommonArgs -Args $filteredArgs -AllowPort
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port

if ($RemainingArgs.Count -ne 0) {
  throw "target-clear does not accept positional arguments."
}

$removed = Clear-SilmarilTargetState -Port $port -Kind "all"
$data = [ordered]@{
  port              = $port
  removedEphemeral  = [bool]$removed.ephemeral
  removedPinned     = [bool]$removed.pinned
  removedLegacy     = [bool]$removed.legacy
}

Write-SilmarilCommandResult -Command "target-clear" -Text "Cleared target state." -Data $data -UseHost
