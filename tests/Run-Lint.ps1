$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$results = Invoke-ScriptAnalyzer -Path $repoRoot -Recurse -Severity Error
$results | ForEach-Object {
  "{0}:{1}: {2} {3}" -f $_.ScriptName, $_.Line, $_.Severity, $_.Message
} | Write-Output

if ($results.Count -gt 0) {
  exit 1
}
