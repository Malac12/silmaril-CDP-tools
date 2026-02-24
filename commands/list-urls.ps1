param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -ne 0) {
  throw "list-urls takes no arguments."
}

$pages = Get-SilmarilPageTargets -Port 9222
$preferred = @($pages | Where-Object { -not (Test-SilmarilDefaultTabUrl -Url $_.url) })

if ($preferred.Count -gt 0) {
  $preferred | ForEach-Object { Write-Output $_.url }
  exit 0
}

$pages | ForEach-Object { Write-Output $_.url }
