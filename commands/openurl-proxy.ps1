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

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTimeout -AllowPoll -DefaultPort 9222 -DefaultTimeoutMs 10000 -DefaultPollMs 200
$RemainingArgs = @($common.RemainingArgs)
$cdpPort = [int]$common.Port
$timeoutMs = [int]$common.TimeoutMs
$pollMs = [int]$common.PollMs

function Get-SilmarilListenerPid {
  param(
    [string]$ListenHost,
    [int]$Port
  )

  try {
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
      return $null
    }

    $listenerMatches = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if (-not $listenerMatches) {
      return $null
    }

    foreach ($conn in @($listenerMatches)) {
      if ($null -eq $conn) {
        continue
      }

      $addr = [string]$conn.LocalAddress
      $hostLower = $ListenHost.ToLowerInvariant()
      if (
        $hostLower -eq "0.0.0.0" -or
        $addr -eq $ListenHost -or
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

function Wait-SilmarilListener {
  param(
    [string]$ListenHost,
    [int]$Port,
    [int]$TimeoutMs = 8000,
    [int]$PollMs = 200
  )

  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    $listenerPid = Get-SilmarilListenerPid -ListenHost $ListenHost -Port $Port
    if ($null -ne $listenerPid) {
      return $listenerPid
    }
    Start-Sleep -Milliseconds $PollMs
  }

  return $null
}

if ($RemainingArgs.Count -lt 1) {
  throw "openurl-proxy requires a URL argument."
}

$rawTarget = $null
$listenHost = "127.0.0.1"
$listenPort = 8080
$rulesFile = Join-Path -Path $scriptRoot -ChildPath "tools\mitm\rules.json"
$profileDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath "Silmaril\chrome-proxy-safe-profile"
$allowMitm = $false
$allowNonLocalBind = $false
$i = 0

while ($i -lt $RemainingArgs.Count) {
  $arg = [string]$RemainingArgs[$i]
  $argLower = $arg.ToLowerInvariant()

  if ($i -eq 0 -and -not $arg.StartsWith("--")) {
    $rawTarget = $arg
    $i += 1
    continue
  }

  switch ($argLower) {
    "--listen-host" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "openurl-proxy --listen-host requires a value."
      }
      $listenHost = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--listen-port" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "openurl-proxy --listen-port requires an integer."
      }

      $rawPort = [string]$RemainingArgs[$i + 1]
      $parsedPort = 0
      if (-not [int]::TryParse($rawPort, [ref]$parsedPort)) {
        throw "openurl-proxy --listen-port must be an integer. Received: $rawPort"
      }
      if ($parsedPort -lt 1 -or $parsedPort -gt 65535) {
        throw "openurl-proxy --listen-port must be between 1 and 65535."
      }

      $listenPort = $parsedPort
      $i += 2
      continue
    }
    "--rules-file" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "openurl-proxy --rules-file requires a path."
      }
      $rulesFile = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--profile-dir" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "openurl-proxy --profile-dir requires a path."
      }
      $profileDir = [string]$RemainingArgs[$i + 1]
      $i += 2
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
    default {
      throw "Unsupported argument '$arg' for openurl-proxy."
    }
  }
}

if ([string]::IsNullOrWhiteSpace($rawTarget)) {
  throw "openurl-proxy requires a non-empty URL argument."
}

$resolvedPath = Resolve-Path -LiteralPath $rawTarget -ErrorAction SilentlyContinue
$url = $null
if ($resolvedPath) {
  $url = ([System.Uri]::new($resolvedPath.Path)).AbsoluteUri
}
else {
  $url = Normalize-SilmarilUrl -InputUrl $rawTarget
}

$acknowledgementSource = Resolve-SilmarilHighRiskAcknowledgement `
  -CommandName "openurl-proxy" `
  -FlagPresent $allowMitm `
  -RequiredFlag "--allow-mitm" `
  -EnvVar "SILMARIL_ALLOW_MITM" `
  -RiskDescription "local proxy-based traffic interception for browser navigation"

Assert-SilmarilLoopbackListenHost -CommandName "openurl-proxy" -ListenHost $listenHost -AllowNonLocalBind $allowNonLocalBind

$rulesResolved = Resolve-Path -LiteralPath $rulesFile -ErrorAction SilentlyContinue
if (-not $rulesResolved) {
  throw "Rules file not found: $rulesFile. Create a rule first with: silmaril.cmd proxy-override --allow-mitm --match ""..."" --file ""..."" --yes"
}
$rulesFile = [string]$rulesResolved.Path

$startedProxy = $false
$listenerPid = Get-SilmarilListenerPid -ListenHost $listenHost -Port $listenPort
if ($null -ne $listenerPid) {
  $listenerProcess = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
  if ($listenerProcess -and -not [string]::Equals($listenerProcess.ProcessName, "mitmdump", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Port $listenPort is occupied by process '$($listenerProcess.ProcessName)' (PID $listenerPid)."
  }
}
else {
  $proxyScript = Join-Path -Path $scriptRoot -ChildPath "commands\proxy-override.ps1"
  if (-not (Test-Path -LiteralPath $proxyScript)) {
    throw "Missing proxy command script: $proxyScript"
  }

  & $proxyScript -RemainingArgs @(
    "--rules-file"
    $rulesFile
    "--listen-host"
    $listenHost
    "--listen-port"
    ([string]$listenPort)
  ) | Out-Null

  $startedProxy = $true
  $listenerPid = Wait-SilmarilListener -ListenHost $listenHost -Port $listenPort -TimeoutMs $timeoutMs -PollMs $pollMs
  if ($null -eq $listenerPid) {
    throw "Proxy did not become ready on $listenHost`:$listenPort within $timeoutMs ms."
  }
}

$browserPath = Get-SilmarilBrowserPath
if ([string]::IsNullOrWhiteSpace($browserPath)) {
  $browserPath = "chrome.exe"
}

New-Item -Path $profileDir -ItemType Directory -Force | Out-Null

$launchArgs = @(
  "--remote-debugging-port=$cdpPort"
  "--remote-allow-origins=*"
  "--no-first-run"
  "--no-default-browser-check"
  "--user-data-dir=$profileDir"
  "--proxy-server=http://$listenHost`:$listenPort"
  "--new-window"
  $url
)

Start-Process -FilePath $browserPath -ArgumentList $launchArgs | Out-Null

$cdpReady = $false
$cdpDeadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
while ([DateTime]::UtcNow -lt $cdpDeadline) {
  if (Test-SilmarilCdpReady -Port $cdpPort) {
    $cdpReady = $true
    break
  }
  Start-Sleep -Milliseconds $pollMs
}

if (-not $cdpReady) {
  throw "Browser was launched but CDP was not ready on port $cdpPort within $timeoutMs ms."
}

Write-SilmarilCommandResult -Command "openurl-proxy" -Text "Opened URL through proxy: $url" -Data @{
  url          = $url
  listenHost   = $listenHost
  listenPort   = $listenPort
  proxyPid     = $listenerPid
  proxyStarted = $startedProxy
  rulesFile    = $rulesFile
  profileDir   = $profileDir
  browserPath  = $browserPath
  safeguard    = $acknowledgementSource
  port         = $cdpPort
  timeoutMs    = $timeoutMs
  pollMs       = $pollMs
} -UseHost



