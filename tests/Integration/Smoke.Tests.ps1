$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$entryScript = Join-Path $repoRoot 'silmaril.ps1'
$fixture = Join-Path $repoRoot 'tests\fixtures\smoke-page.html'

function Invoke-SilmarilJson {
  param([string[]]$CliArgs)

  $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $entryScript @CliArgs '--json' 2>&1
  $line = ($output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($line)) {
    throw 'No output from silmaril command.'
  }

  return ($line | ConvertFrom-Json)
}

Describe 'Silmaril Integration Smoke' -Tag 'Integration' {
  It 'openbrowser openurl wait-for get-text' -Skip:($env:SILMARIL_RUN_INTEGRATION -ne '1') {
    $open = Invoke-SilmarilJson -CliArgs @('openbrowser', '--port', '9222', '--timeout-ms', '12000', '--poll-ms', '300')
    $open.ok | Should -BeTrue

    $openUrl = Invoke-SilmarilJson -CliArgs @('openurl', $fixture, '--port', '9222', '--timeout-ms', '5000')
    $openUrl.ok | Should -BeTrue

    $wait = Invoke-SilmarilJson -CliArgs @('wait-for', '#title', '--port', '9222', '--timeout-ms', '5000', '--poll-ms', '100')
    $wait.ok | Should -BeTrue

    $text = Invoke-SilmarilJson -CliArgs @('get-text', '#title', '--port', '9222', '--timeout-ms', '5000')
    $text.ok | Should -BeTrue
    $text.text | Should -Be 'Smoke Title'
  }
}


