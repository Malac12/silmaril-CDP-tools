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

function Test-SilmarilTruthyValue {
  param(
    [object]$Value
  )

  if ($null -eq $Value) {
    return $false
  }

  $normalized = ([string]$Value).Trim().ToLowerInvariant()
  return (
    $normalized -eq "1" -or
    $normalized -eq "true" -or
    $normalized -eq "yes" -or
    $normalized -eq "on"
  )
}

function Test-SilmarilLoopbackHost {
  param(
    [string]$ListenHost
  )

  if ([string]::IsNullOrWhiteSpace($ListenHost)) {
    return $false
  }

  $normalized = $ListenHost.Trim().TrimStart('[').TrimEnd(']').ToLowerInvariant()
  if ($normalized -eq "localhost") {
    return $true
  }

  $parsedAddress = $null
  if ([System.Net.IPAddress]::TryParse($normalized, [ref]$parsedAddress)) {
    return [System.Net.IPAddress]::IsLoopback($parsedAddress)
  }

  return $false
}

function Get-SilmarilCdpWebSocketUrl {
  param(
    [string]$WebSocketDebuggerUrl
  )

  if ([string]::IsNullOrWhiteSpace($WebSocketDebuggerUrl)) {
    return $WebSocketDebuggerUrl
  }

  try {
    $uri = [System.Uri]::new($WebSocketDebuggerUrl)
    if (-not ($uri.Scheme -eq "ws" -or $uri.Scheme -eq "wss")) {
      return $WebSocketDebuggerUrl
    }

    if (-not (Test-SilmarilLoopbackHost -ListenHost $uri.Host)) {
      return $WebSocketDebuggerUrl
    }

    $builder = [System.UriBuilder]::new($uri)
    $builder.Host = "127.0.0.1"
    return $builder.Uri.AbsoluteUri
  }
  catch {
    return $WebSocketDebuggerUrl
  }
}

function Resolve-SilmarilHighRiskAcknowledgement {
  param(
    [string]$CommandName,
    [bool]$FlagPresent,
    [string]$RequiredFlag,
    [string]$EnvVar,
    [string]$RiskDescription
  )

  if ($FlagPresent) {
    return "flag:$RequiredFlag"
  }

  $envValue = $null
  if (-not [string]::IsNullOrWhiteSpace($EnvVar) -and (Test-Path ("Env:" + $EnvVar))) {
    $envValue = (Get-Item ("Env:" + $EnvVar)).Value
  }

  if (Test-SilmarilTruthyValue -Value $envValue) {
    return "env:$EnvVar"
  }

  throw "$CommandName requires explicit safeguard flag $RequiredFlag because it enables $RiskDescription. For a trusted local session, set $EnvVar=1 instead."
}

function Assert-SilmarilLoopbackListenHost {
  param(
    [string]$CommandName,
    [string]$ListenHost,
    [bool]$AllowNonLocalBind = $false
  )

  if (Test-SilmarilLoopbackHost -ListenHost $ListenHost) {
    return
  }

  if ($AllowNonLocalBind) {
    return
  }

  throw "$CommandName requires a loopback listen host unless --allow-nonlocal-bind is provided."
}

function Get-SilmarilPlatform {
  $override = [string]$env:SILMARIL_PLATFORM
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    $normalizedOverride = $override.Trim().ToLowerInvariant()
    switch ($normalizedOverride) {
      "windows" { return "windows" }
      "macos" { return "macos" }
      "linux" { return "linux" }
      default { throw "Unsupported SILMARIL_PLATFORM override: $override" }
    }
  }

  $isWindowsPlatform = (
    ($PSVersionTable.PSEdition -eq "Desktop") -or
    ($env:OS -eq "Windows_NT") -or
    ((Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) -and $IsWindows)
  )
  if ($isWindowsPlatform) {
    return "windows"
  }

  $isMacPlatform = ((Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS)
  if ($isMacPlatform) {
    return "macos"
  }

  return "linux"
}

function Test-SilmarilWindowsPlatform {
  return ((Get-SilmarilPlatform) -eq "windows")
}

function Test-SilmarilMacOSPlatform {
  return ((Get-SilmarilPlatform) -eq "macos")
}

function Get-SilmarilCliName {
  $override = [string]$env:SILMARIL_CLI_NAME
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    return $override.Trim()
  }

  if (Test-SilmarilWindowsPlatform) {
    return "silmaril.cmd"
  }

  return "./silmaril-mac.sh"
}

function Get-SilmarilUserHome {
  $homePath = [string]$env:HOME
  if (-not [string]::IsNullOrWhiteSpace($homePath)) {
    return $homePath
  }

  $userProfile = [string]$env:USERPROFILE
  if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
    return $userProfile
  }

  try {
    $profilePath = [Environment]::GetFolderPath("UserProfile")
    if (-not [string]::IsNullOrWhiteSpace([string]$profilePath)) {
      return [string]$profilePath
    }
  }
  catch {
    # Fall back below.
  }

  return [System.IO.Path]::GetTempPath()
}

function Get-SilmarilAppRoot {
  $override = [string]$env:SILMARIL_APP_ROOT
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    return $override
  }

  if (Test-SilmarilWindowsPlatform) {
    $localAppData = [string]$env:LOCALAPPDATA
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
      return (Join-Path -Path $localAppData -ChildPath "Silmaril")
    }
  }
  elseif (Test-SilmarilMacOSPlatform) {
    return (Join-Path -Path (Get-SilmarilUserHome) -ChildPath "Library/Application Support/Silmaril")
  }
  else {
    return (Join-Path -Path (Get-SilmarilUserHome) -ChildPath ".local/share/Silmaril")
  }

  return (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "Silmaril")
}

function Get-SilmarilPowerShellPath {
  try {
    $currentProcessPath = (Get-Process -Id $PID -ErrorAction Stop).Path
    if (-not [string]::IsNullOrWhiteSpace([string]$currentProcessPath)) {
      return [string]$currentProcessPath
    }
  }
  catch {
    # Fall back below.
  }

  if (Test-SilmarilWindowsPlatform) {
    return "powershell"
  }

  return "pwsh"
}

function ConvertTo-SilmarilProcessArgumentString {
  param(
    [string[]]$ArgumentList
  )

  if (-not $ArgumentList) {
    return ""
  }

  $escapedArgs = @()
  foreach ($arg in $ArgumentList) {
    $text = [string]$arg
    if ($text.Contains('"')) {
      $text = $text.Replace('"', '\"')
    }

    if ([string]::IsNullOrWhiteSpace($text) -or $text -match '[\s"]') {
      $escapedArgs += ('"' + $text + '"')
    }
    else {
      $escapedArgs += $text
    }
  }

  return ($escapedArgs -join ' ')
}

function Get-SilmarilBrowserLaunchPath {
  $browserPath = Get-SilmarilBrowserPath
  if (-not [string]::IsNullOrWhiteSpace([string]$browserPath)) {
    return [string]$browserPath
  }

  if (Test-SilmarilWindowsPlatform) {
    return "chrome.exe"
  }

  if (Test-SilmarilMacOSPlatform) {
    throw "Google Chrome was not found on this Mac. Install Google Chrome in /Applications or ~/Applications."
  }

  throw "Supported browser not found for platform $(Get-SilmarilPlatform)."
}

function Start-SilmarilBrowserProcess {
  param(
    [string[]]$ArgumentList
  )

  $launchPath = Get-SilmarilBrowserLaunchPath
  if (Test-SilmarilWindowsPlatform) {
    Start-Process -FilePath $launchPath -ArgumentList $ArgumentList | Out-Null
    return $launchPath
  }

  $appRoot = Get-SilmarilAppRoot
  New-Item -ItemType Directory -Force -Path $appRoot | Out-Null
  $stdoutLog = Join-Path -Path $appRoot -ChildPath "browser-stdout.log"
  $stderrLog = Join-Path -Path $appRoot -ChildPath "browser-stderr.log"
  $argumentString = ConvertTo-SilmarilProcessArgumentString -ArgumentList $ArgumentList

  Start-Process -FilePath $launchPath -ArgumentList $argumentString -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog | Out-Null
  return $launchPath
}

function Test-SilmarilPortListening {
  param(
    [int]$Port
  )

  try {
    $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    foreach ($endpoint in @($listeners)) {
      if ($null -ne $endpoint -and [int]$endpoint.Port -eq $Port) {
        return $true
      }
    }
  }
  catch {
    return $false
  }

  return $false
}

function Get-SilmarilListenerPid {
  param(
    [string]$ListenHost = "",
    [int]$Port
  )

  if (Test-SilmarilWindowsPlatform) {
    try {
      if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        return $null
      }

      $listenerMatches = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
      if (-not $listenerMatches) {
        return $null
      }

      $normalizedHost = [string]$ListenHost
      if ([string]::IsNullOrWhiteSpace($normalizedHost)) {
        $normalizedHost = "127.0.0.1"
      }
      $hostLower = $normalizedHost.ToLowerInvariant()

      foreach ($conn in @($listenerMatches)) {
        if ($null -eq $conn) {
          continue
        }

        $addr = [string]$conn.LocalAddress
        if (
          $hostLower -eq "0.0.0.0" -or
          $addr -eq $normalizedHost -or
          $addr -eq "0.0.0.0" -or
          $addr -eq "::" -or
          $addr -eq "::1"
        ) {
          return [int]$conn.OwningProcess
        }
      }
    }
    catch {
      return $null
    }

    return $null
  }

  try {
    $lsofCommand = Get-Command "lsof" -ErrorAction SilentlyContinue
    if (-not $lsofCommand) {
      return $null
    }

    $lsofArgs = @("-nP", "-iTCP:$Port", "-sTCP:LISTEN", "-t")
    $lsofOutput = & $lsofCommand.Source @lsofArgs 2>$null
    $firstPid = @($lsofOutput | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) | Select-Object -First 1
    if (-not [string]::IsNullOrWhiteSpace([string]$firstPid)) {
      $parsedPid = 0
      if ([int]::TryParse([string]$firstPid, [ref]$parsedPid)) {
        return $parsedPid
      }
    }
  }
  catch {
    return $null
  }

  return $null
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

  $structuredPrefix = "SILMARIL_STRUCTURED_ERROR::"
  if ($errorMessage.StartsWith($structuredPrefix, [System.StringComparison]::Ordinal)) {
    $rawStructured = $errorMessage.Substring($structuredPrefix.Length)
    try {
      $structured = $rawStructured | ConvertFrom-Json
      $payload = [ordered]@{
        ok      = $false
        command = $Command
        code    = [string]$structured.code
        message = [string]$structured.message
        hint    = [string]$structured.hint
      }

      foreach ($name in @(Get-SilmarilPropertyNames -InputObject $structured)) {
        if (@("code", "message", "hint") -contains $name) {
          continue
        }

        $payload[$name] = $structured.$name
      }

      if ([string]::IsNullOrWhiteSpace([string]$payload.code)) {
        $payload.code = "COMMAND_FAILED"
      }
      if ([string]::IsNullOrWhiteSpace([string]$payload.message)) {
        $payload.message = "Unknown error."
      }
      if ([string]::IsNullOrWhiteSpace([string]$payload.hint)) {
        $payload.hint = "Review command output and retry."
      }

      return $payload
    }
    catch {
      $errorMessage = "Structured error payload could not be parsed."
    }
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
    $hint = "Start a browser session first, for example: $(Get-SilmarilCliName) openbrowser --port 9222"
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

function New-SilmarilStructuredErrorMessage {
  param(
    [hashtable]$Payload
  )

  if ($null -eq $Payload) {
    $Payload = [ordered]@{
      code    = "COMMAND_FAILED"
      message = "Unknown error."
      hint    = "Review command output and retry."
    }
  }

  return ("SILMARIL_STRUCTURED_ERROR::" + ($Payload | ConvertTo-Json -Compress -Depth 20))
}

function Get-SilmarilBrowserPath {
  $override = [string]$env:SILMARIL_BROWSER_PATH
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    if (Test-Path -LiteralPath $override) {
      $resolvedOverride = Resolve-Path -LiteralPath $override -ErrorAction SilentlyContinue
      if ($resolvedOverride) {
        return [string]$resolvedOverride.Path
      }

      return $override
    }

    throw "Configured SILMARIL_BROWSER_PATH does not exist: $override"
  }

  if (Test-SilmarilMacOSPlatform) {
    $macCandidates = @(
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      (Join-Path -Path (Get-SilmarilUserHome) -ChildPath "Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

    foreach ($candidate in $macCandidates) {
      if (Test-Path -LiteralPath $candidate) {
        return $candidate
      }
    }

    return $null
  }

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

  return (Join-Path -Path (Get-SilmarilAppRoot) -ChildPath ("chrome-cdp-profile-" + [string]$Port))
}

function Get-SilmarilProxyProfileDir {
  return (Join-Path -Path (Get-SilmarilAppRoot) -ChildPath "chrome-proxy-safe-profile")
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
    throw "Unable to query CDP on port $Port. Start browser first: $(Get-SilmarilCliName) openbrowser --port $Port"
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

function Get-SilmarilBrowserDebuggerWebSocketUrl {
  param(
    [int]$Port = 9222,
    [int]$TimeoutSec = 2
  )

  $versionEndpoint = "http://127.0.0.1:$Port/json/version"
  $versionInfo = Invoke-RestMethod -Method Get -Uri $versionEndpoint -TimeoutSec $TimeoutSec
  if (-not $versionInfo.webSocketDebuggerUrl) {
    throw "Browser CDP version endpoint did not include webSocketDebuggerUrl."
  }

  return (Get-SilmarilCdpWebSocketUrl -WebSocketDebuggerUrl ([string]$versionInfo.webSocketDebuggerUrl))
}

function Invoke-SilmarilActivateTarget {
  param(
    [int]$Port = 9222,
    [string]$TargetId,
    [int]$TimeoutSec = 2
  )

  if ([string]::IsNullOrWhiteSpace($TargetId)) {
    return [pscustomobject]@{
      Attempted = $false
      Activated = $false
      Method    = ""
      Error     = $null
    }
  }

  $endpoint = "http://127.0.0.1:$Port/json/activate/$([System.Uri]::EscapeDataString($TargetId))"
  try {
    Invoke-RestMethod -Method Get -Uri $endpoint -TimeoutSec $TimeoutSec | Out-Null
    return [pscustomobject]@{
      Attempted = $true
      Activated = $true
      Method    = "http-activate"
      Error     = $null
    }
  }
  catch {
    return [pscustomobject]@{
      Attempted = $true
      Activated = $false
      Method    = "http-activate"
      Error     = [string]$_.Exception.Message
    }
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
    $normalized.StartsWith("chrome-search://") -or
    $normalized.StartsWith("chrome://omnibox-popup.top-chrome/") -or
    $normalized.StartsWith("edge://omnibox-popup.top-chrome/") -or
    $normalized.StartsWith("chrome-untrusted://")
  )
}

function Test-SilmarilUserPageUrl {
  param(
    [string]$Url
  )

  if ([string]::IsNullOrWhiteSpace($Url)) {
    return $false
  }

  $normalized = $Url.ToLowerInvariant()
  return (
    $normalized.StartsWith("http://") -or
    $normalized.StartsWith("https://") -or
    $normalized.StartsWith("file:///")
  )
}

function Get-SilmarilStateRoot {
  $override = [string]$env:SILMARIL_STATE_DIR
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    return $override
  }

  return (Join-Path -Path (Get-SilmarilAppRoot) -ChildPath "state")
}

function Get-SilmarilTargetStatePath {
  param(
    [int]$Port = 9222,
    [ValidateSet("ephemeral", "pinned")]
    [string]$Kind = "ephemeral"
  )

  return (Join-Path -Path (Get-SilmarilStateRoot) -ChildPath ("target-state-" + [string]$Port + "-" + $Kind + ".json"))
}

function Get-SilmarilLegacyTargetStatePath {
  param(
    [int]$Port = 9222
  )

  return (Join-Path -Path (Get-SilmarilStateRoot) -ChildPath ("target-state-" + [string]$Port + ".json"))
}

function Get-SilmarilComparableUrl {
  param(
    [string]$Url
  )

  if ([string]::IsNullOrWhiteSpace($Url)) {
    return ""
  }

  try {
    $uri = [System.Uri]::new($Url)
    $builder = [System.UriBuilder]::new($uri)
    $builder.Fragment = ""
    $normalized = $builder.Uri.AbsoluteUri
    if ($normalized.EndsWith("/")) {
      return $normalized.TrimEnd("/")
    }
    return $normalized
  }
  catch {
    return ($Url.Trim()).TrimEnd("#")
  }
}

function Get-SilmarilTargetState {
  param(
    [int]$Port = 9222,
    [ValidateSet("ephemeral", "pinned")]
    [string]$Kind = "ephemeral"
  )

  $path = Get-SilmarilTargetStatePath -Port $Port -Kind $Kind
  $pathsToTry = @($path)
  if ($Kind -eq "ephemeral") {
    $legacyPath = Get-SilmarilLegacyTargetStatePath -Port $Port
    if ($legacyPath -ne $path) {
      $pathsToTry += $legacyPath
    }
  }

  $resolvedPath = $null
  foreach ($candidatePath in $pathsToTry) {
    if (Test-Path -LiteralPath $candidatePath) {
      $resolvedPath = $candidatePath
      break
    }
  }

  if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
    return $null
  }

  try {
    $raw = Get-Content -LiteralPath $resolvedPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return $null
    }

    $parsed = $raw | ConvertFrom-Json
    if ($null -ne $parsed -and -not (@(Get-SilmarilPropertyNames -InputObject $parsed) -contains "stateKind")) {
      $parsed | Add-Member -NotePropertyName stateKind -NotePropertyValue $Kind -Force
    }

    return $parsed
  }
  catch {
    return $null
  }
}

function Save-SilmarilTargetState {
  param(
    [int]$Port = 9222,
    [psobject]$Target,
    [string]$SelectionMode = "",
    [ValidateSet("ephemeral", "pinned")]
    [string]$Kind = "ephemeral"
  )

  if (-not $Target) {
    return
  }

  $path = Get-SilmarilTargetStatePath -Port $Port -Kind $Kind
  $parent = Split-Path -Parent $path
  try {
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $payload = [ordered]@{
      id             = [string]$Target.id
      url            = [string]$Target.url
      title          = [string]$Target.title
      type           = [string]$Target.type
      stateKind      = [string]$Kind
      selectionMode  = [string]$SelectionMode
      updatedAtUtc   = [DateTime]::UtcNow.ToString("o")
      comparableUrl  = Get-SilmarilComparableUrl -Url ([string]$Target.url)
    }

    Set-Content -LiteralPath $path -Encoding UTF8 -Value ($payload | ConvertTo-Json -Compress -Depth 10)
  }
  catch {
    # State tracking is best-effort and should never fail the command path.
  }
}

function Clear-SilmarilTargetState {
  param(
    [int]$Port = 9222,
    [ValidateSet("ephemeral", "pinned", "all")]
    [string]$Kind = "all"
  )

  $removed = [ordered]@{
    ephemeral = $false
    pinned    = $false
    legacy    = $false
  }

  $paths = @()
  switch ($Kind) {
    "ephemeral" {
      $paths += [pscustomobject]@{ Name = "ephemeral"; Path = (Get-SilmarilTargetStatePath -Port $Port -Kind "ephemeral") }
      $paths += [pscustomobject]@{ Name = "legacy"; Path = (Get-SilmarilLegacyTargetStatePath -Port $Port) }
    }
    "pinned" {
      $paths += [pscustomobject]@{ Name = "pinned"; Path = (Get-SilmarilTargetStatePath -Port $Port -Kind "pinned") }
    }
    default {
      $paths += [pscustomobject]@{ Name = "ephemeral"; Path = (Get-SilmarilTargetStatePath -Port $Port -Kind "ephemeral") }
      $paths += [pscustomobject]@{ Name = "pinned"; Path = (Get-SilmarilTargetStatePath -Port $Port -Kind "pinned") }
      $paths += [pscustomobject]@{ Name = "legacy"; Path = (Get-SilmarilLegacyTargetStatePath -Port $Port) }
    }
  }

  foreach ($entry in $paths) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Path)) {
      continue
    }

    if (Test-Path -LiteralPath $entry.Path) {
      Remove-Item -LiteralPath $entry.Path -Force -ErrorAction SilentlyContinue
      $removed[[string]$entry.Name] = -not (Test-Path -LiteralPath $entry.Path)
    }
  }

  return [pscustomobject]$removed
}

function Get-SilmarilAllTargetStates {
  param(
    [int]$Port = 9222
  )

  return [pscustomobject]@{
    pinned    = Get-SilmarilTargetState -Port $Port -Kind "pinned"
    ephemeral = Get-SilmarilTargetState -Port $Port -Kind "ephemeral"
  }
}

function Get-SilmarilSnapshotStatePath {
  param(
    [int]$Port = 9222
  )

  return (Join-Path -Path (Get-SilmarilStateRoot) -ChildPath ("snapshot-state-" + [string]$Port + ".json"))
}

function Get-SilmarilSnapshotState {
  param(
    [int]$Port = 9222
  )

  $path = Get-SilmarilSnapshotStatePath -Port $Port
  if (-not (Test-Path -LiteralPath $path)) {
    return $null
  }

  try {
    $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return $null
    }

    return ($raw | ConvertFrom-Json)
  }
  catch {
    return $null
  }
}

function Save-SilmarilSnapshotState {
  param(
    [int]$Port = 9222,
    [hashtable]$State
  )

  if ($null -eq $State) {
    return
  }

  $path = Get-SilmarilSnapshotStatePath -Port $Port
  $parent = Split-Path -Parent $path
  try {
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Set-Content -LiteralPath $path -Encoding UTF8 -Value ($State | ConvertTo-Json -Compress -Depth 30)
  }
  catch {
    # Snapshot state is best-effort and should not fail command paths.
  }
}

function Clear-SilmarilSnapshotState {
  param(
    [int]$Port = 9222
  )

  $path = Get-SilmarilSnapshotStatePath -Port $Port
  if (-not (Test-Path -LiteralPath $path)) {
    return $false
  }

  Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  return (-not (Test-Path -LiteralPath $path))
}

function Test-SilmarilSnapshotRefId {
  param(
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $false
  }

  return ([regex]::IsMatch($Value.Trim(), '^e\d+$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
}

function Test-SilmarilSnapshotRefMatch {
  param(
    [psobject]$Target,
    [psobject]$RefEntry,
    [int]$TimeoutSec = 10
  )

  if ($null -eq $Target) {
    throw "Target is required to validate snapshot refs."
  }
  if ($null -eq $RefEntry) {
    throw "Ref entry is required to validate snapshot refs."
  }

  $selector = [string]$RefEntry.selector
  if ([string]::IsNullOrWhiteSpace($selector)) {
    throw "Snapshot ref entry is missing selector."
  }

  $selectorJs = $selector | ConvertTo-Json -Compress
  $expectedTagJs = ([string]$RefEntry.tag) | ConvertTo-Json -Compress
  $expectedRoleJs = ([string]$RefEntry.role) | ConvertTo-Json -Compress
  $expectedLabelJs = ([string]$RefEntry.label) | ConvertTo-Json -Compress
  $expression = @"
(function(){
  var selector = $selectorJs;
  var expectedTag = $expectedTagJs;
  var expectedRole = $expectedRoleJs;
  var expectedLabel = $expectedLabelJs;

  var clean = function(value){
    return String(value || '').replace(/\s+/g, ' ').trim();
  };

  var getRole = function(el){
    if (!el) return '';
    var explicitRole = clean(el.getAttribute && el.getAttribute('role'));
    if (explicitRole) return explicitRole.toLowerCase();
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'a' && el.hasAttribute('href')) return 'link';
    if (tag === 'button') return 'button';
    if (tag === 'input') {
      var type = clean(el.getAttribute('type') || 'text').toLowerCase();
      if (type === 'button' || type === 'submit' || type === 'reset') return 'button';
      if (type === 'checkbox') return 'checkbox';
      if (type === 'radio') return 'radio';
      return 'textbox';
    }
    if (tag === 'textarea') return 'textbox';
    if (tag === 'select') return 'combobox';
    if (/^h[1-6]$/.test(tag)) return 'heading';
    if (tag === 'main') return 'main';
    if (tag === 'nav') return 'navigation';
    if (tag === 'header') return 'banner';
    if (tag === 'aside') return 'complementary';
    if (tag === 'footer') return 'contentinfo';
    if (tag === 'form') return 'form';
    if (tag === 'dialog') return 'dialog';
    return '';
  };

  var getLabel = function(el){
    if (!el) return '';
    var ariaLabel = clean(el.getAttribute && el.getAttribute('aria-label'));
    if (ariaLabel) return ariaLabel;
    var labelledBy = clean(el.getAttribute && el.getAttribute('aria-labelledby'));
    if (labelledBy) {
      var parts = labelledBy.split(/\s+/).map(function(id){
        var ref = document.getElementById(id);
        return clean(ref ? (ref.innerText || ref.textContent) : '');
      }).filter(Boolean);
      if (parts.length > 0) return clean(parts.join(' '));
    }
    if (typeof el.labels !== 'undefined' && el.labels && el.labels.length > 0) {
      var labelParts = Array.from(el.labels).map(function(labelEl){
        return clean(labelEl.innerText || labelEl.textContent);
      }).filter(Boolean);
      if (labelParts.length > 0) return clean(labelParts.join(' '));
    }
    var alt = clean(el.getAttribute && el.getAttribute('alt'));
    if (alt) return alt;
    var placeholder = clean(el.getAttribute && el.getAttribute('placeholder'));
    if (placeholder) return placeholder;
    var title = clean(el.getAttribute && el.getAttribute('title'));
    if (title) return title;
    var inner = clean(typeof el.innerText === 'string' ? el.innerText : el.textContent);
    return inner;
  };

  var el = document.querySelector(selector);
  if (!el) {
    return { ok: false, reason: 'not_found', selector: selector };
  }

  var actualTag = clean(el.tagName).toLowerCase();
  var actualRole = getRole(el);
  var actualLabel = getLabel(el);

  if (expectedTag && expectedTag.toLowerCase() !== actualTag) {
    return { ok: false, reason: 'tag_mismatch', selector: selector, actualTag: actualTag, actualRole: actualRole, actualLabel: actualLabel };
  }

  if (expectedRole && expectedRole.toLowerCase() !== actualRole) {
    return { ok: false, reason: 'role_mismatch', selector: selector, actualTag: actualTag, actualRole: actualRole, actualLabel: actualLabel };
  }

  if (expectedLabel && expectedLabel !== actualLabel) {
    return { ok: false, reason: 'label_mismatch', selector: selector, actualTag: actualTag, actualRole: actualRole, actualLabel: actualLabel };
  }

  return {
    ok: true,
    selector: selector,
    actualTag: actualTag,
    actualRole: actualRole,
    actualLabel: actualLabel
  };
})()
"@

  $evalResult = Invoke-SilmarilRuntimeEvaluate -Target $Target -Expression $expression -TimeoutSec $TimeoutSec
  return Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "snapshot-ref"
}

function Resolve-SilmarilSelectorInput {
  param(
    [string]$InputValue,
    [int]$Port = 9222,
    [object]$TargetContext,
    [int]$TimeoutMs = 10000
  )

  if ([string]::IsNullOrWhiteSpace($InputValue)) {
    throw "Selector cannot be empty."
  }

  $rawInput = [string]$InputValue
  if (-not (Test-SilmarilSnapshotRefId -Value $rawInput)) {
    $normalizedSelector = Normalize-SilmarilSelector -Selector $rawInput
    return [ordered]@{
      inputSelectorOrRef = $rawInput
      selector           = $rawInput
      normalizedSelector = $normalizedSelector
      resolvedSelector   = $normalizedSelector
      isRef              = $false
      resolvedRef        = $null
    }
  }

  if ($null -eq $TargetContext) {
    throw "Target context is required when resolving snapshot refs."
  }

  $snapshotState = Get-SilmarilSnapshotState -Port $Port
  if ($null -eq $snapshotState) {
    throw (New-SilmarilStructuredErrorMessage -Payload ([ordered]@{
      code    = "SNAPSHOT_NOT_FOUND"
      message = "No snapshot state exists for port $Port."
      hint    = "Run $(Get-SilmarilCliName) snapshot before using ref $rawInput."
      refId   = $rawInput
      port    = $Port
    }))
  }

  $snapshotTargetId = [string]$snapshotState.target.id
  $snapshotComparableUrl = [string]$snapshotState.target.comparableUrl
  $currentComparableUrl = Get-SilmarilComparableUrl -Url ([string]$TargetContext.ResolvedUrl)
  if (
    (-not [string]::IsNullOrWhiteSpace($snapshotTargetId) -and $snapshotTargetId -ne [string]$TargetContext.ResolvedTargetId) -or
    (-not [string]::IsNullOrWhiteSpace($snapshotComparableUrl) -and $snapshotComparableUrl -ne $currentComparableUrl)
  ) {
    throw (New-SilmarilStructuredErrorMessage -Payload ([ordered]@{
      code              = "REF_TARGET_MISMATCH"
      message           = "Ref $rawInput belongs to a different page target than the current selection."
      hint              = "Re-run $(Get-SilmarilCliName) snapshot on the current page before using ref $rawInput."
      refId             = $rawInput
      port              = $Port
      snapshotTargetId  = $snapshotTargetId
      currentTargetId   = [string]$TargetContext.ResolvedTargetId
      snapshotUrl       = [string]$snapshotState.target.url
      currentUrl        = [string]$TargetContext.ResolvedUrl
    }))
  }

  $refEntries = @()
  if ($snapshotState.PSObject.Properties.Name -contains "refs" -and $null -ne $snapshotState.refs) {
    $refEntries = @($snapshotState.refs)
  }
  $refEntry = $refEntries | Where-Object { [string]$_.id -ieq $rawInput } | Select-Object -First 1
  if ($null -eq $refEntry) {
    throw (New-SilmarilStructuredErrorMessage -Payload ([ordered]@{
      code          = "REF_NOT_FOUND"
      message       = "Ref $rawInput does not exist in the latest snapshot."
      hint          = "Run $(Get-SilmarilCliName) snapshot again and use one of the current refs."
      refId         = $rawInput
      snapshotToken = [string]$snapshotState.snapshotToken
      port          = $Port
    }))
  }

  $timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $TimeoutMs -PaddingMs 2000 -MinSeconds 10
  $validation = Test-SilmarilSnapshotRefMatch -Target $TargetContext.Target -RefEntry $refEntry -TimeoutSec $timeoutSec
  $validationProps = @(Get-SilmarilPropertyNames -InputObject $validation)
  if (($validationProps -contains "ok") -and -not [bool]$validation.ok) {
    $reason = if (($validationProps -contains "reason") -and $null -ne $validation.reason) { [string]$validation.reason } else { "unavailable" }
    throw (New-SilmarilStructuredErrorMessage -Payload ([ordered]@{
      code          = "REF_STALE"
      message       = "Ref $rawInput is no longer valid for the current page state."
      hint          = "Run $(Get-SilmarilCliName) snapshot again before using ref $rawInput."
      refId         = $rawInput
      snapshotToken = [string]$snapshotState.snapshotToken
      reason        = $reason
      storedLabel   = [string]$refEntry.label
      storedRole    = [string]$refEntry.role
      selector      = [string]$refEntry.selector
      port          = $Port
    }))
  }

  $resolvedRef = [ordered]@{
    id            = [string]$refEntry.id
    label         = [string]$refEntry.label
    kind          = [string]$refEntry.kind
    role          = [string]$refEntry.role
    tag           = [string]$refEntry.tag
    snapshotToken = [string]$snapshotState.snapshotToken
  }

  return [ordered]@{
    inputSelectorOrRef = $rawInput
    selector           = $rawInput
    normalizedSelector = [string]$refEntry.selector
    resolvedSelector   = [string]$refEntry.selector
    isRef              = $true
    resolvedRef        = $resolvedRef
  }
}

function Add-SilmarilSelectorResolutionMetadata {
  param(
    [object]$Data = @{},
    [object]$Resolution
  )

  if ($null -eq $Data) {
    $Data = [ordered]@{}
  }
  elseif (-not ($Data -is [System.Collections.IDictionary])) {
    $normalizedData = [ordered]@{}
    foreach ($name in @(Get-SilmarilPropertyNames -InputObject $Data)) {
      $normalizedData[$name] = $Data.$name
    }
    $Data = $normalizedData
  }
  if ($null -eq $Resolution) {
    return $Data
  }

  $Data["inputSelectorOrRef"] = [string]$Resolution.inputSelectorOrRef
  $Data["resolvedSelector"] = [string]$Resolution.resolvedSelector

  $resolvedRef = $null
  if ($Resolution -is [System.Collections.IDictionary]) {
    if ($Resolution.Contains("resolvedRef")) {
      $resolvedRef = $Resolution["resolvedRef"]
    }
  }
  elseif ($Resolution.PSObject.Properties.Name -contains "resolvedRef") {
    $resolvedRef = $Resolution.resolvedRef
  }

  if ($null -ne $resolvedRef) {
    $Data["resolvedRef"] = $resolvedRef
  }

  return $Data
}

function ConvertTo-SilmarilTargetCandidate {
  param(
    [object]$Target,
    [int]$Index = -1
  )

  return [ordered]@{
    index        = $Index
    id           = [string]$Target.id
    title        = [string]$Target.title
    url          = [string]$Target.url
    type         = [string]$Target.type
    isUserPage   = Test-SilmarilUserPageUrl -Url ([string]$Target.url)
    isDefaultTab = Test-SilmarilDefaultTabUrl -Url ([string]$Target.url)
  }
}

function Find-SilmarilTargetFromState {
  param(
    [object[]]$Pages,
    [object]$State,
    [string]$StatePrefix
  )

  if ($null -eq $State) {
    return $null
  }

  $stateTargetId = [string]$State.id
  if (-not [string]::IsNullOrWhiteSpace($stateTargetId)) {
    $idMatches = @($Pages | Where-Object { [string]$_.id -eq $stateTargetId })
    if ($idMatches.Count -gt 0) {
      return [pscustomobject]@{
        Target            = $idMatches[0]
        TargetStateSource = ($StatePrefix + "-target-id")
      }
    }
  }

  $stateUrl = [string]$State.url
  if (-not [string]::IsNullOrWhiteSpace($stateUrl)) {
    $exactUrlMatches = @($Pages | Where-Object { [string]$_.url -eq $stateUrl })
    if ($exactUrlMatches.Count -gt 0) {
      return [pscustomobject]@{
        Target            = $exactUrlMatches[0]
        TargetStateSource = ($StatePrefix + "-url")
      }
    }

    $comparableStateUrl = Get-SilmarilComparableUrl -Url $stateUrl
    if (-not [string]::IsNullOrWhiteSpace($comparableStateUrl)) {
      $comparableMatches = @(
        $Pages |
          Where-Object {
            (Get-SilmarilComparableUrl -Url ([string]$_.url)) -eq $comparableStateUrl
          }
      )

      if ($comparableMatches.Count -gt 0) {
        return [pscustomobject]@{
          Target            = $comparableMatches[0]
          TargetStateSource = ($StatePrefix + "-comparable-url")
        }
      }
    }
  }

  return $null
}

function Throw-SilmarilTargetAmbiguity {
  param(
    [int]$Port,
    [string]$RequestedUrlMatch,
    [object[]]$Candidates
  )

  $candidateList = @()
  for ($i = 0; $i -lt @($Candidates).Count; $i += 1) {
    $candidateList += ConvertTo-SilmarilTargetCandidate -Target $Candidates[$i] -Index $i
  }

  $payload = [ordered]@{
    code              = "TARGET_AMBIGUOUS"
    message           = "Multiple page targets matched regex: $RequestedUrlMatch"
    hint              = "Refine --url-match, use --target-id, or pin a target with $(Get-SilmarilCliName) target-pin."
    port              = $Port
    requestedUrlMatch = $RequestedUrlMatch
    candidateCount    = $candidateList.Count
    candidates        = $candidateList
  }

  throw (New-SilmarilStructuredErrorMessage -Payload $payload)
}

function Normalize-SilmarilSelector {
  param(
    [string]$Selector
  )

  if ([string]::IsNullOrWhiteSpace($Selector)) {
    return $Selector
  }

  $normalized = $Selector.Trim()

  if ($normalized.Length -ge 2) {
    $first = $normalized[0]
    $last = $normalized[$normalized.Length - 1]
    if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
      $normalized = $normalized.Substring(1, $normalized.Length - 2)
    }
  }

  $normalized = $normalized.Replace([char]0x2018, "'").Replace([char]0x2019, "'")
  $normalized = $normalized.Replace([char]0x201C, '"').Replace([char]0x201D, '"')

  $pattern = '\[(?<name>[^\]\s~\|\^\$\*=]+)(?<before>\s*)(?<op>[~\|\^\$\*]?=)(?<after>\s*)(?<value>[^\]\s"''`]+)\]'
  $normalized = [regex]::Replace(
    $normalized,
    $pattern,
    {
      param($match)

      $name = [string]$match.Groups["name"].Value
      $before = [string]$match.Groups["before"].Value
      $op = [string]$match.Groups["op"].Value
      $after = [string]$match.Groups["after"].Value
      $value = [string]$match.Groups["value"].Value

      if ([string]::IsNullOrWhiteSpace($value)) {
        return $match.Value
      }

      if ($value.StartsWith('"') -or $value.StartsWith("'")) {
        return $match.Value
      }

      $escapedValue = $value.Replace('\', '\\').Replace('"', '\"')
      return "[{0}{1}{2}{3}`"{4}`"]" -f $name, $before, $op, $after, $escapedValue
    }
  )

  return $normalized
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

function Resolve-SilmarilPageTarget {
  param(
    [int]$Port = 9222,
    [string]$TargetId = $null,
    [string]$UrlMatch = $null,
    [switch]$IgnoreSessionState
  )

  if (-not [string]::IsNullOrWhiteSpace($TargetId) -and -not [string]::IsNullOrWhiteSpace($UrlMatch)) {
    throw "Use either --target-id or --url-match, not both."
  }

  $pages = Get-SilmarilPageTargets -Port $Port
  $selected = $null
  $selectionMode = ""
  $targetStateSource = ""
  $candidateCount = 0
  $pinnedState = $null
  $ephemeralState = $null
  $activation = [pscustomobject]@{
    Attempted = $false
    Activated = $false
    Method    = ""
    Error     = $null
  }

  if (-not [string]::IsNullOrWhiteSpace($TargetId)) {
    $targetMatches = @($pages | Where-Object { [string]$_.id -eq $TargetId })
    if ($targetMatches.Count -eq 0) {
      $availableTargets = @(
        $pages |
          ForEach-Object {
            $idPart = [string]$_.id
            $urlPart = [string]$_.url
            if ([string]::IsNullOrWhiteSpace($urlPart)) {
              return $idPart
            }
            return ($idPart + " => " + $urlPart)
          } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      )
      $availableJoined = if ($availableTargets.Count -gt 0) { $availableTargets -join "; " } else { "none" }
      throw "Target id not found: $TargetId. Available targets: $availableJoined"
    }

    $selected = $targetMatches[0]
    $selectionMode = "explicit-target-id"
    $targetStateSource = "explicit-target-id"
  }
  elseif (-not [string]::IsNullOrWhiteSpace($UrlMatch)) {
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

    $candidateCount = $urlMatches.Count
    if ($urlMatches.Count -eq 1) {
      $selected = $urlMatches[0]
      $selectionMode = "explicit-url-match"
      $targetStateSource = "explicit-url-match"
    }
    else {
      $pinnedState = Get-SilmarilTargetState -Port $Port -Kind "pinned"
      $pinnedMatch = Find-SilmarilTargetFromState -Pages $urlMatches -State $pinnedState -StatePrefix "pinned"
      if ($null -ne $pinnedMatch) {
        $selected = $pinnedMatch.Target
        $selectionMode = "explicit-url-match"
        $targetStateSource = [string]$pinnedMatch.TargetStateSource
      }
      else {
        Throw-SilmarilTargetAmbiguity -Port $Port -RequestedUrlMatch $UrlMatch -Candidates $urlMatches
      }
    }
  }
  else {
    if (-not $IgnoreSessionState) {
      $pinnedState = Get-SilmarilTargetState -Port $Port -Kind "pinned"
      $ephemeralState = Get-SilmarilTargetState -Port $Port -Kind "ephemeral"
    }

    $savedSelection = Find-SilmarilTargetFromState -Pages $pages -State $pinnedState -StatePrefix "pinned"
    if ($null -eq $savedSelection) {
      $savedSelection = Find-SilmarilTargetFromState -Pages $pages -State $ephemeralState -StatePrefix "ephemeral"
    }

    if ($null -ne $savedSelection) {
      $selected = $savedSelection.Target
      $selectionMode = "saved-state"
      $targetStateSource = [string]$savedSelection.TargetStateSource
    }

    if ($null -eq $selected) {
      $preferredUserPages = @($pages | Where-Object { Test-SilmarilUserPageUrl -Url $_.url })
      if ($preferredUserPages.Count -gt 0) {
        $selected = $preferredUserPages[0]
        $selectionMode = "fallback"
        $targetStateSource = "preferred-user-page"
      }
      else {
        $preferred = @($pages | Where-Object { -not (Test-SilmarilDefaultTabUrl -Url $_.url) })
        if ($preferred.Count -gt 0) {
          $selected = $preferred[0]
          $selectionMode = "fallback"
          $targetStateSource = "preferred-non-default-page"
        }
        else {
          $selected = $pages[0]
          $selectionMode = "fallback"
          $targetStateSource = "first-page"
        }
      }
    }
  }

  $activation = Invoke-SilmarilActivateTarget -Port $Port -TargetId ([string]$selected.id)
  Write-SilmarilTrace -Message ("target port={0} pageCount={1} selection={2} source={3} id={4} url={5}" -f $Port, @($pages).Count, $selectionMode, $targetStateSource, [string]$selected.id, [string]$selected.url)
  Save-SilmarilTargetState -Port $Port -Target $selected -SelectionMode $selectionMode -Kind "ephemeral"

  return [pscustomobject]@{
    Target            = $selected
    Port              = $Port
    RequestedTargetId = $TargetId
    RequestedUrlMatch = $UrlMatch
    SelectionMode     = $selectionMode
    TargetStateSource = $targetStateSource
    ResolvedTargetId  = [string]$selected.id
    ResolvedUrl       = [string]$selected.url
    ResolvedTitle     = [string]$selected.title
    PageCount         = @($pages).Count
    CandidateCount    = $candidateCount
    TargetActivated   = [bool]$activation.Activated
    TargetActivationAttempted = [bool]$activation.Attempted
    TargetActivationMethod = [string]$activation.Method
    TargetActivationError = [string]$activation.Error
  }
}

function Get-SilmarilPreferredPageTarget {
  param(
    [int]$Port = 9222,
    [string]$TargetId = $null,
    [string]$UrlMatch = $null
  )

  $resolved = Resolve-SilmarilPageTarget -Port $Port -TargetId $TargetId -UrlMatch $UrlMatch
  return $resolved.Target
}

function Write-SilmarilTrace {
  param(
    [string]$Message
  )

  if (-not (Test-SilmarilTruthyValue -Value $env:SILMARIL_CDP_TRACE)) {
    return
  }

  if ([string]::IsNullOrWhiteSpace($Message)) {
    return
  }

  Write-Host ("SILMARIL_TRACE " + $Message)
}

function Add-SilmarilTargetMetadata {
  param(
    [hashtable]$Data = @{},
    [object]$TargetContext
  )

  if ($null -eq $Data) {
    $Data = [ordered]@{}
  }

  if ($null -eq $TargetContext) {
    return $Data
  }

  $Data["resolvedTargetId"] = [string]$TargetContext.ResolvedTargetId
  $Data["resolvedUrl"] = [string]$TargetContext.ResolvedUrl
  $Data["resolvedTitle"] = [string]$TargetContext.ResolvedTitle
  $Data["targetSelection"] = [string]$TargetContext.SelectionMode
  $Data["targetStateSource"] = [string]$TargetContext.TargetStateSource
  $Data["pageCount"] = [int]$TargetContext.PageCount
  if ($TargetContext.PSObject.Properties.Name -contains "CandidateCount") {
    $candidateCount = [int]$TargetContext.CandidateCount
    if ($candidateCount -gt 0) {
      $Data["candidateCount"] = $candidateCount
    }
  }
  if ($TargetContext.PSObject.Properties.Name -contains "TargetActivated") {
    $Data["targetActivated"] = [bool]$TargetContext.TargetActivated
  }
  if ($TargetContext.PSObject.Properties.Name -contains "TargetActivationMethod") {
    $method = [string]$TargetContext.TargetActivationMethod
    if (-not [string]::IsNullOrWhiteSpace($method)) {
      $Data["targetActivationMethod"] = $method
    }
  }
  if ($TargetContext.PSObject.Properties.Name -contains "TargetActivationError") {
    $activationError = [string]$TargetContext.TargetActivationError
    if (-not [string]::IsNullOrWhiteSpace($activationError)) {
      $Data["targetActivationError"] = $activationError
    }
  }
  return $Data
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

  $webSocketDebuggerUrl = Get-SilmarilCdpWebSocketUrl -WebSocketDebuggerUrl ([string]$Target.webSocketDebuggerUrl)
  Write-SilmarilTrace -Message ("cdp-websocket method={0} targetId={1} url={2}" -f $Method, [string]$Target.id, $webSocketDebuggerUrl)

  $nodePath = $null
  if (Test-SilmarilMacOSPlatform) {
    $nodeCommand = Get-Command "node" -ErrorAction SilentlyContinue
    if ($nodeCommand) {
      $nodePath = [string]$nodeCommand.Source
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($nodePath)) {
    $requestId = Get-Random -Minimum 100000 -Maximum 999999
    $payloadJson = @{
      id     = $requestId
      method = $Method
      params = $Params
    } | ConvertTo-Json -Compress -Depth 20
    $payloadBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payloadJson))
    $socketBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($webSocketDebuggerUrl))
    $browserSocketBase64 = ""
    try {
      $targetSocketUri = [System.Uri]$webSocketDebuggerUrl
      $browserSocketUrl = Get-SilmarilBrowserDebuggerWebSocketUrl -Port ([int]$targetSocketUri.Port) -TimeoutSec ([Math]::Max([Math]::Min($TimeoutSec, 5), 1))
      $browserSocketBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($browserSocketUrl))
      Write-SilmarilTrace -Message ("cdp-browser-websocket method={0} targetId={1} url={2}" -f $Method, [string]$Target.id, $browserSocketUrl)
    }
    catch {
      Write-SilmarilTrace -Message ("cdp-browser-websocket-unavailable method={0} targetId={1} message={2}" -f $Method, [string]$Target.id, [string]$_.Exception.Message)
    }

    Write-SilmarilTrace -Message ("cdp-send-node method={0} id={1} targetId={2}" -f $Method, $requestId, [string]$Target.id)

    $nodeScript = @'
const { Buffer } = require('node:buffer');
const [wsB64, payloadB64, timeoutMsRaw, browserWsB64 = '', targetIdRaw = ''] = process.argv.slice(2);
const wsUrl = Buffer.from(wsB64, 'base64').toString('utf8');
const browserWsUrl = browserWsB64 ? Buffer.from(browserWsB64, 'base64').toString('utf8') : '';
const payload = Buffer.from(payloadB64, 'base64').toString('utf8');
const timeoutMs = Number.parseInt(timeoutMsRaw, 10);
const WebSocketCtor = globalThis.WebSocket;
const targetId = String(targetIdRaw || '').trim();
const traceEnabled = (() => {
  const value = String(process.env.SILMARIL_CDP_TRACE || '').trim().toLowerCase();
  return value === '1' || value === 'true' || value === 'yes' || value === 'on';
})();

const trace = (message) => {
  if (!traceEnabled) {
    return;
  }

  process.stdout.write(`SILMARIL_TRACE_NODE ${message}\n`);
};

if (!WebSocketCtor) {
  process.stdout.write(JSON.stringify({ error: 'Node.js WebSocket API is unavailable.' }));
  process.exit(2);
}

let requestId = null;
let methodName = 'CDP';
let parsedPayload = null;
try {
  parsedPayload = JSON.parse(payload);
  requestId = parsedPayload.id;
  methodName = parsedPayload.method || methodName;
} catch (error) {
  process.stdout.write(JSON.stringify({ error: String(error && error.message ? error.message : error) }));
  process.exit(2);
}

const useBrowserSession = Boolean(browserWsUrl) && targetId.length > 0;
const activeWsUrl = useBrowserSession ? browserWsUrl : wsUrl;
const attachId = useBrowserSession ? requestId : null;
const runIfWaitingInnerId = useBrowserSession && methodName === 'Runtime.evaluate' ? (requestId + 1001) : null;
const runtimeEnableInnerId = useBrowserSession && methodName === 'Runtime.evaluate' ? (requestId + 1002) : null;
const commandInnerId = useBrowserSession ? (requestId + (runtimeEnableInnerId !== null ? 1003 : 1001)) : requestId;
let nextOuterId = requestId + 1;
let sessionId = '';
let runtimeEnabled = runtimeEnableInnerId === null;
let executionContextReady = runtimeEnableInnerId === null;
let commandSent = false;
let waitingForDebugger = false;
const outerMessageMap = new Map();

trace(`connect transport=${useBrowserSession ? 'browser-session' : 'page-socket'} url=${activeWsUrl} timeoutMs=${timeoutMs}`);

const finish = (code, value) => {
  if (settled) {
    return;
  }

  settled = true;
  clearTimeout(timer);
  try {
    ws.close();
  } catch (_) {
  }

  process.stdout.write(JSON.stringify(value));
  process.exit(code);
};

let settled = false;
const ws = new WebSocketCtor(activeWsUrl);
trace(`created readyState=${ws.readyState}`);
const timer = setTimeout(() => {
  trace(`timeout readyState=${ws.readyState}`);
  finish(3, { error: `Timed out waiting for CDP response to '${methodName}'.` });
}, timeoutMs);

const sendMessage = (message) => {
  const serialized = JSON.stringify(message);
  ws.send(serialized);
  trace(`sent bytes=${Buffer.byteLength(serialized)} id=${message.id || 0} method=${message.method || ''} session=${message.sessionId || ''}`);
};

const sendTargetMessage = (message) => {
  const serializedTargetMessage = JSON.stringify(message);
  const outerId = nextOuterId++;
  outerMessageMap.set(outerId, {
    innerId: message.id || 0,
    method: message.method || ''
  });
  sendMessage({
    id: outerId,
    method: 'Target.sendMessageToTarget',
    params: {
      sessionId,
      message: serializedTargetMessage
    }
  });
  trace(`sent-target outerId=${outerId} bytes=${Buffer.byteLength(serializedTargetMessage)} id=${message.id || 0} method=${message.method || ''}`);
};

const sendCommand = () => {
  if (commandSent) {
    return;
  }

  if (!runtimeEnabled || !executionContextReady) {
    return;
  }

  commandSent = true;
  if (useBrowserSession) {
    sendTargetMessage({
      id: commandInnerId,
      method: methodName,
      params: parsedPayload.params || {}
    });
    return;
  }

  sendMessage(parsedPayload);
};

ws.addEventListener('open', () => {
  trace(`open readyState=${ws.readyState}`);
  if (useBrowserSession) {
    sendMessage({
      id: attachId,
      method: 'Target.attachToTarget',
      params: {
        targetId
      }
    });
    return;
  }

  sendCommand();
});

ws.addEventListener('message', (event) => {
  const raw = typeof event.data === 'string'
    ? event.data
    : Buffer.from(event.data).toString('utf8');
  trace(`message type=${typeof event.data} bytes=${Buffer.byteLength(raw)}`);

  const packets = [];
  try {
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      packets.push(...parsed);
    } else {
      packets.push(parsed);
    }
  } catch (_) {
    return;
  }

  for (const packet of packets) {
    if (!packet) {
      continue;
    }

    if (packet.method) {
      trace(`packet method=${packet.method} session=${packet.sessionId || ''}`);
    }

    if (useBrowserSession && Object.prototype.hasOwnProperty.call(packet, 'id')) {
      const trackedOuterPacket = outerMessageMap.get(packet.id);
      if (trackedOuterPacket || packet.id === attachId || packet.error) {
        const errorMessage = packet.error && packet.error.message
          ? String(packet.error.message)
          : '';
        trace(`outer-packet id=${packet.id} trackedInnerId=${trackedOuterPacket ? trackedOuterPacket.innerId : 0} trackedMethod=${trackedOuterPacket ? trackedOuterPacket.method : ''} hasResult=${Object.prototype.hasOwnProperty.call(packet, 'result') ? 'true' : 'false'} error=${errorMessage}`);
        trace(`outer-packet-raw ${JSON.stringify(packet)}`);
      }
    }

    if (useBrowserSession && packet.method === 'Target.attachedToTarget') {
      if (packet.params && packet.params.sessionId && !sessionId) {
        sessionId = String(packet.params.sessionId);
      }

      if (packet.params && Object.prototype.hasOwnProperty.call(packet.params, 'waitingForDebugger')) {
        waitingForDebugger = Boolean(packet.params.waitingForDebugger);
        trace(`waiting-for-debugger=${waitingForDebugger ? 'true' : 'false'}`);
      }

      continue;
    }

    if (useBrowserSession && packet.method === 'Target.receivedMessageFromTarget') {
      const params = packet.params || {};
      const targetSessionId = params.sessionId ? String(params.sessionId) : '';
      if (!params.message) {
        continue;
      }

      if (sessionId && targetSessionId && targetSessionId !== sessionId) {
        continue;
      }

      const innerRaw = String(params.message);
      trace(`target-message bytes=${Buffer.byteLength(innerRaw)}`);

      let innerPacket = null;
      try {
        innerPacket = JSON.parse(innerRaw);
      } catch (_) {
        continue;
      }

      if (innerPacket.method) {
        trace(`target-packet method=${innerPacket.method}`);
      }

      if (innerPacket.method === 'Runtime.executionContextCreated') {
        executionContextReady = true;
        trace('execution-context-created');
        sendCommand();
        continue;
      }

      if (runIfWaitingInnerId !== null && innerPacket.id === runIfWaitingInnerId) {
        if (innerPacket.error) {
          finish(4, { error: `CDP Runtime.runIfWaitingForDebugger failed: ${innerPacket.error.message}` });
          return;
        }

        trace('runtime-resumed');
        sendTargetMessage({
          id: runtimeEnableInnerId,
          method: 'Runtime.enable',
          params: {}
        });
        continue;
      }

      if (runtimeEnableInnerId !== null && innerPacket.id === runtimeEnableInnerId) {
        if (innerPacket.error) {
          finish(4, { error: `CDP Runtime.enable failed: ${innerPacket.error.message}` });
          return;
        }

        runtimeEnabled = true;
        trace('runtime-enabled');
        sendCommand();
        continue;
      }

      if (innerPacket.id !== commandInnerId) {
        continue;
      }

      if (innerPacket.error) {
        finish(4, { error: `CDP ${methodName} failed: ${innerPacket.error.message}` });
        return;
      }

      if (!Object.prototype.hasOwnProperty.call(innerPacket, 'result')) {
        finish(5, { error: `CDP ${methodName} returned no result payload.` });
        return;
      }

      finish(0, { result: innerPacket.result });
      return;
    }

    if (useBrowserSession && packet.id === attachId) {
      if (packet.error) {
        finish(4, { error: `CDP Target.attachToTarget failed: ${packet.error.message}` });
        return;
      }

      sessionId = packet.result && packet.result.sessionId ? String(packet.result.sessionId) : '';
      if (!sessionId) {
        finish(5, { error: 'CDP Target.attachToTarget returned no sessionId.' });
        return;
      }

      trace(`attached sessionId=${sessionId}`);
      if (runtimeEnableInnerId !== null) {
        if (waitingForDebugger && runIfWaitingInnerId !== null) {
          sendTargetMessage({
            id: runIfWaitingInnerId,
            method: 'Runtime.runIfWaitingForDebugger',
            params: {}
          });
        }
        else {
          sendTargetMessage({
            id: runtimeEnableInnerId,
            method: 'Runtime.enable',
            params: {}
          });
        }
      }
      else {
        sendCommand();
      }
      continue;
    }

    if (packet.id !== commandInnerId) {
      continue;
    }

    if (packet.error) {
      finish(4, { error: `CDP ${methodName} failed: ${packet.error.message}` });
      return;
    }

    if (!Object.prototype.hasOwnProperty.call(packet, 'result')) {
      finish(5, { error: `CDP ${methodName} returned no result payload.` });
      return;
    }

    finish(0, { result: packet.result });
    return;
  }
});

ws.addEventListener('error', (event) => {
  const message = event && event.message ? event.message : 'Node WebSocket error.';
  trace(`error message=${String(message)}`);
  finish(6, { error: String(message) });
});

ws.addEventListener('close', (event) => {
  trace(`close code=${event && event.code ? event.code : 0} clean=${event && event.wasClean ? 'true' : 'false'} reason=${event && event.reason ? String(event.reason) : ''}`);
  if (!settled) {
    finish(7, { error: `CDP WebSocket closed before response for '${methodName}'.` });
  }
});
'@

    $invokeNodeBridge = {
      param(
        [string]$AttemptBrowserSocketBase64,
        [string]$AttemptTransport
      )

      Write-SilmarilTrace -Message ("cdp-send-node-attempt method={0} id={1} targetId={2} transport={3}" -f $Method, $requestId, [string]$Target.id, $AttemptTransport)
      $attemptOutput = $nodeScript | & $nodePath - $socketBase64 $payloadBase64 ([string]($TimeoutSec * 1000)) $AttemptBrowserSocketBase64 ([string]$Target.id) 2>&1
      $attemptExitCode = $LASTEXITCODE
      $attemptLines = @($attemptOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($attemptLines.Count -gt 1) {
        for ($index = 0; $index -lt ($attemptLines.Count - 1); $index++) {
          Write-SilmarilTrace -Message $attemptLines[$index]
        }
      }

      $attemptLine = @($attemptLines | Select-Object -Last 1)
      if ([string]::IsNullOrWhiteSpace($attemptLine)) {
        throw "Node.js CDP bridge returned no output for '$Method' over $AttemptTransport."
      }

      return [pscustomobject]@{
        ExitCode = $attemptExitCode
        Payload = ($attemptLine | ConvertFrom-Json)
      }
    }

    $nodeResult = & $invokeNodeBridge "" "page-socket"
    if (($nodeResult.ExitCode -ne 0) -and (-not [string]::IsNullOrWhiteSpace($browserSocketBase64))) {
      Write-SilmarilTrace -Message ("cdp-send-node-fallback method={0} id={1} targetId={2} from=page-socket to=browser-session message={3}" -f $Method, $requestId, [string]$Target.id, [string]$nodeResult.Payload.error)
      $nodeResult = & $invokeNodeBridge $browserSocketBase64 "browser-session"
    }

    if ($nodeResult.ExitCode -ne 0) {
      throw ([string]$nodeResult.Payload.error)
    }

    if ($null -eq $nodeResult.Payload.result) {
      throw "CDP $Method returned no result payload."
    }

    return $nodeResult.Payload.result
  }

  $socket = [System.Net.WebSockets.ClientWebSocket]::new()
  $requestId = Get-Random -Minimum 100000 -Maximum 999999
  $payload = @{
    id     = $requestId
    method = $Method
    params = $Params
  } | ConvertTo-Json -Compress -Depth 20
  Write-SilmarilTrace -Message ("cdp-send method={0} id={1} targetId={2}" -f $Method, $requestId, [string]$Target.id)

  try {
    $uri = [System.Uri]$webSocketDebuggerUrl
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $connectTimeout = [System.Threading.CancellationTokenSource]::new()
    try {
      $connectTimeout.CancelAfter([TimeSpan]::FromSeconds($TimeoutSec))
      $socket.ConnectAsync($uri, $connectTimeout.Token).GetAwaiter().GetResult()
    }
    catch [System.OperationCanceledException] {
      throw "Timed out connecting CDP WebSocket for '$Method'."
    }
    finally {
      $connectTimeout.Dispose()
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sendSegment = [ArraySegment[byte]]::new($bytes)
    $sendTimeout = [System.Threading.CancellationTokenSource]::new()
    try {
      $sendTimeout.CancelAfter([TimeSpan]::FromSeconds($TimeoutSec))
      $socket.SendAsync($sendSegment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $sendTimeout.Token).GetAwaiter().GetResult()
    }
    catch [System.OperationCanceledException] {
      throw "Timed out sending CDP request '$Method'."
    }
    finally {
      $sendTimeout.Dispose()
    }

    while ([DateTime]::UtcNow -lt $deadline) {
      $buffer = New-Object byte[] 65536
      $messageStream = New-Object System.IO.MemoryStream
      do {
        $readSegment = [ArraySegment[byte]]::new($buffer)
        $remainingMs = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remainingMs -le 0) {
          throw "Timed out waiting for CDP response to '$Method'."
        }

        $receiveTimeout = [System.Threading.CancellationTokenSource]::new()
        try {
          $receiveTimeout.CancelAfter($remainingMs)
          $receiveResult = $socket.ReceiveAsync($readSegment, $receiveTimeout.Token).GetAwaiter().GetResult()
        }
        catch [System.OperationCanceledException] {
          throw "Timed out waiting for CDP response to '$Method'."
        }
        finally {
          $receiveTimeout.Dispose()
        }

        if ($receiveResult.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
          throw "CDP WebSocket closed before response for '$Method'."
        }

        if ($receiveResult.Count -gt 0) {
          $messageStream.Write($buffer, 0, $receiveResult.Count)
        }
      } while (-not $receiveResult.EndOfMessage)

      $rawMessage = [System.Text.Encoding]::UTF8.GetString($messageStream.ToArray())
      $messageStream.Dispose()
      if (-not [string]::IsNullOrWhiteSpace($rawMessage)) {
        Write-SilmarilTrace -Message ("cdp-recv method={0} id={1} message={2}" -f $Method, $requestId, $rawMessage)
      }

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

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
  $lastError = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      return Invoke-SilmarilCdpCommand -Target $Target -Method "Runtime.evaluate" -Params @{
        expression    = $Expression
        returnByValue = $true
        awaitPromise  = $true
      } -TimeoutSec $TimeoutSec
    }
    catch {
      $lastError = $_.Exception
      $message = [string]$lastError.Message
      $isTransient = (
        $message -match "Execution context was destroyed" -or
        $message -match "Cannot find context with specified id"
      )

      if (-not $isTransient) {
        throw
      }

      Start-Sleep -Milliseconds 150
    }
  }

  if ($null -ne $lastError) {
    throw $lastError
  }

  throw "Timed out waiting for Runtime.evaluate to stabilize."
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

function Invoke-SilmarilVisualCursorCue {
  param(
    [psobject]$Target,
    [string]$Selector,
    [ValidateSet("click", "type")]
    [string]$Mode,
    [string]$Text = $null,
    [int]$TimeoutSec = 20
  )

  if ([string]::IsNullOrWhiteSpace($Selector)) {
    throw "Visual cursor selector cannot be empty."
  }

  $selectorJs = $Selector | ConvertTo-Json -Compress
  $modeJs = $Mode | ConvertTo-Json -Compress
  $textJs = if ($null -ne $Text) { $Text | ConvertTo-Json -Compress } else { "null" }

  $expression = @"
(async function(){
  var sel = $selectorJs;
  var mode = $modeJs;
  var typedText = $textJs;
  var rootId = '__silmaril_visual_cursor_root__';
  var styleId = '__silmaril_visual_cursor_style__';

  var wait = function(ms){
    return new Promise(function(resolve){ setTimeout(resolve, ms); });
  };

  var nextFrame = function(){
    return new Promise(function(resolve){ requestAnimationFrame(function(){ resolve(); }); });
  };

  var clamp = function(value, min, max){
    return Math.min(max, Math.max(min, value));
  };

  var dispatchInput = function(target, ch){
    try {
      if (typeof InputEvent === 'function') {
        target.dispatchEvent(new InputEvent('input', {
          bubbles: true,
          data: ch,
          inputType: 'insertText'
        }));
        return;
      }
    } catch (_) {}

    target.dispatchEvent(new Event('input', { bubbles: true }));
  };

  var placeCaretAtEnd = function(target){
    try {
      if ('value' in target && typeof target.setSelectionRange === 'function') {
        var n = String(target.value || '').length;
        target.setSelectionRange(n, n);
        return;
      }
    } catch (_) {}

    try {
      if (target.isContentEditable) {
        var selection = window.getSelection();
        if (!selection) return;
        var range = document.createRange();
        range.selectNodeContents(target);
        range.collapse(false);
        selection.removeAllRanges();
        selection.addRange(range);
      }
    } catch (_) {}
  };

  var setEditableValue = function(target, value){
    if ('value' in target) {
      target.value = value;
      placeCaretAtEnd(target);
      return;
    }

    target.textContent = value;
    placeCaretAtEnd(target);
  };

  var appendEditableChar = function(target, ch){
    if ('value' in target) {
      target.value = String(target.value || '') + ch;
      placeCaretAtEnd(target);
      return;
    }

    target.textContent = String(target.textContent || '') + ch;
    placeCaretAtEnd(target);
  };

  var getTypingDelay = function(ch, index){
    var base = 58 + ((index % 4) * 16);
    if (/[\s]/.test(ch)) return base + 26;
    if (/[,.!?;:]/.test(ch)) return base + 54;
    return base;
  };

  var removeNode = function(id){
    var node = document.getElementById(id);
    if (node && node.parentNode) {
      node.parentNode.removeChild(node);
    }
  };

  removeNode(rootId);
  removeNode(styleId);

  var overlayRoot = null;
  var overlayStyle = null;
  var restoreCaretColor = false;
  var previousCaretColor = '';
  var activeEditable = null;
  try {
    var el = document.querySelector(sel);
    if (!el) {
      return { ok: false, reason: 'not_found', selector: sel };
    }

    try {
      if (typeof el.scrollIntoView === 'function') {
        el.scrollIntoView({ block: 'center', inline: 'center' });
      }
    } catch (_) {
      try { el.scrollIntoView(); } catch (_) {}
    }

    await nextFrame();
    await wait(40);

    var rect = el.getBoundingClientRect();
    if (!rect || rect.width <= 0 || rect.height <= 0) {
      return { ok: false, reason: 'not_visible', selector: sel };
    }

    var host = document.documentElement || document.body;
    if (!host) {
      return { ok: false, reason: 'no_document_root', selector: sel };
    }

    overlayStyle = document.createElement('style');
    overlayStyle.id = styleId;
    overlayStyle.textContent = [
      '.silmaril-visual-root{position:fixed;inset:0;pointer-events:none;z-index:2147483647;overflow:hidden;}',
      '.silmaril-visual-cursor{position:fixed;left:0;top:0;opacity:1;transform-origin:4px 4px;transition:left 340ms cubic-bezier(0.2,0.85,0.18,1),top 340ms cubic-bezier(0.2,0.85,0.18,1),transform 160ms ease,opacity 120ms ease;filter:drop-shadow(0 2px 6px rgba(20,64,170,0.24));background-repeat:no-repeat;}',
      '.silmaril-visual-cursor--arrow{width:28px;height:40px;transform:translate(-2px,-2px) rotate(-2deg);background-size:28px 40px;background-image:url(\"data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2728%27 height=%2740%27 viewBox=%270 0 28 40%27%3E%3Cpath d=%27M3 2.5L3 31L10.9 24.5L15.5 36.3L20.8 33.9L16.2 22.4L25 22.4Z%27 fill=%27%23dbeafe%27 stroke=%27%231d4ed8%27 stroke-width=%272.1%27 stroke-linejoin=%27round%27/%3E%3Cpath d=%27M8.7 23.1L10.8 21.4L14.2 29.9L17.1 28.6L13.8 20.3L20.1 20.3Z%27 fill=%27%2393c5fd%27 opacity=%270.95%27/%3E%3C/svg%3E\");}',
      '.silmaril-visual-cursor--ibeam{width:22px;height:38px;transform:translate(-11px,-19px);transition:left 470ms cubic-bezier(0.2,0.85,0.18,1),top 470ms cubic-bezier(0.2,0.85,0.18,1),transform 180ms ease,opacity 120ms ease;background-size:22px 38px;background-image:url(\"data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%2722%27 height=%2738%27 viewBox=%270 0 22 38%27%3E%3Cpath d=%27M4.5 4.5H17.5M4.5 33.5H17.5M11 4.5V33.5%27 stroke=%27%231d4ed8%27 stroke-width=%273.6%27 stroke-linecap=%27round%27/%3E%3Cpath d=%27M7.2 9.2H14.8M7.2 28.8H14.8M11 7.2V30.8%27 stroke=%27%2360a5fa%27 stroke-width=%272.1%27 stroke-linecap=%27round%27 opacity=%270.98%27/%3E%3C/svg%3E\");}',
      '.silmaril-visual-cursor--pressed.silmaril-visual-cursor--arrow{transform:translate(-1px,-1px) rotate(-2deg) scale(0.95);}',
      '.silmaril-visual-cursor--pressed.silmaril-visual-cursor--ibeam{transform:translate(-11px,-19px) scale(0.95);}',
      '.silmaril-visual-pulse{position:fixed;left:0;top:0;width:12px;height:12px;border-radius:999px;transform:translate(-50%,-50%) scale(0.3);opacity:0;transition:transform 210ms ease,opacity 210ms ease;border:1.5px solid rgba(29,78,216,0.5);background:rgba(147,197,253,0.12);box-shadow:0 0 0 1px rgba(255,255,255,0.42) inset,0 0 8px rgba(29,78,216,0.12);}',
      '.silmaril-visual-pulse--active{opacity:0.85;transform:translate(-50%,-50%) scale(1.9);}'
    ].join('');

    (document.head || host).appendChild(overlayStyle);

    overlayRoot = document.createElement('div');
    overlayRoot.id = rootId;
    overlayRoot.className = 'silmaril-visual-root';

    var pulse = document.createElement('div');
    pulse.className = 'silmaril-visual-pulse';

    var tag = (el.tagName || '').toLowerCase();
    var inputType = (typeof el.type === 'string') ? el.type.toLowerCase() : '';
    var isTextInput = (
      tag === 'textarea' ||
      !!el.isContentEditable ||
      (tag === 'input' && (
        inputType === '' ||
        inputType === 'text' ||
        inputType === 'search' ||
        inputType === 'email' ||
        inputType === 'url' ||
        inputType === 'tel' ||
        inputType === 'password' ||
        inputType === 'number'
      ))
    );

    var cursorVariant = (mode === 'type' && isTextInput) ? 'silmaril-visual-cursor--ibeam' : 'silmaril-visual-cursor--arrow';
    var cursor = document.createElement('div');
    cursor.className = 'silmaril-visual-cursor ' + cursorVariant;

    overlayRoot.appendChild(pulse);
    overlayRoot.appendChild(cursor);
    host.appendChild(overlayRoot);

    var viewportWidth = Math.max(document.documentElement.clientWidth || 0, window.innerWidth || 0, 40);
    var viewportHeight = Math.max(document.documentElement.clientHeight || 0, window.innerHeight || 0, 40);
    var computedStyle = window.getComputedStyle(el);
    var paddingLeft = parseFloat((computedStyle && computedStyle.paddingLeft) ? computedStyle.paddingLeft : '0');
    if (!isFinite(paddingLeft)) {
      paddingLeft = 0;
    }

    var targetX = clamp(rect.left + (rect.width / 2), 14, Math.max(14, viewportWidth - 14));
    var targetY = clamp(rect.top + (rect.height / 2), 14, Math.max(14, viewportHeight - 14));
    if (cursorVariant === 'silmaril-visual-cursor--ibeam') {
      targetX = clamp(rect.left + Math.max(10, Math.min(paddingLeft + 6, rect.width - 10)), 14, Math.max(14, viewportWidth - 14));
    }
    var startX = clamp(targetX - 84, 14, Math.max(14, viewportWidth - 14));
    var startY = clamp(targetY - 56, 14, Math.max(14, viewportHeight - 14));

    cursor.style.left = startX + 'px';
    cursor.style.top = startY + 'px';
    pulse.style.left = targetX + 'px';
    pulse.style.top = targetY + 'px';

    await nextFrame();
    cursor.style.left = targetX + 'px';
    cursor.style.top = targetY + 'px';

    await wait(cursorVariant === 'silmaril-visual-cursor--ibeam' ? 520 : 360);

    if (mode === 'type' && isTextInput && typedText !== null) {
      activeEditable = el;
      if (typeof el.focus === 'function') {
        el.focus();
      }

      previousCaretColor = el.style.caretColor || '';
      el.style.caretColor = '#2563eb';
      restoreCaretColor = true;

      setEditableValue(el, '');
      dispatchInput(el, '');
      cursor.style.opacity = '0';
      pulse.classList.add('silmaril-visual-pulse--active');

      for (var idx = 0; idx < typedText.length; idx++) {
        var ch = typedText.charAt(idx);
        appendEditableChar(el, ch);
        dispatchInput(el, ch);
        await wait(getTypingDelay(ch, idx));
      }

      el.dispatchEvent(new Event('change', { bubbles: true }));
      await wait(260);

      return {
        ok: true,
        selector: sel,
        mode: mode,
        x: Math.round(targetX),
        y: Math.round(targetY),
        cursorVariant: cursorVariant,
        handledTyping: true
      };
    }

    cursor.classList.add('silmaril-visual-cursor--pressed');
    pulse.classList.add('silmaril-visual-pulse--active');

    await wait(mode === 'type' ? 280 : 230);

    return {
      ok: true,
      selector: sel,
      mode: mode,
      x: Math.round(targetX),
      y: Math.round(targetY),
      cursorVariant: cursorVariant,
      handledTyping: false
    };
  } catch (error) {
    return {
      ok: false,
      reason: 'visual_error',
      selector: sel,
      mode: mode,
      message: String((error && error.message) ? error.message : error)
    };
  } finally {
    if (restoreCaretColor && activeEditable) {
      try {
        activeEditable.style.caretColor = previousCaretColor;
      } catch (_) {}
    }
    if (overlayRoot && overlayRoot.parentNode) {
      overlayRoot.parentNode.removeChild(overlayRoot);
    }
    if (overlayStyle && overlayStyle.parentNode) {
      overlayStyle.parentNode.removeChild(overlayStyle);
    }
  }
})()
"@

  $evalResult = Invoke-SilmarilRuntimeEvaluate -Target $Target -Expression $expression -TimeoutSec $TimeoutSec
  return Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "visual-cursor"
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

  $selectorsJs = ConvertTo-Json -Compress -InputObject @($selectorList)
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



