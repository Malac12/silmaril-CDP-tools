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

  $normalized = $ListenHost.Trim().ToLowerInvariant()
  return (
    $normalized -eq "127.0.0.1" -or
    $normalized -eq "localhost" -or
    $normalized -eq "::1"
  )
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

  $localAppData = [string]$env:LOCALAPPDATA
  if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
    return (Join-Path -Path $localAppData -ChildPath "Silmaril\state")
  }

  return (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "Silmaril\state")
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
    hint              = "Refine --url-match, use --target-id, or pin a target with silmaril.cmd target-pin."
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



