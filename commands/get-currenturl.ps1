param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -ne 0) {
  throw "get-currentUrl takes no arguments."
}

$pages = Get-SilmarilPageTargets -Port 9222

# /json/list is typically ordered by most recently active target first.
$preferred = @($pages | Where-Object { -not (Test-SilmarilDefaultTabUrl -Url $_.url) })
if ($preferred.Count -gt 0) {
  Write-Output $preferred[0].url
  exit 0
}

Write-Output $pages[0].url
