param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$urlContains = [string]$common.UrlContains
$titleMatch = [string]$common.TitleMatch
$titleContains = [string]$common.TitleContains
$timeoutMs = [int]$common.TimeoutMs

if ($RemainingArgs.Count -lt 1) {
  throw "query requires a selector argument."
}

$selectorInput = [string]$RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selectorInput)) {
  throw "Selector cannot be empty."
}

$fieldsCsv = "text"
$limit = 20
$visibleOnly = $false
$minCount = 0
$rootSelectorInput = $null

$i = 1
while ($i -lt $RemainingArgs.Count) {
  $arg = [string]$RemainingArgs[$i]
  $argLower = $arg.ToLowerInvariant()

  switch ($argLower) {
    "--fields" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "query --fields requires a comma-separated field list."
      }
      $fieldsCsv = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--limit" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "query --limit requires an integer value."
      }

      $rawLimit = [string]$RemainingArgs[$i + 1]
      $parsedLimit = 0
      if (-not [int]::TryParse($rawLimit, [ref]$parsedLimit)) {
        throw "query --limit must be an integer. Received: $rawLimit"
      }
      if ($parsedLimit -lt 1) {
        throw "query --limit must be >= 1."
      }

      $limit = $parsedLimit
      $i += 2
      continue
    }
    "--visible-only" {
      $visibleOnly = $true
      $i += 1
      continue
    }
    "--min-count" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "query --min-count requires an integer value."
      }

      $rawMinCount = [string]$RemainingArgs[$i + 1]
      $parsedMinCount = 0
      if (-not [int]::TryParse($rawMinCount, [ref]$parsedMinCount)) {
        throw "query --min-count must be an integer. Received: $rawMinCount"
      }
      if ($parsedMinCount -lt 1) {
        throw "query --min-count must be >= 1."
      }

      $minCount = $parsedMinCount
      $i += 2
      continue
    }
    "--root" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "query --root requires a selector or ref."
      }

      $rootSelectorInput = [string]$RemainingArgs[$i + 1]
      if ([string]::IsNullOrWhiteSpace($rootSelectorInput)) {
        throw "query --root requires a non-empty selector or ref."
      }

      $i += 2
      continue
    }
    default {
      if ($arg.StartsWith("--")) {
        throw "Unsupported flag '$arg'. Supported flags: --fields, --limit, --visible-only, --min-count, --root, --port, --target-id, --url-match, --timeout-ms"
      }
      throw "Unexpected positional argument '$arg'. query accepts one selector plus optional flags."
    }
  }
}

$fields = @()
if (-not [string]::IsNullOrWhiteSpace($fieldsCsv)) {
  $fields = @(
    $fieldsCsv.Split(",") |
      ForEach-Object { [string]$_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
}

if ($fields.Count -lt 1) {
  throw "query --fields cannot be empty."
}

foreach ($field in $fields) {
  $lower = $field.ToLowerInvariant()
  $isBuiltIn = @("text", "href", "html", "outer-html", "tag", "value", "visible") -contains $lower
  $isAttr = $lower.StartsWith("attr:")
  $isProp = $lower.StartsWith("prop:")
  if (-not ($isBuiltIn -or $isAttr -or $isProp)) {
    throw "Unsupported field '$field'. Supported built-ins: text, href, html, outer-html, tag, value, visible, attr:<name>, prop:<name>"
  }

  if (($isAttr -or $isProp) -and ($field.IndexOf(":") -ge ($field.Length - 1))) {
    throw "Field '$field' must include a name after ':'."
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

$selectorJs = $selector | ConvertTo-Json -Compress
$fieldsJs = ConvertTo-Json -Compress -InputObject @($fields)
$limitJs = [string]$limit
$visibleOnlyJs = if ($visibleOnly) { "true" } else { "false" }
$rootSelectorJs = if ([string]::IsNullOrWhiteSpace($rootSelector)) { "null" } else { $rootSelector | ConvertTo-Json -Compress }
$domSupport = Get-SilmarilDomSupportScript
$expression = @"
(function(){
  var sel = $selectorJs;
  var fields = $fieldsJs;
  var limit = $limitJs;
  var visibleOnly = $visibleOnlyJs;
  var rootSelector = $rootSelectorJs;
$domSupport
  var readField = function(el, field){
    var f = String(field || '');
    var lower = f.toLowerCase();
    if (lower === 'text') {
      var txt = (typeof el.innerText === 'string') ? el.innerText : el.textContent;
      return txt == null ? '' : String(txt);
    }
    if (lower === 'href') {
      if (typeof el.href === 'string') {
        return el.href;
      }
      if (el.getAttribute) {
        return el.getAttribute('href');
      }
      return null;
    }
    if (lower === 'html') {
      return (typeof el.innerHTML === 'string') ? el.innerHTML : null;
    }
    if (lower === 'outer-html') {
      return (typeof el.outerHTML === 'string') ? el.outerHTML : null;
    }
    if (lower === 'tag') {
      return (el.tagName ? String(el.tagName).toLowerCase() : null);
    }
    if (lower === 'value') {
      return ('value' in el) ? el.value : null;
    }
    if (lower === 'visible') {
      return silmarilIsVisible(el);
    }
    if (lower.indexOf('attr:') === 0) {
      var attrName = f.slice(5);
      return el.getAttribute ? el.getAttribute(attrName) : null;
    }
    if (lower.indexOf('prop:') === 0) {
      var propName = f.slice(5);
      try {
        var propVal = el[propName];
        if (propVal == null) return propVal;
        var t = typeof propVal;
        if (t === 'string' || t === 'number' || t === 'boolean') return propVal;
        return String(propVal);
      } catch (_) {
        return null;
      }
    }
    return null;
  };

  var rootState = silmarilResolveRoot(rootSelector);
  if (!rootState.ok) {
    return rootState;
  }

  var stats = silmarilCollectSelectorStats(rootState.root, sel);
  if (!stats.ok) {
    return stats;
  }

  var nodes = visibleOnly ? stats.visibleNodes : stats.nodes;
  var take = Math.min(limit, nodes.length);
  var rows = [];
  for (var i = 0; i < take; i++) {
    var el = nodes[i];
    var row = {};
    for (var j = 0; j < fields.length; j++) {
      var field = fields[j];
      row[field] = readField(el, field);
    }
    rows.push(row);
  }

  return {
    ok: true,
    selector: sel,
    rootSelector: rootSelector,
    fields: fields,
    limit: limit,
    visibleOnly: visibleOnly,
    totalCount: stats.matchedCount,
    matchedCount: stats.matchedCount,
    visibleCount: stats.visibleCount,
    returnedCount: rows.length,
    returnedVisibleCount: visibleOnly ? rows.length : Math.min(stats.visibleCount, rows.length),
    rows: rows,
    recovery: nodes.length > 0 ? null : silmarilCollectRecoveryCandidates(rootState.root, sel, 'any', 8)
  };
})()
"@

$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 3000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec -Port $port -TargetId $targetId -UrlMatch $urlMatch -UrlContains $urlContains -TitleMatch $titleMatch -TitleContains $titleContains -AllowTargetRefresh
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "query"
if ($null -eq $value) {
  throw "query result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_selector") {
    $detail = if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) { [string]$value.message } else { "" }
    throw (New-SilmarilSelectorStructuredErrorMessage -CommandName "query" -InputSelector $selectorInput -NormalizedSelector $selector -DetailMessage $detail)
  }
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_root_selector") {
    $detail = if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) { [string]$value.message } else { "" }
    throw (New-SilmarilSelectorStructuredErrorMessage -CommandName "query root" -InputSelector $rootSelectorInput -NormalizedSelector $rootSelector -DetailMessage $detail -Extra @{
      inputRootSelector = $rootSelectorInput
      normalizedRootSelector = $rootSelector
    })
  }
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "root_not_found") {
    throw (New-SilmarilStructuredErrorMessage -Payload ([ordered]@{
      code = "ROOT_NOT_FOUND"
      message = "No query root matched selector: $rootSelectorInput"
      hint = "Verify the root selector or remove --root."
      inputRootSelector = $rootSelectorInput
      normalizedRootSelector = $rootSelector
    }))
  }

  throw "query failed for selector: $selectorInput"
}

$rows = @()
if (($valueProps -contains "rows") -and $null -ne $value.rows) {
  $rows = @($value.rows)
}

$matchedCount = 0
if (($valueProps -contains "matchedCount") -and $null -ne $value.matchedCount) {
  $matchedCount = [int]$value.matchedCount
}

$visibleCountValue = 0
if (($valueProps -contains "visibleCount") -and $null -ne $value.visibleCount) {
  $visibleCountValue = [int]$value.visibleCount
}

$returnedCount = $rows.Count
if (($valueProps -contains "returnedCount") -and $null -ne $value.returnedCount) {
  $returnedCount = [int]$value.returnedCount
}

$returnedVisibleCount = 0
if (($valueProps -contains "returnedVisibleCount") -and $null -ne $value.returnedVisibleCount) {
  $returnedVisibleCount = [int]$value.returnedVisibleCount
}

$actualCount = if ($visibleOnly) { $visibleCountValue } else { $matchedCount }
if ($minCount -gt 0 -and $actualCount -lt $minCount) {
  $countError = New-SilmarilCountStructuredErrorMessage -CommandName "query" -InputSelector $selectorInput -NormalizedSelector $selector -MinCount $minCount -ActualCount $actualCount -MatchedCount $matchedCount -VisibleCount $visibleCountValue -VisibleOnly:$visibleOnly -RootSelector ([string]$rootSelectorInput)
  if (($valueProps -contains "recovery") -and $null -ne $value.recovery) {
    $payload = Get-SilmarilErrorContract -Command "query" -Message $countError
    $payload["recovery"] = $value.recovery
    if (($value.recovery.PSObject.Properties.Name -contains "suggestedSelectors") -and $null -ne $value.recovery.suggestedSelectors) {
      $payload["suggestedSelectors"] = @($value.recovery.suggestedSelectors)
    }
    throw (New-SilmarilStructuredErrorMessage -Payload $payload)
  }
  throw $countError
}

$resultData = [ordered]@{
  selector            = $selectorInput
  normalizedSelector  = $selector
  fields              = $fields
  limit               = $limit
  totalCount          = $matchedCount
  matchedCount        = $matchedCount
  visibleCount        = $visibleCountValue
  returnedCount       = $returnedCount
  returnedVisibleCount = $returnedVisibleCount
  visibleOnly         = $visibleOnly
  rows                = $rows
  port                = $port
  targetId            = $targetId
  urlMatch            = $urlMatch
  urlContains         = $urlContains
  titleMatch          = $titleMatch
  titleContains       = $titleContains
}
if (($valueProps -contains "recovery") -and $null -ne $value.recovery) {
  $resultData["recovery"] = $value.recovery
  if (($value.recovery.PSObject.Properties.Name -contains "suggestedSelectors") -and $null -ne $value.recovery.suggestedSelectors) {
    $resultData["suggestedSelectors"] = @($value.recovery.suggestedSelectors)
  }
}

if ($minCount -gt 0) {
  $resultData["minCount"] = $minCount
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

$resultData = Add-SilmarilRuntimeRecoveryMetadata -Data $resultData -InputObject $evalResult
$resultData = Add-SilmarilSelectorResolutionMetadata -Data $resultData -Resolution $selectorResolution
$resultData = Add-SilmarilTargetMetadata -Data $resultData -TargetContext $targetContext

$rowsText = $rows | ConvertTo-Json -Depth 20 -Compress
Write-SilmarilCommandResult -Command "query" -Text $rowsText -Data $resultData
