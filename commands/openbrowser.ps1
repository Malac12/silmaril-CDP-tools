param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if ($RemainingArgs.Count -ne 0) {
  throw "openbrowser takes no arguments."
}

$browserPath = Get-SilmarilBrowserPath
$userDataDir = Get-SilmarilUserDataDir
New-Item -Path $userDataDir -ItemType Directory -Force | Out-Null

$launchArgs = @(
  "--remote-debugging-port=9222"
  "--remote-allow-origins=*"
  "--no-first-run"
  "--no-default-browser-check"
  "--user-data-dir=$userDataDir"
  "--new-window"
  "about:blank"
)

if ($browserPath) {
  Start-Process -FilePath $browserPath -ArgumentList $launchArgs | Out-Null
}
else {
  Start-Process -FilePath "chrome.exe" -ArgumentList $launchArgs | Out-Null
}

$cdpReady = $false
for ($i = 0; $i -lt 8; $i++) {
  Start-Sleep -Milliseconds 400
  if (Test-SilmarilCdpReady -Port 9222) {
    $cdpReady = $true
    break
  }
}

if (-not $cdpReady) {
  throw "Browser launch did not expose CDP at 127.0.0.1:9222. No usable automation session was created."
}

Write-Host "Browser opened with CDP on port 9222."
