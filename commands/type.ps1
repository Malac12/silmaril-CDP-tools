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

$usage = "type requires: ""selector"" ""text"" --yes [--visual-cursor], or ""selector"" --text-file ""path"" --yes [--visual-cursor]"
if ($RemainingArgs.Count -lt 3) {
  throw $usage
}

$selectorInput = [string]$RemainingArgs[0]
if ([string]::IsNullOrWhiteSpace($selectorInput)) {
  throw "Selector cannot be empty."
}

$confirmType = $false
$visualCursor = $false
$lastPayloadIndex = $RemainingArgs.Count - 1

while ($lastPayloadIndex -ge 1) {
  $tailArg = [string]$RemainingArgs[$lastPayloadIndex]
  $tailLower = $tailArg.ToLowerInvariant()

  if ($tailLower -eq "--yes") {
    $confirmType = $true
    $lastPayloadIndex -= 1
    continue
  }

  if ($tailLower -eq "--visual-cursor") {
    $visualCursor = $true
    $lastPayloadIndex -= 1
    continue
  }

  break
}

if (-not $confirmType) {
  throw "type requires explicit confirmation flag --yes"
}

$payloadArgs = @()
if ($lastPayloadIndex -ge 1) {
  $payloadArgs = $RemainingArgs[1..$lastPayloadIndex]
}

$maxPayloadBytes = 1048576
$textValue = $null
$inputMode = "inline"
$filePath = $null
$payloadBytes = 0

$fileFlags = @("--text-file", "--file")
$hasFileFlag = $false
foreach ($arg in $payloadArgs) {
  foreach ($fileFlag in $fileFlags) {
    if ([string]::Equals([string]$arg, $fileFlag, [System.StringComparison]::OrdinalIgnoreCase)) {
      $hasFileFlag = $true
      break
    }
  }
  if ($hasFileFlag) {
    break
  }
}

if ($hasFileFlag) {
  if ($payloadArgs.Count -ne 2) {
    throw "type does not allow combining inline text with --text-file. Use either type ""selector"" ""text"" --yes or type ""selector"" --text-file ""path"" --yes"
  }

  $flag = [string]$payloadArgs[0]
  if (-not ($fileFlags | Where-Object { [string]::Equals($flag, $_, [System.StringComparison]::OrdinalIgnoreCase) })) {
    throw "type file mode requires --text-file ""path""."
  }

  $rawPath = [string]$payloadArgs[1]
  if ([string]::IsNullOrWhiteSpace($rawPath)) {
    throw "type --text-file requires a non-empty file path."
  }

  $loaded = Read-SilmarilTextFile -Path $rawPath -Label "Text" -MaxBytes $maxPayloadBytes
  $filePath = [string]$loaded.path
  $inputMode = "file"
  $textValue = [string]$loaded.content
  $payloadBytes = [int64]$loaded.bytes
}
else {
  $textValue = ($payloadArgs -join " ")
  if ([string]::IsNullOrWhiteSpace($textValue)) {
    throw "Text value cannot be empty."
  }

  $payloadBytes = [System.Text.Encoding]::UTF8.GetByteCount($textValue)
}

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$target = $targetContext.Target
$selectorResolution = Resolve-SilmarilSelectorInput -InputValue $selectorInput -Port $port -TargetContext $targetContext -TimeoutMs $timeoutMs
$selector = [string]$selectorResolution.resolvedSelector
$selectorJs = $selector | ConvertTo-Json -Compress
$textJs = $textValue | ConvertTo-Json -Compress
$expression = @"
(async function(){
  var sel = $selectorJs;
  var txt = $textJs;
  var el = document.querySelector(sel);
  if (!el) return { ok: false, reason: 'not_found' };
  var tag = (el.tagName || '').toLowerCase();
  var isEditable = !!el.isContentEditable || tag === 'input' || tag === 'textarea';
  if (!isEditable) return { ok: false, reason: 'not_editable' };
  if (typeof el.scrollIntoView === 'function') { el.scrollIntoView({block:'center', inline:'center'}); }
  if (typeof el.focus === 'function') { el.focus(); }
  var previousValue = ('value' in el) ? String(el.value || '') : String(el.textContent || '');

  var waitForDomFlush = async function(){
    try {
      await Promise.resolve();
      await new Promise(function(resolve){
        if (typeof requestAnimationFrame === 'function') {
          requestAnimationFrame(function(){ resolve(); });
          return;
        }
        setTimeout(resolve, 0);
      });
    } catch (_) {}
  };

  var dispatchEditableEvent = function(name, inputType){
    try {
      if (typeof window.InputEvent === 'function' && (name === 'beforeinput' || name === 'input')) {
        el.dispatchEvent(new InputEvent(name, {
          bubbles: true,
          composed: true,
          cancelable: name === 'beforeinput',
          data: txt,
          inputType: inputType
        }));
        return;
      }
    } catch (_) {}
    el.dispatchEvent(new Event(name, { bubbles: true, composed: true }));
  };

  var setNativeValue = function(node, nextValue){
    if (!('value' in node)) {
      return false;
    }

    var prototypeChain = [];
    if (tag === 'input' && window.HTMLInputElement && window.HTMLInputElement.prototype) {
      prototypeChain.push(window.HTMLInputElement.prototype);
    }
    if (tag === 'textarea' && window.HTMLTextAreaElement && window.HTMLTextAreaElement.prototype) {
      prototypeChain.push(window.HTMLTextAreaElement.prototype);
    }

    var cursor = Object.getPrototypeOf(node);
    while (cursor) {
      prototypeChain.push(cursor);
      cursor = Object.getPrototypeOf(cursor);
    }

    for (var i = 0; i < prototypeChain.length; i++) {
      var proto = prototypeChain[i];
      if (!proto) continue;
      try {
        var descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
        if (descriptor && typeof descriptor.set === 'function') {
          descriptor.set.call(node, nextValue);
          return true;
        }
      } catch (_) {}
    }

    try {
      node.value = nextValue;
      return true;
    } catch (_) {
      return false;
    }
  };

  var inputType = previousValue.length > 0 ? 'insertReplacementText' : 'insertText';
  dispatchEditableEvent('beforeinput', inputType);

  if ('value' in el) {
    if (!setNativeValue(el, txt)) {
      return { ok: false, reason: 'not_editable' };
    }
    if (typeof el.setSelectionRange === 'function') {
      try {
        var n = el.value.length;
        el.setSelectionRange(n, n);
      } catch (_) {}
    }
  } else {
    el.textContent = txt;
  }

  dispatchEditableEvent('input', inputType);
  dispatchEditableEvent('change');
  await waitForDomFlush();

  var finalValue = ('value' in el) ? String(el.value || '') : String(el.textContent || '');
  if (finalValue !== txt) {
    return {
      ok: false,
      reason: 'value_mismatch',
      expected: txt,
      actual: finalValue,
      previousValue: previousValue
    };
  }

  return {
    ok: true,
    previousValue: previousValue,
    value: finalValue,
    inputType: inputType
  };
})()
"@

$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 2000 -MinSeconds 10
if ($visualCursor) {
  try {
    Invoke-SilmarilVisualCursorCue -Target $target -Selector $selector -Mode "type" -Text $textValue -TimeoutSec $timeoutSec | Out-Null
  }
  catch {
    Write-SilmarilTrace -Message ("Visual cursor cue failed for type selector '{0}': {1}" -f $selectorInput, $_.Exception.Message)
  }
}
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "type"
if ($null -eq $value) {
  throw "type result value is null."
}

$valueProps = @(Get-SilmarilPropertyNames -InputObject $value)
if (($valueProps -contains "ok") -and -not [bool]$value.ok) {
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "not_found") {
    throw "No element matched selector: $selectorInput"
  }
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "not_editable") {
    throw "Element is not editable for selector: $selectorInput"
  }
  if (($valueProps -contains "reason") -and [string]$value.reason -eq "value_mismatch") {
    $expectedText = if ($valueProps -contains "expected") { [string]$value.expected } else { $textValue }
    $actualText = if ($valueProps -contains "actual") { [string]$value.actual } else { "" }
    throw ("Typed value did not stick for selector: {0}. Expected '{1}' but found '{2}'." -f $selectorInput, $expectedText, $actualText)
  }

  throw "type failed for selector: $selectorInput"
}

$data = [ordered]@{
  selector    = $selectorInput
  normalizedSelector = $selector
  inputMode   = $inputMode
  bytes       = $payloadBytes
  visualCursor = $visualCursor
  port        = $port
  targetId    = $targetId
  urlMatch    = $urlMatch
}

if ($valueProps -contains "previousValue") {
  $data["previousValue"] = [string]$value.previousValue
}
if ($valueProps -contains "value") {
  $data["value"] = [string]$value.value
}
if ($valueProps -contains "inputType") {
  $data["inputType"] = [string]$value.inputType
}

if ($inputMode -eq "file" -and -not [string]::IsNullOrWhiteSpace($filePath)) {
  $data["filePath"] = $filePath
}

Write-SilmarilCommandResult -Command "type" -Text "Typed into selector: $selectorInput" -Data (Add-SilmarilTargetMetadata -Data (Add-SilmarilSelectorResolutionMetadata -Data $data -Resolution $selectorResolution) -TargetContext $targetContext) -UseHost

