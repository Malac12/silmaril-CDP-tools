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
  throw "target-show takes no positional arguments. Supported flag: --port"
}

$pages = Get-SilmarilPageTargets -Port $port
$targetContext = Resolve-SilmarilPageTarget -Port $port
$states = Get-SilmarilAllTargetStates -Port $port
$selectedTargetId = [string]$targetContext.ResolvedTargetId
$pinnedTargetId = if ($null -ne $states.pinned) { [string]$states.pinned.id } else { "" }
$ephemeralTargetId = if ($null -ne $states.ephemeral) { [string]$states.ephemeral.id } else { "" }

$targets = @()
for ($i = 0; $i -lt $pages.Count; $i += 1) {
  $target = $pages[$i]
  $row = ConvertTo-SilmarilTargetCandidate -Target $target -Index $i
  $row["isSelected"] = ([string]$target.id -eq $selectedTargetId)
  $row["isPinned"] = (-not [string]::IsNullOrWhiteSpace($pinnedTargetId) -and ([string]$target.id -eq $pinnedTargetId))
  $row["isEphemeral"] = (-not [string]::IsNullOrWhiteSpace($ephemeralTargetId) -and ([string]$target.id -eq $ephemeralTargetId))
  $targets += $row
}

$data = [ordered]@{
  port              = $port
  targetSelection   = [string]$targetContext.SelectionMode
  targetStateSource = [string]$targetContext.TargetStateSource
  selectedTargetId  = $selectedTargetId
  selectedUrl       = [string]$targetContext.ResolvedUrl
  selectedTitle     = [string]$targetContext.ResolvedTitle
  pinnedState       = $states.pinned
  ephemeralState    = $states.ephemeral
  targets           = $targets
}

$text = "Selected target: $selectedTargetId -> $($targetContext.ResolvedUrl)"
Write-SilmarilCommandResult -Command "target-show" -Text $text -Data $data -Depth 20
