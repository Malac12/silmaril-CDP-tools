param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port

if ($RemainingArgs.Count -ne 0) {
  throw "get-currentUrl takes no positional arguments. Supported flag: --port"
}

$pages = Get-SilmarilPageTargets -Port $port

# /json/list is typically ordered by most recently active target first.
$preferred = @($pages | Where-Object { -not (Test-SilmarilDefaultTabUrl -Url $_.url) })
if ($preferred.Count -gt 0) {
  Write-SilmarilCommandResult -Command "get-currenturl" -Text $preferred[0].url -Data @{ url = $preferred[0].url; port = $port }
  exit 0
}

Write-SilmarilCommandResult -Command "get-currenturl" -Text $pages[0].url -Data @{ url = $pages[0].url; port = $port }
