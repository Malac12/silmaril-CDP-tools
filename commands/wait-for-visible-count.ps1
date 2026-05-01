param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout -AllowPoll
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$urlContains = [string]$common.UrlContains
$titleMatch = [string]$common.TitleMatch
$titleContains = [string]$common.TitleContains
$timeoutMs = [int]$common.TimeoutMs
$pollMs = [int]$common.PollMs

if ($RemainingArgs.Count -lt 1) {
  throw "wait-for-visible-count requires a selector argument."
}

$selectorInput = [string]$RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selectorInput)) {
  throw "Selector cannot be empty."
}

$minCount = 1
$rootSelectorInput = $null
$i = 1
while ($i -lt $RemainingArgs.Count) {
  $arg = [string]$RemainingArgs[$i]
  $argLower = $arg.ToLowerInvariant()

  switch ($argLower) {
    "--min-count" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "wait-for-visible-count --min-count requires an integer value."
      }

      $rawMinCount = [string]$RemainingArgs[$i + 1]
      $parsedMinCount = 0
      if (-not [int]::TryParse($rawMinCount, [ref]$parsedMinCount)) {
        throw "wait-for-visible-count --min-count must be an integer. Received: $rawMinCount"
      }
      if ($parsedMinCount -lt 1) {
        throw "wait-for-visible-count --min-count must be >= 1."
      }
      $minCount = $parsedMinCount
      $i += 2
      continue
    }
    "--root" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "wait-for-visible-count --root requires a selector or ref."
      }
      $rootSelectorInput = [string]$RemainingArgs[$i + 1]
      if ([string]::IsNullOrWhiteSpace($rootSelectorInput)) {
        throw "wait-for-visible-count --root requires a non-empty selector or ref."
      }
      $i += 2
      continue
    }
    default {
      if ($arg.StartsWith("--")) {
        throw "Unsupported flag '$arg'. Supported flags: --min-count, --root, --port, --target-id, --url-match, --timeout-ms, --poll-ms"
      }
      throw "Unexpected positional argument '$arg'. wait-for-visible-count accepts one selector plus optional flags."
    }
  }
}

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains
$target = $targetContext.Target
$selectorResolution = Resolve-SilmarilSelectorInput -InputValue $selectorInput -Port $port -TargetContext $targetContext -TimeoutMs $timeoutMs
$selector = [string]$selectorResolution.resolvedSelector
$rootResolution = $null
$rootSelector = $null
if (-not [string]::IsNullOrWhiteSpace($rootSelectorInput)) {
  $rootResolution = Resolve-SilmarilSelectorInput -InputValue $rootSelectorInput -Port $port -TargetContext $targetContext -TimeoutMs $timeoutMs
  $rootSelector = [string]$rootResolution.resolvedSelector
}

$value = Invoke-SilmarilSelectorWait -Target $target -Selectors @($selector) -Mode "visible-count" -TimeoutMs $timeoutMs -PollMs $pollMs -CommandName "wait-for-visible-count" -MinCount $minCount -RootSelector $rootSelector -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains -IncludeCounts
if ($null -eq $value) {
  throw "wait-for-visible-count result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_selector") {
    $detail = if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) { [string]$value.message } else { "" }
    throw (New-SilmarilSelectorStructuredErrorMessage -CommandName "wait-for-visible-count" -InputSelector $selectorInput -NormalizedSelector $selector -DetailMessage $detail)
  }
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_root_selector") {
    $detail = if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) { [string]$value.message } else { "" }
    throw (New-SilmarilSelectorStructuredErrorMessage -CommandName "wait-for-visible-count root" -InputSelector $rootSelectorInput -NormalizedSelector $rootSelector -DetailMessage $detail -Extra @{
      inputRootSelector = $rootSelectorInput
      normalizedRootSelector = $rootSelector
    })
  }
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "root_not_found") {
    throw (New-SilmarilStructuredErrorMessage -Payload ([ordered]@{
      code = "ROOT_NOT_FOUND"
      message = "No wait root matched selector: $rootSelectorInput"
      hint = "Verify the root selector or remove --root."
      inputRootSelector = $rootSelectorInput
      normalizedRootSelector = $rootSelector
    }))
  }

  $actualCount = 0
  $matchedCount = 0
  $visibleCount = 0
  if (($valueProps -contains "counts") -and $null -ne $value.counts -and $value.counts.PSObject.Properties.Name -contains $selector) {
    $matchedCount = [int]$value.counts.$selector
  }
  if (($valueProps -contains "visibleCounts") -and $null -ne $value.visibleCounts -and $value.visibleCounts.PSObject.Properties.Name -contains $selector) {
    $actualCount = [int]$value.visibleCounts.$selector
    $visibleCount = $actualCount
  }
  throw (New-SilmarilCountStructuredErrorMessage -CommandName "wait-for-visible-count" -InputSelector $selectorInput -NormalizedSelector $selector -MinCount $minCount -ActualCount $actualCount -MatchedCount $matchedCount -VisibleCount $visibleCount -VisibleOnly -RootSelector ([string]$rootSelectorInput))
}

$elapsed = 0
if (($valueProps -contains "elapsedMs") -and $null -ne $value.elapsedMs) {
  $elapsed = [int]$value.elapsedMs
}
$matchedCount = 0
if (($valueProps -contains "matchedCount") -and $null -ne $value.matchedCount) {
  $matchedCount = [int]$value.matchedCount
}
$visibleCount = 0
if (($valueProps -contains "visibleCount") -and $null -ne $value.visibleCount) {
  $visibleCount = [int]$value.visibleCount
}
$actualCount = $visibleCount

$resultData = [ordered]@{
  selector            = $selectorInput
  normalizedSelector  = $selector
  minCount            = $minCount
  actualCount         = $actualCount
  matchedCount        = $matchedCount
  visibleCount        = $visibleCount
  elapsedMs           = $elapsed
  port                = $port
  timeoutMs           = $timeoutMs
  pollMs              = $pollMs
  targetId            = $targetId
  urlMatch            = $urlMatch
  urlContains         = $urlContains
  titleMatch          = $titleMatch
  titleContains       = $titleContains
}
if ($null -ne $rootResolution) {
  $resultData["rootSelector"] = $rootSelectorInput
  $resultData["normalizedRootSelector"] = $rootSelector
  $resultData["rootInputSelectorOrRef"] = [string]$rootResolution.inputSelectorOrRef
  $resultData["resolvedRootSelector"] = [string]$rootResolution.resolvedSelector
  if ($null -ne $rootResolution.resolvedRef) {
    $resultData["resolvedRootRef"] = $rootResolution.resolvedRef
  }
}
if (($valueProps -contains "counts") -and $null -ne $value.counts) {
  $resultData["counts"] = $value.counts
}
if (($valueProps -contains "visibleCounts") -and $null -ne $value.visibleCounts) {
  $resultData["visibleCounts"] = $value.visibleCounts
}

$resultData = Add-SilmarilRuntimeRecoveryMetadata -Data $resultData -InputObject $value
$resultData = Add-SilmarilSelectorResolutionMetadata -Data $resultData -Resolution $selectorResolution
$resultData = Add-SilmarilTargetMetadata -Data $resultData -TargetContext $targetContext

Write-SilmarilCommandResult -Command "wait-for-visible-count" -Text "Visible selector count reached: $selectorInput ($actualCount >= $minCount, $elapsed ms)" -Data $resultData -UseHost
