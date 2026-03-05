Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SilmarilPropertyNames {
  param(
    [object]$InputObject
  )

  if ($null -eq $InputObject) {
    return @()
  }

  $names = @()
  foreach ($prop in $InputObject.PSObject.Properties) {
    if ($null -ne $prop -and -not [string]::IsNullOrWhiteSpace($prop.Name)) {
      $names += $prop.Name
    }
  }

  return $names
}

function Parse-SilmarilCommonArgs {
  param(
    [Alias("Args")][string[]]$InputArgs,
    [switch]$AllowPort,
    [switch]$AllowTargetSelection,
    [switch]$AllowTimeout,
    [switch]$AllowPoll,
    [int]$DefaultPort = 9222,
    [int]$DefaultTimeoutMs = 10000,
    [int]$DefaultPollMs = 200
  )

  if (-not $InputArgs) {
    $InputArgs = @()
  }

  $port = $DefaultPort
  $timeoutMs = $DefaultTimeoutMs
  $pollMs = $DefaultPollMs
  $targetId = $null
  $urlMatch = $null
  $remaining = @()

  $i = 0
  while ($i -lt $InputArgs.Count) {
    $arg = [string]$InputArgs[$i]
    $argLower = $arg.ToLowerInvariant()

    switch ($argLower) {
      "--port" {
        if (-not $AllowPort) {
          $remaining += $arg
          $i += 1
          continue
        }

        if (($i + 1) -ge $InputArgs.Count) {
          throw "--port requires an integer value."
        }

        $rawPort = [string]$InputArgs[$i + 1]
        $parsedPort = 0
        if (-not [int]::TryParse($rawPort, [ref]$parsedPort)) {
          throw "--port must be an integer. Received: $rawPort"
        }
        if ($parsedPort -lt 1 -or $parsedPort -gt 65535) {
          throw "--port must be between 1 and 65535."
        }

        $port = $parsedPort
        $i += 2
        continue
      }
      "--target-id" {
        if (-not $AllowTargetSelection) {
          $remaining += $arg
          $i += 1
          continue
        }

        if (($i + 1) -ge $InputArgs.Count) {
          throw "--target-id requires a value."
        }

        $targetId = [string]$InputArgs[$i + 1]
        if ([string]::IsNullOrWhiteSpace($targetId)) {
          throw "--target-id cannot be empty."
        }

        $i += 2
        continue
      }
      "--url-match" {
        if (-not $AllowTargetSelection) {
          $remaining += $arg
          $i += 1
          continue
        }

        if (($i + 1) -ge $InputArgs.Count) {
          throw "--url-match requires a regex pattern."
        }

        $urlMatch = [string]$InputArgs[$i + 1]
        if ([string]::IsNullOrWhiteSpace($urlMatch)) {
          throw "--url-match cannot be empty."
        }

        $i += 2
        continue
      }
      "--timeout-ms" {
        if (-not $AllowTimeout) {
          $remaining += $arg
          $i += 1
          continue
        }

        if (($i + 1) -ge $InputArgs.Count) {
          throw "--timeout-ms requires an integer value."
        }

        $rawTimeout = [string]$InputArgs[$i + 1]
        $parsedTimeout = 0
        if (-not [int]::TryParse($rawTimeout, [ref]$parsedTimeout)) {
          throw "--timeout-ms must be an integer. Received: $rawTimeout"
        }
        if ($parsedTimeout -lt 100) {
          throw "--timeout-ms must be >= 100."
        }

        $timeoutMs = $parsedTimeout
        $i += 2
        continue
      }
      "--poll-ms" {
        if (-not $AllowPoll) {
          $remaining += $arg
          $i += 1
          continue
        }

        if (($i + 1) -ge $InputArgs.Count) {
          throw "--poll-ms requires an integer value."
        }

        $rawPoll = [string]$InputArgs[$i + 1]
        $parsedPoll = 0
        if (-not [int]::TryParse($rawPoll, [ref]$parsedPoll)) {
          throw "--poll-ms must be an integer. Received: $rawPoll"
        }
        if ($parsedPoll -lt 50) {
          throw "--poll-ms must be >= 50."
        }

        $pollMs = $parsedPoll
        $i += 2
        continue
      }
      default {
        $remaining += $arg
        $i += 1
      }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($targetId) -and -not [string]::IsNullOrWhiteSpace($urlMatch)) {
    throw "Use either --target-id or --url-match, not both."
  }

  return [ordered]@{
    RemainingArgs = @($remaining)
    Port          = $port
    TimeoutMs     = $timeoutMs
    PollMs        = $pollMs
    TargetId      = $targetId
    UrlMatch      = $urlMatch
  }
}

function Get-SilmarilErrorContract {
  param(
    [string]$Command,
    [string]$Message
  )

  $errorMessage = [string]$Message
  if ([string]::IsNullOrWhiteSpace($errorMessage)) {
    $errorMessage = "Unknown error."
  }

  $code = "COMMAND_FAILED"
  $hint = "Review command output and retry."

  if (
    $errorMessage -match "requires" -or
    $errorMessage -match "Unsupported" -or
    $errorMessage -match "must be" -or
    $errorMessage -match "cannot be empty" -or
    $errorMessage -match "exactly" -or
    $errorMessage -match "at least" -or
    $errorMessage -match "accepts at most" -or
    $errorMessage -match "Use either"
  ) {
    $code = "INVALID_ARGUMENT"
    $hint = "Check command arguments and required flags."
  }
  elseif (
    $errorMessage -match "Unable to query CDP" -or
    $errorMessage -match "No CDP targets" -or
    $errorMessage -match "No page targets" -or
    $errorMessage -match "Start browser first"
  ) {
    $code = "CDP_UNAVAILABLE"
    $hint = "Start a browser session first, for example: silmaril.cmd openbrowser --port 9222"
  }
  elseif ($errorMessage -match "Timed out" -or $errorMessage -match "timeout") {
    $code = "TIMEOUT"
    $hint = "Increase --timeout-ms or verify the expected page state."
  }
  elseif ($errorMessage -match "not found") {
    $code = "NOT_FOUND"
    $hint = "Verify target selectors, files, or target selection flags."
  }
  elseif ($errorMessage -match "JavaScript exception") {
    $code = "JS_EXCEPTION"
    $hint = "Inspect the JavaScript expression or switch to eval-js --file for debugging."
  }

  return [ordered]@{
    ok      = $false
    command = $Command
    code    = $code
    message = $errorMessage
    hint    = $hint
  }
}

function Get-SilmarilBrowserPath {
  $roots = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:LOCALAPPDATA
  ) | Where-Object { $_ }

  $relativePaths = @(
    "Google\Chrome\Application\chrome.exe",
    "Chromium\Application\chrome.exe",
    "Microsoft\Edge\Application\msedge.exe"
  )

  foreach ($root in $roots) {
    foreach ($relative in $relativePaths) {
      $candidate = Join-Path -Path $root -ChildPath $relative
      if (Test-Path -Path $candidate) {
        return $candidate
      }
    }
  }

  return $null
}

function Get-SilmarilUserDataDir {
  param(
    [int]$Port = 9222
  )

  return (Join-Path -Path $env:LOCALAPPDATA -ChildPath ("Silmaril\chrome-cdp-profile-" + [string]$Port))
}

function Get-SilmarilCdpTargets {
  param(
    [int]$Port = 9222,
    [int]$TimeoutSec = 5
  )

  $targetsEndpoint = "http://127.0.0.1:$Port/json/list"
  try {
    $targets = Invoke-RestMethod -Method Get -Uri $targetsEndpoint -TimeoutSec $TimeoutSec
  }
  catch {
    throw "Unable to query CDP on port $Port. Start browser first: silmaril.cmd openbrowser --port $Port"
  }

  if (-not $targets) {
    throw "No CDP targets found on port $Port."
  }

  return @($targets)
}

function Test-SilmarilCdpReady {
  param(
    [int]$Port = 9222
  )

  try {
    Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 1 | Out-Null
    return $true
  }
  catch {
    return $false
  }
}

function Normalize-SilmarilUrl {
  param(
    [string]$InputUrl
  )

  if ([string]::IsNullOrWhiteSpace($InputUrl)) {
    throw "openUrl requires a URL argument."
  }

  if ($InputUrl.StartsWith("//")) {
    return "https:$InputUrl"
  }

  return $InputUrl
}

function Test-SilmarilDefaultTabUrl {
  param(
    [string]$Url
  )

  if ([string]::IsNullOrWhiteSpace($Url)) {
    return $true
  }

  $normalized = $Url.ToLowerInvariant()
  return (
    $normalized -eq "about:blank" -or
    $normalized -eq "chrome://newtab/" -or
    $normalized -eq "edge://newtab/" -or
    $normalized.StartsWith("chrome-search://")
  )
}

function Get-SilmarilPageTargets {
  param(
    [int]$Port = 9222
  )

  $targets = Get-SilmarilCdpTargets -Port $Port
  $pages = @($targets | Where-Object { $_.type -eq "page" })
  if ($pages.Count -eq 0) {
    throw "No page targets found on port $Port."
  }

  return $pages
}

function Get-SilmarilPreferredPageTarget {
  param(
    [int]$Port = 9222,
    [string]$TargetId = $null,
    [string]$UrlMatch = $null
  )

  if (-not [string]::IsNullOrWhiteSpace($TargetId) -and -not [string]::IsNullOrWhiteSpace($UrlMatch)) {
    throw "Use either --target-id or --url-match, not both."
  }

  $pages = Get-SilmarilPageTargets -Port $Port

  if (-not [string]::IsNullOrWhiteSpace($TargetId)) {
    $targetMatches = @($pages | Where-Object { [string]$_.id -eq $TargetId })
    if ($targetMatches.Count -eq 0) {
      $availableIds = @($pages | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $availableJoined = if ($availableIds.Count -gt 0) { $availableIds -join ", " } else { "none" }
      throw "Target id not found: $TargetId. Available target ids: $availableJoined"
    }
    return $targetMatches[0]
  }

  if (-not [string]::IsNullOrWhiteSpace($UrlMatch)) {
    try {
      [void][regex]::new($UrlMatch)
    }
    catch {
      throw "Invalid --url-match regex: $UrlMatch"
    }

    $urlMatches = @($pages | Where-Object {
      $u = [string]$_.url
      -not [string]::IsNullOrWhiteSpace($u) -and $u -match $UrlMatch
    })

    if ($urlMatches.Count -eq 0) {
      throw "No page target URL matched regex: $UrlMatch"
    }

    $preferredMatched = @($urlMatches | Where-Object { -not (Test-SilmarilDefaultTabUrl -Url $_.url) })
    if ($preferredMatched.Count -gt 0) {
      return $preferredMatched[0]
    }

    return $urlMatches[0]
  }

  $preferred = @($pages | Where-Object { -not (Test-SilmarilDefaultTabUrl -Url $_.url) })
  if ($preferred.Count -gt 0) {
    return $preferred[0]
  }

  return $pages[0]
}

function Invoke-SilmarilCdpCommand {
  param(
    [psobject]$Target,
    [string]$Method,
    [hashtable]$Params = @{},
    [int]$TimeoutSec = 10
  )

  if (-not $Target) {
    throw "Target is required for CDP command '$Method'."
  }

  if (-not $Target.webSocketDebuggerUrl) {
    throw "Target does not include webSocketDebuggerUrl."
  }

  $socket = [System.Net.WebSockets.ClientWebSocket]::new()
  $requestId = Get-Random -Minimum 100000 -Maximum 999999
  $payload = @{
    id     = $requestId
    method = $Method
    params = $Params
  } | ConvertTo-Json -Compress -Depth 20

  try {
    $uri = [System.Uri]$Target.webSocketDebuggerUrl
    $token = [System.Threading.CancellationToken]::None
    $socket.ConnectAsync($uri, $token).GetAwaiter().GetResult()

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sendSegment = [ArraySegment[byte]]::new($bytes)
    $socket.SendAsync($sendSegment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $token).GetAwaiter().GetResult()

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
      $buffer = New-Object byte[] 65536
      $messageStream = New-Object System.IO.MemoryStream
      do {
        $readSegment = [ArraySegment[byte]]::new($buffer)
        $receiveResult = $socket.ReceiveAsync($readSegment, $token).GetAwaiter().GetResult()

        if ($receiveResult.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
          throw "CDP WebSocket closed before response for '$Method'."
        }

        if ($receiveResult.Count -gt 0) {
          $messageStream.Write($buffer, 0, $receiveResult.Count)
        }
      } while (-not $receiveResult.EndOfMessage)

      $rawMessage = [System.Text.Encoding]::UTF8.GetString($messageStream.ToArray())
      $messageStream.Dispose()

      if ([string]::IsNullOrWhiteSpace($rawMessage)) {
        continue
      }

      $parsed = $null
      try {
        $parsed = $rawMessage | ConvertFrom-Json
      }
      catch {
        continue
      }

      $messages = @($parsed)
      $matchedById = $null
      foreach ($message in $messages) {
        if (-not $message) {
          continue
        }

        $propertyNames = @(Get-SilmarilPropertyNames -InputObject $message)
        if (($propertyNames -contains "id") -and $message.id -eq $requestId) {
          $matchedById = $message
          break
        }
      }

      if (-not $matchedById) {
        continue
      }

      $selectedProps = @(Get-SilmarilPropertyNames -InputObject $matchedById)
      if (($selectedProps -contains "error") -and $null -ne $matchedById.error) {
        throw "CDP $Method failed: $($matchedById.error.message)"
      }

      if (-not ($selectedProps -contains "result")) {
        throw "CDP $Method returned no result payload."
      }

      return $matchedById.result
    }

    throw "Timed out waiting for CDP response to '$Method'."
  }
  finally {
    try {
      if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $socket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
      }
    }
    catch {
      # Ignore close failures.
    }
    $socket.Dispose()
  }
}

function ConvertTo-SilmarilTimeoutSec {
  param(
    [int]$TimeoutMs,
    [int]$PaddingMs = 5000,
    [int]$MinSeconds = 20
  )

  if ($TimeoutMs -lt 1) {
    throw "TimeoutMs must be positive."
  }

  $totalMs = [int64]$TimeoutMs + [int64]$PaddingMs
  $sec = [int][Math]::Ceiling($totalMs / 1000.0)
  if ($sec -lt $MinSeconds) {
    $sec = $MinSeconds
  }

  return $sec
}

function Invoke-SilmarilRuntimeEvaluate {
  param(
    [psobject]$Target,
    [string]$Expression,
    [int]$TimeoutSec = 20
  )

  if ([string]::IsNullOrWhiteSpace($Expression)) {
    throw "Runtime.evaluate expression cannot be empty."
  }

  return Invoke-SilmarilCdpCommand -Target $Target -Method "Runtime.evaluate" -Params @{
    expression    = $Expression
    returnByValue = $true
    awaitPromise  = $true
  } -TimeoutSec $TimeoutSec
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
  if (($evalProps -contains "exceptionDetails") -and $null -ne $EvalResult.exceptionDetails) {
    throw "Runtime.evaluate reported exceptionDetails for '$CommandName'."
  }

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

  throw "Runtime.evaluate result does not contain 'value'."
}

function Invoke-SilmarilSelectorWait {
  param(
    [psobject]$Target,
    [string[]]$Selectors,
    [ValidateSet("visible", "gone", "any-visible")]
    [string]$Mode,
    [int]$TimeoutMs = 10000,
    [int]$PollMs = 200,
    [switch]$IncludeCounts,
    [string]$CommandName = "wait",
    [int]$TimeoutSec = 0
  )

  $selectorList = @($Selectors | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
  if ($selectorList.Count -lt 1) {
    throw "$CommandName requires at least one selector."
  }

  if ($TimeoutMs -lt 100) {
    throw "TimeoutMs must be >= 100."
  }

  if ($PollMs -lt 50) {
    throw "PollMs must be >= 50."
  }

  $selectorsJs = $selectorList | ConvertTo-Json -Compress
  $modeJs = $Mode | ConvertTo-Json -Compress
  $timeoutJs = [string]$TimeoutMs
  $pollJs = [string]$PollMs
  $includeCountsJs = if ($IncludeCounts) { "true" } else { "false" }

  $expression = @"
(async function(){
  var sels = $selectorsJs;
  var mode = $modeJs;
  var includeCounts = $includeCountsJs;
  var timeoutMs = $timeoutJs;
  var intervalMs = $pollJs;
  var started = Date.now();

  var isVisible = function(el){
    if (!el || !el.isConnected) return false;
    var style = window.getComputedStyle(el);
    if (!style) return false;
    if (style.display === 'none') return false;
    if (style.visibility === 'hidden' || style.visibility === 'collapse') return false;
    if (parseFloat(style.opacity || '1') === 0) return false;
    var rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };

  var collectCounts = function(){
    var out = {};
    for (var i = 0; i < sels.length; i++) {
      var sel = sels[i];
      try {
        out[sel] = document.querySelectorAll(sel).length;
      } catch (_) {
        out[sel] = -1;
      }
    }
    return out;
  };

  while ((Date.now() - started) <= timeoutMs) {
    if (mode === 'visible' || mode === 'any-visible') {
      for (var i = 0; i < sels.length; i++) {
        var sel = sels[i];
        var nodes = null;
        try {
          nodes = document.querySelectorAll(sel);
        } catch (e) {
          return {
            ok: false,
            reason: 'invalid_selector',
            selector: sel,
            message: String((e && e.message) ? e.message : e),
            elapsedMs: Date.now() - started
          };
        }

        for (var j = 0; j < nodes.length; j++) {
          if (isVisible(nodes[j])) {
            var payload = {
              ok: true,
              matchedSelector: sel,
              elapsedMs: Date.now() - started
            };
            if (includeCounts) {
              payload.counts = collectCounts();
            }
            return payload;
          }
        }
      }
    }
    else if (mode === 'gone') {
      var allGone = true;
      for (var k = 0; k < sels.length; k++) {
        var selGone = sels[k];
        var nodesGone = null;
        try {
          nodesGone = document.querySelectorAll(selGone);
        } catch (e2) {
          return {
            ok: false,
            reason: 'invalid_selector',
            selector: selGone,
            message: String((e2 && e2.message) ? e2.message : e2),
            elapsedMs: Date.now() - started
          };
        }

        for (var p = 0; p < nodesGone.length; p++) {
          if (isVisible(nodesGone[p])) {
            allGone = false;
            break;
          }
        }

        if (!allGone) {
          break;
        }
      }

      if (allGone) {
        return {
          ok: true,
          elapsedMs: Date.now() - started,
          selectors: sels
        };
      }
    }
    else {
      return {
        ok: false,
        reason: 'invalid_mode',
        mode: mode,
        elapsedMs: Date.now() - started
      };
    }

    await new Promise(function(resolve){ setTimeout(resolve, intervalMs); });
  }

  var timeoutPayload = {
    ok: false,
    reason: 'timeout',
    elapsedMs: Date.now() - started,
    selectors: sels
  };
  if (includeCounts) {
    timeoutPayload.counts = collectCounts();
  }
  return timeoutPayload;
})()
"@

  $effectiveTimeoutSec = $TimeoutSec
  if ($effectiveTimeoutSec -lt 1) {
    $effectiveTimeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $TimeoutMs -PaddingMs 5000 -MinSeconds 20
  }

  $evalResult = Invoke-SilmarilRuntimeEvaluate -Target $Target -Expression $expression -TimeoutSec $effectiveTimeoutSec
  return Get-SilmarilEvalValue -EvalResult $evalResult -CommandName $CommandName
}

function Test-SilmarilJsonOutput {
  return ([string]$env:SILMARIL_OUTPUT_JSON -eq "1")
}

function Write-SilmarilJson {
  param(
    [object]$Value,
    [int]$Depth = 20
  )

  Write-Output ($Value | ConvertTo-Json -Depth $Depth -Compress)
}

function Write-SilmarilCommandResult {
  param(
    [string]$Command,
    [object]$Text = $null,
    [hashtable]$Data = @{},
    [switch]$UseHost,
    [int]$Depth = 20
  )

  if (Test-SilmarilJsonOutput) {
    $payload = [ordered]@{
      ok      = $true
      command = $Command
    }

    foreach ($key in @($Data.Keys)) {
      $payload[$key] = $Data[$key]
    }

    Write-SilmarilJson -Value $payload -Depth $Depth
    return
  }

  if ($null -eq $Text) {
    return
  }

  if ($UseHost) {
    Write-Host ([string]$Text)
    return
  }

  Write-Output ([string]$Text)
}

function Read-SilmarilTextFile {
  param(
    [string]$Path,
    [string]$Label = "Text",
    [int]$MaxBytes = 1048576
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Label file path cannot be empty."
  }

  if ($MaxBytes -lt 1) {
    throw "MaxBytes must be a positive integer."
  }

  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
  if (-not $resolved) {
    throw "$Label file not found: $Path"
  }

  $filePath = $resolved.Path
  $fileInfo = Get-Item -LiteralPath $filePath -ErrorAction SilentlyContinue
  if (-not $fileInfo) {
    throw "$Label file not found: $Path"
  }

  $byteLength = [int64]$fileInfo.Length
  if ($byteLength -gt $MaxBytes) {
    throw "$Label file exceeds max size of $MaxBytes bytes: $filePath ($byteLength bytes)"
  }

  $content = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
  if ($null -eq $content) {
    throw "$Label file is empty: $filePath"
  }

  if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
    $content = $content.Substring(1)
  }

  if ([string]::IsNullOrWhiteSpace($content)) {
    throw "$Label file is empty: $filePath"
  }

  return [ordered]@{
    path    = $filePath
    content = $content
    bytes   = $byteLength
  }
}



