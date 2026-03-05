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

$urls = @()
if ($preferred.Count -gt 0) {
  $urls = @($preferred | ForEach-Object { $_.url })
}
else {
  $urls = @($pages | ForEach-Object { $_.url })
}

if (Test-SilmarilJsonOutput) {
  Write-SilmarilJson -Value ([ordered]@{
    ok      = $true
    command = "list-urls"
    urls    = $urls
  }) -Depth 10
  exit 0
}

$urls | ForEach-Object { Write-Output $_ }
