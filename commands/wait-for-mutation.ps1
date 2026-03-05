param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout -AllowPoll
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$timeoutMs = [int]$common.TimeoutMs
$pollMs = [int]$common.PollMs

$selector = "body"
$includeDetails = $false
$selectorWasSet = $false

foreach ($arg in $RemainingArgs) {
  if ($arg -eq "--details") {
    $includeDetails = $true
    continue
  }

  if ($arg.StartsWith("--")) {
    throw "Unsupported flag '$arg'. Supported flags: --details, --port, --target-id, --url-match, --timeout-ms, --poll-ms"
  }

  if ($selectorWasSet) {
    throw "wait-for-mutation accepts at most one selector argument."
  }

  $selector = [string]$arg
  $selectorWasSet = $true
}

if ([string]::IsNullOrWhiteSpace($selector)) {
  throw "Selector cannot be empty."
}

$selectorJs = $selector | ConvertTo-Json -Compress
$detailsJs = if ($includeDetails) { "true" } else { "false" }
$timeoutJs = [string]$timeoutMs
$expression = "(async function(){ var sel = $selectorJs; var includeDetails = $detailsJs; var timeoutMs = $timeoutJs; var started = Date.now(); var root = document.querySelector(sel); if (!root) { return { ok: false, reason: 'not_found' }; } function nodeInfo(node){ if (!node) return null; if (node.nodeType === 3) { var textVal = typeof node.data === 'string' ? node.data : ''; return { kind: 'text', preview: textVal.slice(0, 120) }; } if (node.nodeType === 1) { var idPart = node.id ? ('#' + node.id) : ''; var clsPart = ''; if (node.classList && node.classList.length) { clsPart = '.' + Array.prototype.slice.call(node.classList, 0, 3).join('.'); } var tag = node.tagName ? node.tagName.toLowerCase() : 'element'; return { kind: 'element', name: tag, selector: tag + idPart + clsPart }; } return { kind: 'node', nodeType: node.nodeType }; } return await new Promise(function(resolve){ var finished = false; var observer = null; var timer = null; var done = function(payload){ if (finished) return; finished = true; try { if (observer) { observer.disconnect(); } } catch (_) {} if (timer) { clearTimeout(timer); } resolve(payload); }; observer = new MutationObserver(function(records){ var first = records && records.length ? records[0] : null; var payload = { ok: true, elapsedMs: Date.now() - started, mutationType: first && first.type ? first.type : 'unknown' }; if (includeDetails && first) { var detail = { target: nodeInfo(first.target) }; if (first.type === 'attributes') { detail.attributeName = first.attributeName || null; detail.oldValue = first.oldValue == null ? null : String(first.oldValue); if (first.target && first.target.getAttribute && first.attributeName) { var newAttr = first.target.getAttribute(first.attributeName); detail.newValue = newAttr == null ? null : String(newAttr); } } else if (first.type === 'childList') { detail.addedCount = first.addedNodes ? first.addedNodes.length : 0; detail.removedCount = first.removedNodes ? first.removedNodes.length : 0; detail.firstAdded = (first.addedNodes && first.addedNodes.length) ? nodeInfo(first.addedNodes[0]) : null; detail.firstRemoved = (first.removedNodes && first.removedNodes.length) ? nodeInfo(first.removedNodes[0]) : null; } else if (first.type === 'characterData') { detail.oldValue = first.oldValue == null ? null : String(first.oldValue).slice(0, 200); var newText = first.target && typeof first.target.data === 'string' ? first.target.data : ''; detail.newValue = String(newText).slice(0, 200); } payload.detail = detail; } done(payload); }); timer = setTimeout(function(){ done({ ok: false, reason: 'timeout', elapsedMs: Date.now() - started }); }, timeoutMs); try { observer.observe(root, { subtree: true, childList: true, attributes: true, characterData: true, attributeOldValue: includeDetails, characterDataOldValue: includeDetails }); } catch (e) { done({ ok: false, reason: 'observe_failed', message: String((e && e.message) ? e.message : e) }); } }); })()"

$target = Get-SilmarilPreferredPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 5000 -MinSeconds 20
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "wait-for-mutation"
if ($null -eq $value) {
  throw "wait-for-mutation result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and $value.reason -eq "not_found") {
    throw "No element matched selector: $selector"
  }
  if (($valueProps -contains "reason") -and $value.reason -eq "observe_failed") {
    if (($valueProps -contains "message") -and -not [string]::IsNullOrWhiteSpace([string]$value.message)) {
      throw "Mutation observer setup failed: $($value.message)"
    }
    throw "Mutation observer setup failed."
  }
  throw "Timed out waiting for mutation on selector: $selector"
}

$elapsed = 0
if (($valueProps -contains "elapsedMs") -and $null -ne $value.elapsedMs) {
  $elapsed = [int]$value.elapsedMs
}

$mutationType = "unknown"
if (($valueProps -contains "mutationType") -and -not [string]::IsNullOrWhiteSpace([string]$value.mutationType)) {
  $mutationType = [string]$value.mutationType
}

if (Test-SilmarilJsonOutput) {
  $payload = [ordered]@{
    ok           = $true
    command      = "wait-for-mutation"
    selector     = $selector
    mutationType = $mutationType
    elapsedMs    = $elapsed
    port         = $port
    timeoutMs    = $timeoutMs
    pollMs       = $pollMs
    targetId     = $targetId
    urlMatch     = $urlMatch
  }

  if ($includeDetails -and ($valueProps -contains "detail") -and $null -ne $value.detail) {
    $payload["detail"] = $value.detail
  }

  Write-SilmarilJson -Value $payload -Depth 20
  exit 0
}

Write-Host "Mutation observed on selector: $selector ($mutationType, $elapsed ms)"

if ($includeDetails -and ($valueProps -contains "detail") -and $null -ne $value.detail) {
  $detailJson = $value.detail | ConvertTo-Json -Depth 8 -Compress
  Write-Output $detailJson
}
