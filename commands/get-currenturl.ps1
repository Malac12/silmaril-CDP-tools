param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port

if ($RemainingArgs.Count -ne 0) {
  throw "get-currentUrl takes no positional arguments. Supported flag: --port"
}

$targetContext = Resolve-SilmarilPageTarget -Port $port
$target = $targetContext.Target
Write-SilmarilCommandResult -Command "get-currenturl" -Text $target.url -Data (Add-SilmarilTargetMetadata -Data @{
  url  = $target.url
  port = $port
} -TargetContext $targetContext)
