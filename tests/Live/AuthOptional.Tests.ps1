BeforeAll {
  . (Join-Path $PSScriptRoot 'LiveTestHelpers.ps1')
}

Describe 'Silmaril Live Auth-Optional Regressions' -Tag 'LiveAuth' {
  It 'can inspect an authenticated X home timeline when a signed-in session exists' -Skip:($env:SILMARIL_RUN_LIVE_AUTH -ne '1') {
    if ([string]::IsNullOrWhiteSpace((Get-SilmarilBrowserPath))) {
      Set-ItResult -Skipped -Because 'Auth-required live test skipped: no supported browser found.'
      return
    }

    $port = if ([string]::IsNullOrWhiteSpace([string]$env:SILMARIL_LIVE_AUTH_PORT)) { 9222 } else { [int]$env:SILMARIL_LIVE_AUTH_PORT }
    (Invoke-SilmarilJson -CliArgs @('openbrowser', '--port', ([string]$port), '--timeout-ms', '20000', '--poll-ms', '300')).ok | Should -BeTrue
    (Invoke-SilmarilJson -CliArgs @('openurl', 'https://x.com/home', '--port', ([string]$port), '--timeout-ms', '12000')).ok | Should -BeTrue
    $timeline = $null
    try {
      $timeline = Invoke-SilmarilJsonEventually -CliArgs @('query', 'article', '--fields', 'text', '--limit', '5', '--port', ([string]$port), '--timeout-ms', '20000') -Attempts 10 -DelayMs 750 -Validator {
        param($payload)
        return ([int]$payload.returnedCount -gt 0)
      }
    }
    catch {
      Set-ItResult -Skipped -Because "Auth-required live test skipped: no signed-in X session found on profile port $port."
      return
    }

    $timeline.returnedCount | Should -BeGreaterThan 0
  }
}
