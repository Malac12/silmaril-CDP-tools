param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1")
. (Join-Path -Path $scriptRoot -ChildPath "lib/page-memory.ps1")

if (-not $RemainingArgs -or $RemainingArgs.Count -lt 1) {
  throw "page-memory requires a subcommand: lookup, save, verify, list, or invalidate"
}

$subcommand = ([string]$RemainingArgs[0]).Trim().ToLowerInvariant()
$subArgs = @()
if ($RemainingArgs.Count -gt 1) {
  $subArgs = @($RemainingArgs[1..($RemainingArgs.Count - 1)])
}

switch ($subcommand) {
  "lookup" { Invoke-SilmarilPageMemoryLookup -RemainingArgs $subArgs }
  "save" { Invoke-SilmarilPageMemorySave -RemainingArgs $subArgs }
  "verify" { Invoke-SilmarilPageMemoryVerify -RemainingArgs $subArgs }
  "list" { Invoke-SilmarilPageMemoryList -RemainingArgs $subArgs }
  "invalidate" { Invoke-SilmarilPageMemoryInvalidate -RemainingArgs $subArgs }
  default {
    throw "Unsupported page-memory subcommand '$subcommand'. Use lookup, save, verify, list, or invalidate."
  }
}
