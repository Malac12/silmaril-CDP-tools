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
$timeoutMs = [int]$common.TimeoutMs

$selectorInput = $null
$containerInput = $null
$x = $null
$y = $null
$left = $null
$top = $null
$behavior = "auto"
$block = "center"
$inline = "nearest"

function Parse-SilmarilScrollInt {
  param(
    [string]$RawValue,
    [string]$FlagName
  )

  $parsed = 0
  if (-not [int]::TryParse($RawValue, [ref]$parsed)) {
    throw "$FlagName must be an integer. Received: $RawValue"
  }

  return $parsed
}

$i = 0
while ($i -lt $RemainingArgs.Count) {
  $arg = [string]$RemainingArgs[$i]
  $argLower = $arg.ToLowerInvariant()

  switch ($argLower) {
    "--x" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "--x requires an integer value."
      }
      $x = Parse-SilmarilScrollInt -RawValue ([string]$RemainingArgs[$i + 1]) -FlagName "--x"
      $i += 2
      continue
    }
    "--y" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "--y requires an integer value."
      }
      $y = Parse-SilmarilScrollInt -RawValue ([string]$RemainingArgs[$i + 1]) -FlagName "--y"
      $i += 2
      continue
    }
    "--left" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "--left requires an integer value."
      }
      $left = Parse-SilmarilScrollInt -RawValue ([string]$RemainingArgs[$i + 1]) -FlagName "--left"
      $i += 2
      continue
    }
    "--top" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "--top requires an integer value."
      }
      $top = Parse-SilmarilScrollInt -RawValue ([string]$RemainingArgs[$i + 1]) -FlagName "--top"
      $i += 2
      continue
    }
    "--container" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "--container requires a selector value."
      }
      $containerInput = [string]$RemainingArgs[$i + 1]
      if ([string]::IsNullOrWhiteSpace($containerInput)) {
        throw "--container cannot be empty."
      }
      $i += 2
      continue
    }
    "--behavior" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "--behavior requires one of: auto, smooth."
      }
      $behavior = [string]$RemainingArgs[$i + 1]
      if ($behavior -notin @("auto", "smooth")) {
        throw "--behavior must be one of: auto, smooth."
      }
      $i += 2
      continue
    }
    "--block" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "--block requires one of: start, center, end, nearest."
      }
      $block = [string]$RemainingArgs[$i + 1]
      if ($block -notin @("start", "center", "end", "nearest")) {
        throw "--block must be one of: start, center, end, nearest."
      }
      $i += 2
      continue
    }
    "--inline" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "--inline requires one of: start, center, end, nearest."
      }
      $inline = [string]$RemainingArgs[$i + 1]
      if ($inline -notin @("start", "center", "end", "nearest")) {
        throw "--inline must be one of: start, center, end, nearest."
      }
      $i += 2
      continue
    }
    default {
      if ($arg.StartsWith("--")) {
        throw "Unsupported flag '$arg'. Supported flags: --container, --x, --y, --left, --top, --behavior, --block, --inline, --port, --target-id, --url-match, --timeout-ms"
      }

      if ($null -ne $selectorInput) {
        throw "scroll accepts at most one positional selector argument."
      }

      $selectorInput = $arg
      $i += 1
    }
  }
}

$hasDelta = ($null -ne $x) -or ($null -ne $y)
$hasAbsolute = ($null -ne $left) -or ($null -ne $top)

if ($hasDelta -and $hasAbsolute) {
  throw "Use either --x/--y for relative scrolling or --left/--top for absolute scrolling, not both."
}

$mode = $null
$selector = $null
$containerSelector = $null
$selectorResolution = $null
$containerResolution = $null

if (-not [string]::IsNullOrWhiteSpace($selectorInput)) {
  if ($hasDelta -or $hasAbsolute -or -not [string]::IsNullOrWhiteSpace($containerInput)) {
    throw "Selector scroll mode does not support --container, --x, --y, --left, or --top. Use: scroll ""selector"" [--behavior ...] [--block ...] [--inline ...]"
  }

  $mode = "element"
}
else {
  if (-not $hasDelta -and -not $hasAbsolute) {
    throw "scroll requires either a selector argument or at least one of --x, --y, --left, or --top."
  }

  if ($hasDelta) {
    if ($null -eq $x) { $x = 0 }
    if ($null -eq $y) { $y = 0 }
    $mode = "delta"
  }
  else {
    $mode = "absolute"
  }
}

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$target = $targetContext.Target
if (-not [string]::IsNullOrWhiteSpace($selectorInput)) {
  $selectorResolution = Resolve-SilmarilSelectorInput -InputValue $selectorInput -Port $port -TargetContext $targetContext -TimeoutMs $timeoutMs
  $selector = [string]$selectorResolution.resolvedSelector
}
if (-not [string]::IsNullOrWhiteSpace($containerInput)) {
  $containerResolution = Resolve-SilmarilSelectorInput -InputValue $containerInput -Port $port -TargetContext $targetContext -TimeoutMs $timeoutMs
  $containerSelector = [string]$containerResolution.resolvedSelector
}

$selectorJs = if ($null -ne $selector) { $selector | ConvertTo-Json -Compress } else { "null" }
$containerJs = if ($null -ne $containerSelector) { $containerSelector | ConvertTo-Json -Compress } else { "null" }
$modeJs = $mode | ConvertTo-Json -Compress
$behaviorJs = $behavior | ConvertTo-Json -Compress
$blockJs = $block | ConvertTo-Json -Compress
$inlineJs = $inline | ConvertTo-Json -Compress
$xJs = if ($null -ne $x) { [string]$x } else { "null" }
$yJs = if ($null -ne $y) { [string]$y } else { "null" }
$leftJs = if ($null -ne $left) { [string]$left } else { "null" }
$topJs = if ($null -ne $top) { [string]$top } else { "null" }

$expression = @"
(async function(){
  var selector = $selectorJs;
  var containerSelector = $containerJs;
  var mode = $modeJs;
  var behavior = $behaviorJs;
  var block = $blockJs;
  var inlineMode = $inlineJs;
  var deltaX = $xJs;
  var deltaY = $yJs;
  var absoluteLeft = $leftJs;
  var absoluteTop = $topJs;

  var flush = async function(){
    try {
      await Promise.resolve();
      await new Promise(function(resolve){
        var finished = false;
        var done = function(){
          if (finished) return;
          finished = true;
          resolve();
        };
        if (typeof requestAnimationFrame === 'function') {
          try {
            requestAnimationFrame(function(){ done(); });
          } catch (_) {}
        }
        setTimeout(done, 32);
      });
    } catch (_) {}
  };

  if (mode === 'element') {
    var el = document.querySelector(selector);
    if (!el) return { ok: false, reason: 'not_found' };
    if (typeof el.scrollIntoView === 'function') {
      el.scrollIntoView({ behavior: behavior, block: block, inline: inlineMode });
    }
    await flush();
    var rect = el.getBoundingClientRect();
    return {
      ok: true,
      mode: mode,
      selector: selector,
      top: Math.round(rect.top),
      left: Math.round(rect.left)
    };
  }

  var target = window;
  var targetKind = 'page';
  if (containerSelector) {
    target = document.querySelector(containerSelector);
    if (!target) return { ok: false, reason: 'container_not_found' };
    targetKind = 'container';
  }

  var canUseOptionsObject = typeof target.scrollTo === 'function' || typeof target.scrollBy === 'function';
  if (mode === 'delta') {
    if (typeof target.scrollBy === 'function') {
      if (canUseOptionsObject) {
        target.scrollBy({ left: deltaX, top: deltaY, behavior: behavior });
      } else {
        target.scrollBy(deltaX, deltaY);
      }
    } else {
      target.scrollLeft = (target.scrollLeft || 0) + deltaX;
      target.scrollTop = (target.scrollTop || 0) + deltaY;
    }
  } else {
    var currentLeft = targetKind === 'page'
      ? Math.round(window.scrollX || window.pageXOffset || 0)
      : Math.round(target.scrollLeft || 0);
    var currentTop = targetKind === 'page'
      ? Math.round(window.scrollY || window.pageYOffset || 0)
      : Math.round(target.scrollTop || 0);
    var desiredLeft = absoluteLeft === null ? currentLeft : absoluteLeft;
    var desiredTop = absoluteTop === null ? currentTop : absoluteTop;

    if (typeof target.scrollTo === 'function') {
      if (canUseOptionsObject) {
        target.scrollTo({ left: desiredLeft, top: desiredTop, behavior: behavior });
      } else {
        target.scrollTo(desiredLeft, desiredTop);
      }
    } else {
      target.scrollLeft = desiredLeft;
      target.scrollTop = desiredTop;
    }
  }

  await flush();

  var finalLeft;
  var finalTop;
  if (targetKind === 'page') {
    finalLeft = Math.round(window.scrollX || window.pageXOffset || 0);
    finalTop = Math.round(window.scrollY || window.pageYOffset || 0);
  } else {
    finalLeft = Math.round(target.scrollLeft || 0);
    finalTop = Math.round(target.scrollTop || 0);
  }

  return {
    ok: true,
    mode: mode,
    targetKind: targetKind,
    container: containerSelector,
    scrollLeft: finalLeft,
    scrollTop: finalTop
  };
})()
"@

$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "scroll"
if ($null -eq $value) {
  throw "scroll result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "not_found") {
    throw "No element matched selector: $selectorInput"
  }
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "container_not_found") {
    throw "No scroll container matched selector: $containerInput"
  }

  throw "scroll failed."
}

$data = [ordered]@{
  mode = $mode
  behavior = $behavior
  port = $port
  targetId = $targetId
  urlMatch = $urlMatch
}

if ($null -ne $selectorInput) {
  $data["selector"] = $selectorInput
  $data["normalizedSelector"] = $selector
  $data["block"] = $block
  $data["inline"] = $inline
}
if ($null -ne $containerInput) {
  $data["container"] = $containerInput
  $data["normalizedContainer"] = $containerSelector
  $data["inputContainerOrRef"] = [string]$containerResolution.inputSelectorOrRef
  $data["resolvedContainer"] = [string]$containerResolution.resolvedSelector
  if ($null -ne $containerResolution.resolvedRef) {
    $data["resolvedContainerRef"] = $containerResolution.resolvedRef
  }
}
if ($null -ne $x) { $data["x"] = $x }
if ($null -ne $y) { $data["y"] = $y }
if ($null -ne $left) { $data["left"] = $left }
if ($null -ne $top) { $data["top"] = $top }
if ($valueProps -contains "scrollLeft") { $data["scrollLeft"] = [int]$value.scrollLeft }
if ($valueProps -contains "scrollTop") { $data["scrollTop"] = [int]$value.scrollTop }
if ($valueProps -contains "targetKind") { $data["targetKind"] = [string]$value.targetKind }

if ($null -ne $selectorResolution) {
  $data = Add-SilmarilSelectorResolutionMetadata -Data $data -Resolution $selectorResolution
}

$text = switch ($mode) {
  "element" { "Scrolled selector into view: $selectorInput" }
  "delta" {
    if ([string]::IsNullOrWhiteSpace($containerInput)) {
      "Scrolled page by x=$x y=$y"
    } else {
      "Scrolled container by x=$x y=${y}: $containerInput"
    }
  }
  default {
    if ([string]::IsNullOrWhiteSpace($containerInput)) {
      "Scrolled page to left=$left top=$top"
    } else {
      "Scrolled container to left=$left top=${top}: $containerInput"
    }
  }
}

Write-SilmarilCommandResult -Command "scroll" -Text $text -Data (Add-SilmarilTargetMetadata -Data $data -TargetContext $targetContext) -UseHost
