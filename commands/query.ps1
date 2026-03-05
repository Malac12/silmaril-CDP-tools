param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -lt 1) {
  throw "query requires a selector argument."
}

$selector = [string]$RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selector)) {
  throw "Selector cannot be empty."
}

$fieldsCsv = "text"
$limit = 20

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
    default {
      if ($arg.StartsWith("--")) {
        throw "Unsupported flag '$arg'. Supported flags: --fields, --limit"
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

function Get-SilmarilEvalValue {
  param(
    [object]$EvalResult,
    [string]$CommandName
  )

  if (-not $EvalResult) {
    throw "No $CommandName result returned from CDP."
  }

  $evalProps = @(Get-SilmarilPropertyNames -InputObject $EvalResult)
  $runtimeResult = $null
  if ($evalProps -contains "result") {
    $runtimeResult = $EvalResult.result
  }
  else {
    $runtimeResult = $EvalResult
  }

  if (-not $runtimeResult) {
    throw "No runtime result payload from CDP."
  }

  $runtimeProps = @(Get-SilmarilPropertyNames -InputObject $runtimeResult)
  if ($runtimeProps -contains "value") {
    return $runtimeResult.value
  }

  if (($runtimeResult -is [System.Collections.IEnumerable]) -and -not ($runtimeResult -is [string])) {
    foreach ($item in @($runtimeResult)) {
      if (-not $item) {
        continue
      }

      $itemProps = @(Get-SilmarilPropertyNames -InputObject $item)
      if ($itemProps -contains "value") {
        return $item.value
      }

      if ($itemProps -contains "result") {
        $nested = $item.result
        if ($null -ne $nested) {
          $nestedProps = @(Get-SilmarilPropertyNames -InputObject $nested)
          if ($nestedProps -contains "value") {
            return $nested.value
          }
        }
      }
    }
  }

  if (($evalProps -contains "exceptionDetails") -and $null -ne $EvalResult.exceptionDetails) {
    throw "Runtime.evaluate returned exceptionDetails instead of value."
  }

  throw "Runtime.evaluate result does not contain 'value'."
}

$selectorJs = $selector | ConvertTo-Json -Compress
$fieldsJs = $fields | ConvertTo-Json -Compress
$limitJs = [string]$limit
$expression = "(function(){ var sel = $selectorJs; var fields = $fieldsJs; var limit = $limitJs; var isVisible = function(el){ if (!el || !el.isConnected) return false; var style = window.getComputedStyle(el); if (!style) return false; if (style.display === 'none') return false; if (style.visibility === 'hidden' || style.visibility === 'collapse') return false; if (parseFloat(style.opacity || '1') === 0) return false; var rect = el.getBoundingClientRect(); return rect.width > 0 && rect.height > 0; }; var readField = function(el, field){ var f = String(field || ''); var lower = f.toLowerCase(); if (lower === 'text') { var txt = (typeof el.innerText === 'string') ? el.innerText : el.textContent; return txt == null ? '' : String(txt); } if (lower === 'href') { if (typeof el.href === 'string') { return el.href; } if (el.getAttribute) { return el.getAttribute('href'); } return null; } if (lower === 'html') { return (typeof el.innerHTML === 'string') ? el.innerHTML : null; } if (lower === 'outer-html') { return (typeof el.outerHTML === 'string') ? el.outerHTML : null; } if (lower === 'tag') { return (el.tagName ? String(el.tagName).toLowerCase() : null); } if (lower === 'value') { return ('value' in el) ? el.value : null; } if (lower === 'visible') { return isVisible(el); } if (lower.indexOf('attr:') === 0) { var attrName = f.slice(5); return el.getAttribute ? el.getAttribute(attrName) : null; } if (lower.indexOf('prop:') === 0) { var propName = f.slice(5); try { var propVal = el[propName]; if (propVal == null) return propVal; var t = typeof propVal; if (t === 'string' || t === 'number' || t === 'boolean') return propVal; return String(propVal); } catch (_) { return null; } } return null; }; var nodes = null; try { nodes = document.querySelectorAll(sel); } catch (e) { return { ok: false, reason: 'invalid_selector', message: String((e && e.message) ? e.message : e), selector: sel }; } var total = nodes.length; var take = Math.min(limit, total); var rows = []; for (var i = 0; i < take; i++) { var el = nodes[i]; var row = {}; for (var j = 0; j < fields.length; j++) { var field = fields[j]; row[field] = readField(el, field); } rows.push(row); } return { ok: true, selector: sel, fields: fields, limit: limit, totalCount: total, returnedCount: rows.length, rows: rows }; })()"

$target = Get-SilmarilPreferredPageTarget -Port 9222
$evalResult = Invoke-SilmarilCdpCommand -Target $target -Method "Runtime.evaluate" -Params @{
  expression    = $expression
  returnByValue = $true
  awaitPromise  = $true
}

$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "query"
if ($null -eq $value) {
  throw "query result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "invalid_selector") {
    $message = "Invalid selector for query: $selector"
    if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) {
      $message = "$message. $($value.message)"
    }
    throw $message
  }

  throw "query failed for selector: $selector"
}

$rows = @()
if (($valueProps -contains "rows") -and $null -ne $value.rows) {
  $rows = @($value.rows)
}

$totalCount = 0
if (($valueProps -contains "totalCount") -and $null -ne $value.totalCount) {
  $totalCount = [int]$value.totalCount
}

$returnedCount = $rows.Count
if (($valueProps -contains "returnedCount") -and $null -ne $value.returnedCount) {
  $returnedCount = [int]$value.returnedCount
}

$resultData = [ordered]@{
  selector      = $selector
  fields        = $fields
  limit         = $limit
  totalCount    = $totalCount
  returnedCount = $returnedCount
  rows          = $rows
}

$rowsText = $rows | ConvertTo-Json -Depth 20 -Compress
Write-SilmarilCommandResult -Command "query" -Text $rowsText -Data $resultData

