param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1")

if (-not $RemainingArgs) {
  $RemainingArgs = @()
}

$confirm = $false
$useCurrent = $false
$filteredArgs = @()
foreach ($arg in $RemainingArgs) {
  $normalized = [string]$arg
  if ([string]::Equals($normalized, "--yes", [System.StringComparison]::OrdinalIgnoreCase)) {
    $confirm = $true
    continue
  }
  if ([string]::Equals($normalized, "--current", [System.StringComparison]::OrdinalIgnoreCase)) {
    $useCurrent = $true
    continue
  }

  $filteredArgs += $normalized
}

if (-not $confirm) {
  throw "target-pin requires explicit confirmation flag --yes"
}

$common = Parse-SilmarilCommonArgs -Args $filteredArgs -AllowPort -AllowTargetSelection
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch

if ($RemainingArgs.Count -ne 0) {
  throw "target-pin does not accept positional arguments."
}

$sourceCount = 0
if ($useCurrent) { $sourceCount += 1 }
if (-not [string]::IsNullOrWhiteSpace($targetId)) { $sourceCount += 1 }
if (-not [string]::IsNullOrWhiteSpace($urlMatch)) { $sourceCount += 1 }
if ($sourceCount -ne 1) {
  throw "target-pin requires exactly one selector source: --current, --target-id, or --url-match"
}

$targetContext = $null
if ($useCurrent) {
  $ephemeralState = Get-SilmarilTargetState -Port $port -Kind "ephemeral"
  if ($null -ne $ephemeralState) {
    $candidateContext = Resolve-SilmarilPageTarget -Port $port -TargetId ([string]$ephemeralState.id)
    $targetContext = [pscustomobject]@{
      Target            = $candidateContext.Target
      Port              = $candidateContext.Port
      RequestedTargetId = $candidateContext.RequestedTargetId
      RequestedUrlMatch = $candidateContext.RequestedUrlMatch
      SelectionMode     = "target-pin-current"
      TargetStateSource = "ephemeral-target-id"
      ResolvedTargetId  = $candidateContext.ResolvedTargetId
      ResolvedUrl       = $candidateContext.ResolvedUrl
      ResolvedTitle     = $candidateContext.ResolvedTitle
      PageCount         = $candidateContext.PageCount
      CandidateCount    = 1
    }
  }
  else {
    $resolved = Resolve-SilmarilPageTarget -Port $port
    $targetContext = [pscustomobject]@{
      Target            = $resolved.Target
      Port              = $resolved.Port
      RequestedTargetId = $resolved.RequestedTargetId
      RequestedUrlMatch = $resolved.RequestedUrlMatch
      SelectionMode     = "target-pin-current"
      TargetStateSource = [string]$resolved.TargetStateSource
      ResolvedTargetId  = $resolved.ResolvedTargetId
      ResolvedUrl       = $resolved.ResolvedUrl
      ResolvedTitle     = $resolved.ResolvedTitle
      PageCount         = $resolved.PageCount
      CandidateCount    = 1
    }
  }
}
else {
  $targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
}

Save-SilmarilTargetState -Port $port -Target $targetContext.Target -SelectionMode "target-pin" -Kind "pinned"

$data = Add-SilmarilTargetMetadata -Data ([ordered]@{
  port            = $port
  pinnedTargetId  = [string]$targetContext.ResolvedTargetId
  pinnedUrl       = [string]$targetContext.ResolvedUrl
  pinnedTitle     = [string]$targetContext.ResolvedTitle
  requestedTargetId = $targetId
  requestedUrlMatch = $urlMatch
  usedCurrent     = $useCurrent
}) -TargetContext $targetContext

Write-SilmarilCommandResult -Command "target-pin" -Text ("Pinned target: " + [string]$targetContext.ResolvedTargetId) -Data $data -UseHost
