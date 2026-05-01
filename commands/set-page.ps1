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
  throw "set-page requires explicit confirmation flag --yes"
}

$common = Parse-SilmarilCommonArgs -Args $filteredArgs -AllowPort -AllowTargetSelection
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$urlContains = [string]$common.UrlContains
$titleMatch = [string]$common.TitleMatch
$titleContains = [string]$common.TitleContains

if ($RemainingArgs.Count -ne 0) {
  throw "set-page does not accept positional arguments."
}

$sourceCount = 0
if ($useCurrent) { $sourceCount += 1 }
if (-not [string]::IsNullOrWhiteSpace($targetId)) { $sourceCount += 1 }
if (-not [string]::IsNullOrWhiteSpace($urlMatch)) { $sourceCount += 1 }
if (-not [string]::IsNullOrWhiteSpace($urlContains)) { $sourceCount += 1 }
if (-not [string]::IsNullOrWhiteSpace($titleMatch)) { $sourceCount += 1 }
if (-not [string]::IsNullOrWhiteSpace($titleContains)) { $sourceCount += 1 }
if ($sourceCount -ne 1) {
  throw "set-page requires exactly one selector source: --current, --page-id/--target-id, --url-match, --url-contains, --title-match, or --title-contains"
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
      RequestedUrlContains = $candidateContext.RequestedUrlContains
      RequestedTitleMatch = $candidateContext.RequestedTitleMatch
      RequestedTitleContains = $candidateContext.RequestedTitleContains
      SelectionMode     = "set-page-current"
      TargetStateSource = "ephemeral-target-id"
      ResolvedTargetId  = $candidateContext.ResolvedTargetId
      ResolvedUrl       = $candidateContext.ResolvedUrl
      ResolvedTitle     = $candidateContext.ResolvedTitle
      PageCount         = $candidateContext.PageCount
      CandidateCount    = 1
      TargetActivated   = $candidateContext.TargetActivated
      TargetActivationAttempted = $candidateContext.TargetActivationAttempted
      TargetActivationMethod = $candidateContext.TargetActivationMethod
      TargetActivationError = $candidateContext.TargetActivationError
    }
  }
  else {
    $resolved = Resolve-SilmarilPageTarget -Port $port
    $targetContext = [pscustomobject]@{
      Target            = $resolved.Target
      Port              = $resolved.Port
      RequestedTargetId = $resolved.RequestedTargetId
      RequestedUrlMatch = $resolved.RequestedUrlMatch
      RequestedUrlContains = $resolved.RequestedUrlContains
      RequestedTitleMatch = $resolved.RequestedTitleMatch
      RequestedTitleContains = $resolved.RequestedTitleContains
      SelectionMode     = "set-page-current"
      TargetStateSource = [string]$resolved.TargetStateSource
      ResolvedTargetId  = $resolved.ResolvedTargetId
      ResolvedUrl       = $resolved.ResolvedUrl
      ResolvedTitle     = $resolved.ResolvedTitle
      PageCount         = $resolved.PageCount
      CandidateCount    = 1
      TargetActivated   = $resolved.TargetActivated
      TargetActivationAttempted = $resolved.TargetActivationAttempted
      TargetActivationMethod = $resolved.TargetActivationMethod
      TargetActivationError = $resolved.TargetActivationError
    }
  }
}
else {
  $targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains
}

Save-SilmarilTargetState -Port $port -Target $targetContext.Target -SelectionMode "set-page" -Kind "pinned"

$data = Add-SilmarilTargetMetadata -Data ([ordered]@{
  port                    = $port
  pinnedPageId            = [string]$targetContext.ResolvedTargetId
  pinnedTargetId          = [string]$targetContext.ResolvedTargetId
  pinnedUrl               = [string]$targetContext.ResolvedUrl
  pinnedTitle             = [string]$targetContext.ResolvedTitle
  requestedTargetId       = $targetId
  requestedPageId         = $targetId
  requestedUrlMatch       = $urlMatch
  requestedUrlContains    = $urlContains
  requestedTitleMatch     = $titleMatch
  requestedTitleContains  = $titleContains
  usedCurrent             = $useCurrent
}) -TargetContext $targetContext

Write-SilmarilCommandResult -Command "set-page" -Text ("Pinned page: " + [string]$targetContext.ResolvedTargetId) -Data $data -UseHost
