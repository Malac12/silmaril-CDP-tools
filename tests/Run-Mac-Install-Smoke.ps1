param(
  [string]$InstallerScript = "",
  [string]$RepoUrlOverride = "",
  [int]$Port = 9333
)

$ErrorActionPreference = 'Stop'

if (-not ((Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS)) {
  throw 'Run-Mac-Install-Smoke.ps1 must be executed on macOS.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($InstallerScript)) {
  $InstallerScript = Join-Path $repoRoot 'install-skill.sh'
}

if (-not (Test-Path -LiteralPath $InstallerScript)) {
  throw "Installer script not found: $InstallerScript"
}

function Assert-SilmarilTrue {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-FileContains {
  param(
    [string]$Path,
    [string]$ExpectedText
  )

  $content = Get-Content -LiteralPath $Path -Raw
  if ($content -notmatch [regex]::Escape($ExpectedText)) {
    throw ("Expected file '{0}' to contain '{1}'." -f $Path, $ExpectedText)
  }
}

$workspaceRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
  Join-Path $env:RUNNER_TEMP 'silmaril-installer-smoke'
}
else {
  Join-Path ([System.IO.Path]::GetTempPath()) 'silmaril-installer-smoke'
}

if (Test-Path -LiteralPath $workspaceRoot) {
  Remove-Item -LiteralPath $workspaceRoot -Recurse -Force
}

$scriptCopyDir = Join-Path $workspaceRoot 'script'
$toolkitDir = Join-Path $workspaceRoot 'toolkit'
$codexSkillsDir = Join-Path $workspaceRoot 'codex-skills'
$claudeSkillsDir = Join-Path $workspaceRoot 'claude-skills'

New-Item -ItemType Directory -Path $scriptCopyDir -Force | Out-Null

$installerCopy = Join-Path $scriptCopyDir 'install-skill.sh'
Copy-Item -LiteralPath $InstallerScript -Destination $installerCopy -Force

$bashArgs = @(
  $installerCopy,
  '--target', 'both',
  '--toolkit-dir', $toolkitDir,
  '--codex-skills-dir', $codexSkillsDir,
  '--claude-skills-dir', $claudeSkillsDir
)

if (-not [string]::IsNullOrWhiteSpace($RepoUrlOverride)) {
  $bashArgs += @('--repo-url', $RepoUrlOverride)
}

$output = & bash @bashArgs 2>&1
$exitCode = $LASTEXITCODE
foreach ($entry in @($output)) {
  $text = [string]$entry
  if (-not [string]::IsNullOrWhiteSpace($text)) {
    Write-Host ("TRACE_INSTALL " + $text)
  }
}

if ($exitCode -ne 0) {
  throw ("install-skill.sh failed with exit code {0}." -f $exitCode)
}

$toolkitCommand = Join-Path $toolkitDir 'silmaril-mac.sh'
$codexSkillDir = Join-Path $codexSkillsDir 'silmaril-cdp'
$claudeSkillDir = Join-Path $claudeSkillsDir 'silmaril-cdp'
$codexLocalPaths = Join-Path $codexSkillDir 'LOCAL_PATHS.md'
$claudeLocalPaths = Join-Path $claudeSkillDir 'LOCAL_PATHS.md'

Assert-SilmarilTrue -Condition (Test-Path -LiteralPath $toolkitCommand) -Message 'Installed toolkit launcher was not created.'
Assert-SilmarilTrue -Condition (Test-Path -LiteralPath (Join-Path $codexSkillDir 'SKILL.md')) -Message 'Codex skill install is missing SKILL.md.'
Assert-SilmarilTrue -Condition (Test-Path -LiteralPath (Join-Path $claudeSkillDir 'SKILL.md')) -Message 'Claude skill install is missing SKILL.md.'
Assert-SilmarilTrue -Condition (Test-Path -LiteralPath $codexLocalPaths) -Message 'Codex skill install is missing LOCAL_PATHS.md.'
Assert-SilmarilTrue -Condition (Test-Path -LiteralPath $claudeLocalPaths) -Message 'Claude skill install is missing LOCAL_PATHS.md.'

Assert-FileContains -Path $codexLocalPaths -ExpectedText ("- Toolkit root: " + $toolkitDir)
Assert-FileContains -Path $codexLocalPaths -ExpectedText ("- macOS launcher: " + $toolkitCommand)
Assert-FileContains -Path $claudeLocalPaths -ExpectedText ("- Toolkit root: " + $toolkitDir)
Assert-FileContains -Path $claudeLocalPaths -ExpectedText ("- macOS launcher: " + $toolkitCommand)

& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Run-Mac-Smoke.ps1') -SilmarilCommand $toolkitCommand -Port $Port
if ($LASTEXITCODE -ne 0) {
  throw 'Installed toolkit smoke test failed.'
}

Write-Host 'macOS installer smoke test completed successfully.'
