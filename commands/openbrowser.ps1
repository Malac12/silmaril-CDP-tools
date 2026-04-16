param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1")

$parsed = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTimeout -AllowPoll -DefaultPort 9222 -DefaultTimeoutMs 3200 -DefaultPollMs 400
$RemainingArgs = @($parsed.RemainingArgs)
$port = [int]$parsed.Port
$timeoutMs = [int]$parsed.TimeoutMs
$pollMs = [int]$parsed.PollMs

if ($RemainingArgs.Count -ne 0) {
  throw "openbrowser takes no positional arguments. Supported flags: --port, --timeout-ms, --poll-ms"
}

$userDataDir = Get-SilmarilUserDataDir -Port $port
New-Item -Path $userDataDir -ItemType Directory -Force | Out-Null
Clear-SilmarilSnapshotState -Port $port | Out-Null

$launchArgs = @(
  "--remote-debugging-port=$port"
  "--remote-allow-origins=*"
  "--no-first-run"
  "--no-default-browser-check"
  "--user-data-dir=$userDataDir"
  "--new-window"
  "about:blank"
)

if (Test-SilmarilTruthyValue -Value $env:SILMARIL_BROWSER_HEADLESS) {
  $launchArgs = @(
    "--headless=new"
    "--disable-gpu"
    "--hide-scrollbars"
  ) + $launchArgs
}

$browserPath = Start-SilmarilBrowserProcess -ArgumentList $launchArgs

$ready = $false
$deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
while ([DateTime]::UtcNow -lt $deadline) {
  Start-Sleep -Milliseconds $pollMs
  if (Test-SilmarilCdpReady -Port $port) {
    $ready = $true
    break
  }
}

if (-not $ready) {
  throw "Browser launch did not expose CDP at 127.0.0.1:$port within $timeoutMs ms."
}

Write-SilmarilCommandResult -Command "openbrowser" -Text "Browser opened with CDP on port $port." -Data @{
  port       = $port
  timeoutMs  = $timeoutMs
  pollMs     = $pollMs
  userDataDir = $userDataDir
  browserPath = $browserPath
} -UseHost
