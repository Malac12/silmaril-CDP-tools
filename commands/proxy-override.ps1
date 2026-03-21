param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if (-not $RemainingArgs) {
  $RemainingArgs = @()
}

function Resolve-SilmarilMitmdumpPath {
  param(
    [string]$ExplicitPath
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
    $resolved = Resolve-Path -LiteralPath $ExplicitPath -ErrorAction SilentlyContinue
    if (-not $resolved) {
      throw "mitmdump executable not found: $ExplicitPath"
    }
    return [string]$resolved.Path
  }

  $defaultCandidate = Join-Path -Path $env:USERPROFILE -ChildPath "tools\mitmproxy\12.2.1\mitmdump.exe"
  if (Test-Path -LiteralPath $defaultCandidate) {
    $resolvedDefault = Resolve-Path -LiteralPath $defaultCandidate -ErrorAction SilentlyContinue
    if ($resolvedDefault) {
      return [string]$resolvedDefault.Path
    }
  }

  $command = Get-Command "mitmdump.exe" -ErrorAction SilentlyContinue
  if (-not $command) {
    $command = Get-Command "mitmdump" -ErrorAction SilentlyContinue
  }

  if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
    return [string]$command.Source
  }

  throw "mitmdump executable not found. Use --mitmdump ""path-to-mitmdump.exe""."
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

function Get-SilmarilListenPid {
  param(
    [int]$Port
  )

  try {
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
      return $null
    }

    $listeners = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if (-not $listeners) {
      return $null
    }

    $first = @($listeners)[0]
    if ($null -eq $first) {
      return $null
    }

    return [int]$first.OwningProcess
  }
  catch {
    return $null
  }
}

function ConvertTo-SilmarilArgumentLine {
  param(
    [string[]]$InputArgs
  )

  $parts = @()
  foreach ($arg in @($InputArgs)) {
    $value = [string]$arg
    if ($null -eq $value) {
      $parts += '""'
      continue
    }

    $escaped = $value.Replace('"', '\"')
    if ([string]::IsNullOrWhiteSpace($escaped) -or $escaped -match '\s') {
      $parts += ('"' + $escaped + '"')
    }
    else {
      $parts += $escaped
    }
  }

  return ($parts -join " ")
}

$repoRoot = $scriptRoot
$addonScript = Join-Path -Path $repoRoot -ChildPath "tools\mitm\local_overrides.py"
$rulesFile = Join-Path -Path $repoRoot -ChildPath "tools\mitm\rules.json"
$listenHost = "127.0.0.1"
$listenPort = 8080
$matchRegex = $null
$localFileRaw = $null
$contentType = $null
$statusCode = 200
$confirmWrite = $false
$attachMode = $false
$dryRun = $false
$mitmdumpOverride = $null
$allowMitm = $false
$allowNonLocalBind = $false

$i = 0
while ($i -lt $RemainingArgs.Count) {
  $arg = [string]$RemainingArgs[$i]
  $argLower = $arg.ToLowerInvariant()

  switch ($argLower) {
    "--match" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-override --match requires a regex pattern."
      }
      $matchRegex = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--file" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-override --file requires a local file path."
      }
      $localFileRaw = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--rules-file" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-override --rules-file requires a path."
      }
      $rulesFile = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--listen-host" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-override --listen-host requires a value."
      }
      $listenHost = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--listen-port" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-override --listen-port requires an integer value."
      }
      $rawPort = [string]$RemainingArgs[$i + 1]
      $parsedPort = 0
      if (-not [int]::TryParse($rawPort, [ref]$parsedPort)) {
        throw "proxy-override --listen-port must be an integer. Received: $rawPort"
      }
      if ($parsedPort -lt 1 -or $parsedPort -gt 65535) {
        throw "proxy-override --listen-port must be between 1 and 65535."
      }
      $listenPort = $parsedPort
      $i += 2
      continue
    }
    "--content-type" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-override --content-type requires a MIME type value."
      }
      $contentType = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--status" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-override --status requires an integer HTTP status code."
      }
      $rawStatus = [string]$RemainingArgs[$i + 1]
      $parsedStatus = 0
      if (-not [int]::TryParse($rawStatus, [ref]$parsedStatus)) {
        throw "proxy-override --status must be an integer. Received: $rawStatus"
      }
      if ($parsedStatus -lt 100 -or $parsedStatus -gt 599) {
        throw "proxy-override --status must be between 100 and 599."
      }
      $statusCode = $parsedStatus
      $i += 2
      continue
    }
    "--mitmdump" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-override --mitmdump requires a path to mitmdump.exe."
      }
      $mitmdumpOverride = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--yes" {
      $confirmWrite = $true
      $i += 1
      continue
    }
    "--allow-mitm" {
      $allowMitm = $true
      $i += 1
      continue
    }
    "--allow-nonlocal-bind" {
      $allowNonLocalBind = $true
      $i += 1
      continue
    }
    "--attach" {
      $attachMode = $true
      $i += 1
      continue
    }
    "--dry-run" {
      $dryRun = $true
      $i += 1
      continue
    }
    default {
      throw "Unsupported flag '$arg' for proxy-override."
    }
  }
}

if (-not (Test-Path -LiteralPath $addonScript)) {
  throw "Missing mitm addon script: $addonScript"
}

Assert-SilmarilLoopbackListenHost -CommandName "proxy-override" -ListenHost $listenHost -AllowNonLocalBind $allowNonLocalBind

$hasMatch = -not [string]::IsNullOrWhiteSpace($matchRegex)
$hasFile = -not [string]::IsNullOrWhiteSpace($localFileRaw)
if ($hasMatch -xor $hasFile) {
  throw "proxy-override requires both --match and --file together."
}

$acknowledgementSource = $null
if (-not $dryRun) {
  $acknowledgementSource = Resolve-SilmarilHighRiskAcknowledgement `
    -CommandName "proxy-override" `
    -FlagPresent $allowMitm `
    -RequiredFlag "--allow-mitm" `
    -EnvVar "SILMARIL_ALLOW_MITM" `
    -RiskDescription "local proxy-based traffic interception and response overrides"
}

$resolvedRules = $rulesFile
$rulesResolvedInfo = Resolve-Path -LiteralPath $rulesFile -ErrorAction SilentlyContinue
if ($rulesResolvedInfo) {
  $resolvedRules = [string]$rulesResolvedInfo.Path
}
else {
  $rulesParent = Split-Path -Parent $rulesFile
  if ([string]::IsNullOrWhiteSpace($rulesParent)) {
    throw "Invalid --rules-file path: $rulesFile"
  }
  New-Item -Path $rulesParent -ItemType Directory -Force | Out-Null
  $resolvedRules = [System.IO.Path]::GetFullPath($rulesFile)
}

$resolvedLocalFile = $null
$didWriteRule = $false
$rulePlanned = $false
$ruleAction = "none"

if ($hasMatch) {
  if (-not $confirmWrite) {
    throw "proxy-override requires --yes when writing rule entries."
  }

  $localResolved = Resolve-Path -LiteralPath $localFileRaw -ErrorAction SilentlyContinue
  if (-not $localResolved) {
    throw "Local override file not found: $localFileRaw"
  }
  $resolvedLocalFile = [string]$localResolved.Path

  $rulesObject = [ordered]@{ rules = @() }
  if (Test-Path -LiteralPath $resolvedRules) {
    $rawRules = Get-Content -LiteralPath $resolvedRules -Raw -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($rawRules)) {
      try {
        $parsedRules = $rawRules | ConvertFrom-Json
      }
      catch {
        throw "Failed to parse rules file JSON: $resolvedRules"
      }

      if ($parsedRules) {
        $rulesObject = [ordered]@{}
        foreach ($prop in $parsedRules.PSObject.Properties) {
          $rulesObject[$prop.Name] = $prop.Value
        }
      }
    }
  }

  if (-not $rulesObject.Contains("rules") -or $null -eq $rulesObject["rules"]) {
    $rulesObject["rules"] = @()
  }

  $rulesList = @($rulesObject["rules"])
  $newRule = [ordered]@{
    match  = $matchRegex
    file   = $resolvedLocalFile
    status = $statusCode
  }
  if (-not [string]::IsNullOrWhiteSpace($contentType)) {
    $newRule["contentType"] = $contentType
  }

  $replaced = $false
  for ($idx = 0; $idx -lt $rulesList.Count; $idx++) {
    $existing = $rulesList[$idx]
    if ($null -eq $existing) {
      continue
    }

    $existingMatch = [string]$existing.match
    if ([string]::Equals($existingMatch, $matchRegex, [System.StringComparison]::Ordinal)) {
      $rulesList[$idx] = [pscustomobject]$newRule
      $replaced = $true
      break
    }
  }

  if ($replaced) {
    $ruleAction = "updated"
  }
  else {
    $rulesList += [pscustomobject]$newRule
    $ruleAction = "added"
  }

  $rulesObject["rules"] = @($rulesList)
  $rulePlanned = $true

  if (-not $dryRun) {
    $rulesJson = $rulesObject | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($resolvedRules, $rulesJson, [System.Text.UTF8Encoding]::new($false))
    $didWriteRule = $true
  }
}
elseif (-not (Test-Path -LiteralPath $resolvedRules)) {
  throw "Rules file not found: $resolvedRules. Provide --match and --file to create one."
}

$mitmdumpPath = Resolve-SilmarilMitmdumpPath -ExplicitPath $mitmdumpOverride

$mitmArgs = @(
  "-s"
  $addonScript
  "--listen-host"
  $listenHost
  "--listen-port"
  ([string]$listenPort)
)

$resultData = [ordered]@{
  rulesFile   = $resolvedRules
  addonScript = $addonScript
  mitmdump    = $mitmdumpPath
  listenHost  = $listenHost
  listenPort  = $listenPort
  attach      = $attachMode
  dryRun      = $dryRun
  safeguard   = if ($null -ne $acknowledgementSource) { $acknowledgementSource } else { "none" }
  rulePlanned = $rulePlanned
  ruleWritten = $didWriteRule
  ruleAction  = $ruleAction
}

if ($hasMatch) {
  $resultData["match"] = $matchRegex
  $resultData["file"] = $resolvedLocalFile
  $resultData["status"] = $statusCode
  if (-not [string]::IsNullOrWhiteSpace($contentType)) {
    $resultData["contentType"] = $contentType
  }
}

if ($dryRun) {
  $resultData["args"] = $mitmArgs
  Write-SilmarilCommandResult -Command "proxy-override" -Text "Dry run complete. Rule prepared and proxy launch command assembled." -Data $resultData
  exit 0
}

$hadPreviousRulesEnv = Test-Path Env:SILMARIL_MITM_RULES
$previousRulesEnv = $null
if ($hadPreviousRulesEnv) {
  $previousRulesEnv = $env:SILMARIL_MITM_RULES
}

try {
  $env:SILMARIL_MITM_RULES = $resolvedRules

  if ($attachMode) {
    if (Test-SilmarilJsonOutput) {
      $resultData["started"] = $true
      $attachPayload = [ordered]@{
        ok      = $true
        command = "proxy-override"
      }
      foreach ($key in @($resultData.Keys)) {
        $attachPayload[$key] = $resultData[$key]
      }
      Write-SilmarilJson -Value $attachPayload -Depth 20
    }
    else {
      Write-Host "Starting MITM proxy in attached mode. Press Ctrl+C to stop."
    }

    & $mitmdumpPath @mitmArgs
    if ($LASTEXITCODE -ne 0) {
      throw "mitmdump exited with code $LASTEXITCODE."
    }
  }
  else {
    if (Test-SilmarilPortListening -Port $listenPort) {
      throw "Port $listenPort is already listening. Stop the existing process or use --listen-port with a different value."
    }

    $argumentLine = ConvertTo-SilmarilArgumentLine -InputArgs $mitmArgs
    $process = Start-Process -FilePath $mitmdumpPath -ArgumentList $argumentLine -PassThru

    $isListening = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
      if (Test-SilmarilPortListening -Port $listenPort) {
        $isListening = $true
        break
      }

      Start-Sleep -Milliseconds 200
    }

    if (-not $isListening) {
      if ($process.HasExited) {
        $process.Refresh()
        throw "mitmdump exited before opening proxy port (exit code $($process.ExitCode))."
      }
      throw "Proxy did not start listening on port $listenPort in time."
    }

    $resultData["started"] = $true
    $listenPid = Get-SilmarilListenPid -Port $listenPort
    if ($null -ne $listenPid) {
      $resultData["pid"] = $listenPid
    }
    elseif (-not $process.HasExited) {
      $resultData["pid"] = $process.Id
    }

    Write-SilmarilCommandResult -Command "proxy-override" -Text "Proxy started in background. Use --attach to run in foreground." -Data $resultData
  }
}
finally {
  if ($hadPreviousRulesEnv) {
    $env:SILMARIL_MITM_RULES = $previousRulesEnv
  }
  else {
    Remove-Item Env:SILMARIL_MITM_RULES -ErrorAction SilentlyContinue
  }
}

