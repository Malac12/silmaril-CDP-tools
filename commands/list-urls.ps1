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
  throw "list-urls takes no positional arguments. Supported flag: --port"
}

$pages = Get-SilmarilPageTargets -Port $port
$targetContext = Resolve-SilmarilPageTarget -Port $port
$states = Get-SilmarilAllTargetStates -Port $port
$selectedTargetId = [string]$targetContext.ResolvedTargetId
$pinnedTargetId = if ($null -ne $states.pinned) { [string]$states.pinned.id } else { "" }
$ephemeralTargetId = if ($null -ne $states.ephemeral) { [string]$states.ephemeral.id } else { "" }

$urls = @()
$urls = @($pages | ForEach-Object { $_.url })

if (Test-SilmarilJsonOutput) {
  $targets = @()
  for ($i = 0; $i -lt $pages.Count; $i += 1) {
    $target = $pages[$i]
    $row = ConvertTo-SilmarilTargetCandidate -Target $target -Index $i
    $row["isSelected"] = ([string]$target.id -eq $selectedTargetId)
    $row["isPinned"] = (-not [string]::IsNullOrWhiteSpace($pinnedTargetId) -and ([string]$target.id -eq $pinnedTargetId))
    $row["isEphemeral"] = (-not [string]::IsNullOrWhiteSpace($ephemeralTargetId) -and ([string]$target.id -eq $ephemeralTargetId))
    $targets += $row
  }
  Write-SilmarilJson -Value ([ordered]@{
    ok               = $true
    command          = "list-urls"
    port             = $port
    urls             = $urls
    selectedTargetId = $selectedTargetId
    selectedUrl      = [string]$targetContext.ResolvedUrl
    selectedTitle    = [string]$targetContext.ResolvedTitle
    targetSelection  = [string]$targetContext.SelectionMode
    targetStateSource = [string]$targetContext.TargetStateSource
    pinnedState      = $states.pinned
    ephemeralState   = $states.ephemeral
    targets          = $targets
  }) -Depth 10
  exit 0
}

if ($urls.Count -eq 0) {
  Write-Output "No URLs found"
  exit 0
}

$urls | ForEach-Object { Write-Output $_ }
