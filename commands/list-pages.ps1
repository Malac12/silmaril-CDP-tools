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
  throw "list-pages takes no positional arguments. Supported flag: --port"
}

$pages = @(Get-SilmarilPageTargets -Port $port)
$states = Get-SilmarilAllTargetStates -Port $port
$targetContext = $null
$selectedTargetId = ""
$selectedUrl = ""
$selectedTitle = ""
$targetSelection = "none"
$targetStateSource = "none"

if ($pages.Count -gt 0) {
  $targetContext = Resolve-SilmarilPageTarget -Port $port
  $selectedTargetId = [string]$targetContext.ResolvedTargetId
  $selectedUrl = [string]$targetContext.ResolvedUrl
  $selectedTitle = [string]$targetContext.ResolvedTitle
  $targetSelection = [string]$targetContext.SelectionMode
  $targetStateSource = [string]$targetContext.TargetStateSource
}

$pinnedTargetId = if ($null -ne $states.pinned) { [string]$states.pinned.id } else { "" }
$ephemeralTargetId = if ($null -ne $states.ephemeral) { [string]$states.ephemeral.id } else { "" }

$targets = @()
for ($i = 0; $i -lt $pages.Count; $i += 1) {
  $target = $pages[$i]
  $row = ConvertTo-SilmarilTargetCandidate -Target $target -Index $i
  $row["pageId"] = [string]$target.id
  $row["isSelected"] = ([string]$target.id -eq $selectedTargetId)
  $row["isPinned"] = (-not [string]::IsNullOrWhiteSpace($pinnedTargetId) -and ([string]$target.id -eq $pinnedTargetId))
  $row["isEphemeral"] = (-not [string]::IsNullOrWhiteSpace($ephemeralTargetId) -and ([string]$target.id -eq $ephemeralTargetId))
  $targets += $row
}

Write-SilmarilCommandResult -Command "list-pages" -Text ("Pages: " + [string]$targets.Count) -Data ([ordered]@{
  port              = $port
  pageCount         = $targets.Count
  pages             = $targets
  targets           = $targets
  selectedPageId    = $selectedTargetId
  selectedTargetId  = $selectedTargetId
  selectedUrl       = $selectedUrl
  selectedTitle     = $selectedTitle
  targetSelection   = $targetSelection
  targetStateSource = $targetStateSource
  pinnedState       = $states.pinned
  ephemeralState    = $states.ephemeral
}) -Depth 10
