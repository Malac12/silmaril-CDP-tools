[CmdletBinding()]
param(
  [string]$ToolkitDir,
  [string]$RepoUrl = "https://github.com/Malac12/silmaril-CDP-tools.git",
  [string]$ArchiveUrl = "https://github.com/Malac12/silmaril-CDP-tools/archive/refs/heads/main.zip",
  [switch]$Force,
  [switch]$SkipNpmInstall,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-InstallerStep {
  param(
    [string]$Message
  )

  Write-Host ("==> " + $Message)
}

function Test-SilmarilRepoRoot {
  param(
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }

  $skillPath = Join-Path -Path $Path -ChildPath "skills\silmaril-cdp\SKILL.md"
  $commandPath = Join-Path -Path $Path -ChildPath "silmaril.cmd"
  $bridgePackagePath = Join-Path -Path $Path -ChildPath "bridge-app\package.json"
  return (
    (Test-Path -LiteralPath $skillPath) -and
    (Test-Path -LiteralPath $commandPath) -and
    (Test-Path -LiteralPath $bridgePackagePath)
  )
}

function Get-DefaultToolkitDir {
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    return (Join-Path -Path $env:USERPROFILE -ChildPath "silmaril-cdp-tools")
  }

  return (Join-Path -Path $HOME -ChildPath "silmaril-cdp-tools")
}

function Install-SilmarilToolkitArchive {
  param(
    [string]$DestinationDir,
    [string]$DownloadUrl
  )

  $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("silmaril-bridge-install-" + [guid]::NewGuid().ToString("N"))
  $zipPath = Join-Path -Path $tempRoot -ChildPath "toolkit.zip"
  $extractRoot = Join-Path -Path $tempRoot -ChildPath "extract"

  New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
  New-Item -Path $extractRoot -ItemType Directory -Force | Out-Null

  try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipPath
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

    $expandedRepo = Get-ChildItem -Path $extractRoot -Directory | Select-Object -First 1
    if ($null -eq $expandedRepo) {
      throw "Downloaded archive did not contain a repository root directory."
    }

    Move-Item -LiteralPath $expandedRepo.FullName -Destination $DestinationDir
  }
  finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Resolve-SilmarilRepoRoot {
  param(
    [string]$RequestedToolkitDir,
    [bool]$ReplaceExisting,
    [bool]$SimulationMode,
    [string]$DownloadRepoUrl,
    [string]$DownloadArchiveUrl
  )

  if (Test-SilmarilRepoRoot -Path $PSScriptRoot) {
    return (Resolve-Path -LiteralPath $PSScriptRoot).Path
  }

  $destinationDir = $RequestedToolkitDir
  if ([string]::IsNullOrWhiteSpace($destinationDir)) {
    $destinationDir = Get-DefaultToolkitDir
  }

  if (Test-SilmarilRepoRoot -Path $destinationDir) {
    return (Resolve-Path -LiteralPath $destinationDir).Path
  }

  if (Test-Path -LiteralPath $destinationDir) {
    if (-not $ReplaceExisting) {
      throw "Existing path is not a Silmaril toolkit checkout: $destinationDir. Re-run with -Force to replace it."
    }

    if ($SimulationMode) {
      Write-InstallerStep "Would remove existing path: $destinationDir"
    }
    else {
      Remove-Item -LiteralPath $destinationDir -Recurse -Force
    }
  }

  if ($SimulationMode) {
    Write-InstallerStep "Would install toolkit repo to $destinationDir"
    return $destinationDir
  }

  $parentDir = Split-Path -Parent $destinationDir
  if (-not [string]::IsNullOrWhiteSpace($parentDir)) {
    New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
  }

  $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  if ($null -ne $gitCommand) {
    Write-InstallerStep "Cloning toolkit with git into $destinationDir"
    & git clone $DownloadRepoUrl $destinationDir
    if ($LASTEXITCODE -ne 0) {
      throw "git clone failed."
    }
  }
  else {
    Write-InstallerStep "git not found. Downloading toolkit archive into $destinationDir"
    Install-SilmarilToolkitArchive -DestinationDir $destinationDir -DownloadUrl $DownloadArchiveUrl
  }

  if (-not (Test-SilmarilRepoRoot -Path $destinationDir)) {
    throw "Installed toolkit checkout is missing required files: $destinationDir"
  }

  return (Resolve-Path -LiteralPath $destinationDir).Path
}

function Assert-BridgeAppFiles {
  param(
    [string]$ToolkitRoot
  )

  $bridgeDir = Join-Path -Path $ToolkitRoot -ChildPath "bridge-app"
  $packageJson = Join-Path -Path $bridgeDir -ChildPath "package.json"
  $launcherPath = Join-Path -Path $ToolkitRoot -ChildPath "run-bridge-app.cmd"
  $silmarilCommand = Join-Path -Path $ToolkitRoot -ChildPath "silmaril.cmd"

  if (-not (Test-Path -LiteralPath $packageJson)) {
    throw "Bridge app package.json not found: $packageJson"
  }
  if (-not (Test-Path -LiteralPath $launcherPath)) {
    throw "Bridge app launcher not found: $launcherPath"
  }
  if (-not (Test-Path -LiteralPath $silmarilCommand)) {
    throw "Toolkit command not found: $silmarilCommand"
  }
}

function Install-BridgeDependencies {
  param(
    [string]$ToolkitRoot,
    [bool]$SimulationMode
  )

  if ($SimulationMode) {
    Write-InstallerStep "Would install bridge-app npm dependencies"
    return
  }

  $npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if ($null -eq $npmCommand) {
    throw "npm.cmd was not found. Install Node.js 20+ and re-run the installer."
  }

  $bridgeDir = Join-Path -Path $ToolkitRoot -ChildPath "bridge-app"
  Write-InstallerStep "Installing bridge-app npm dependencies"
  Push-Location $bridgeDir
  try {
    & npm.cmd install
    if ($LASTEXITCODE -ne 0) {
      throw "npm install failed."
    }
  }
  finally {
    Pop-Location
  }
}

$resolvedToolkitDir = $ToolkitDir
if ([string]::IsNullOrWhiteSpace($resolvedToolkitDir)) {
  $resolvedToolkitDir = Get-DefaultToolkitDir
}

$repoRoot = Resolve-SilmarilRepoRoot -RequestedToolkitDir $resolvedToolkitDir -ReplaceExisting $Force.IsPresent -SimulationMode $DryRun.IsPresent -DownloadRepoUrl $RepoUrl -DownloadArchiveUrl $ArchiveUrl
Assert-BridgeAppFiles -ToolkitRoot $repoRoot

if (-not $SkipNpmInstall) {
  Install-BridgeDependencies -ToolkitRoot $repoRoot -SimulationMode $DryRun.IsPresent
}
elseif ($DryRun) {
  Write-InstallerStep "Would skip bridge-app npm install"
}

$launcherPath = Join-Path -Path $repoRoot -ChildPath "run-bridge-app.cmd"
$bridgeDir = Join-Path -Path $repoRoot -ChildPath "bridge-app"

Write-Host ""
if ($DryRun) {
  Write-Host "Dry run complete."
}
else {
  Write-Host "Installed Silmaril Electron bridge app successfully."
}

Write-Host ("Toolkit root: " + $repoRoot)
Write-Host ("Bridge app path: " + $bridgeDir)
Write-Host ("Launcher: " + $launcherPath)
Write-Host ("Run command: " + $launcherPath)
