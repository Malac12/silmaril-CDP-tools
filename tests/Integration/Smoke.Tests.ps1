BeforeAll {
  $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $script:entryScript = Join-Path $script:repoRoot 'silmaril.ps1'
  $script:fixture = Join-Path $script:repoRoot 'tests/fixtures/smoke-page.html'
  . (Join-Path $script:repoRoot 'lib/common.ps1')

  $script:shellPath = (Get-Process -Id $PID).Path
  $script:shellArgs = @('-NoProfile')
  $script:isWindowsPlatform = (($PSVersionTable.PSEdition -eq 'Desktop') -or ($env:OS -eq 'Windows_NT') -or ((Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) -and $IsWindows))
  if ($script:isWindowsPlatform) {
    $script:shellArgs += @('-ExecutionPolicy', 'Bypass')
  }

  function Get-FreeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
      $listener.Start()
      return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
      $listener.Stop()
    }
  }

  function Invoke-SilmarilJson {
    param([string[]]$CliArgs)

    $output = & $script:shellPath @script:shellArgs -File $script:entryScript @CliArgs '--json' 2>&1
    $line = ($output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($line)) {
      throw 'No output from silmaril command.'
    }

    return ($line | ConvertFrom-Json)
  }
}

Describe 'Silmaril Integration Smoke' -Tag 'Integration' {
  It 'openbrowser openurl wait-for get-text' -Skip:($env:SILMARIL_RUN_INTEGRATION -ne '1') {
    if ([string]::IsNullOrWhiteSpace((Get-SilmarilBrowserPath))) {
      Set-ItResult -Skipped -Because 'Integration test skipped: no supported browser found.'
      return
    }

    $port = Get-FreeLoopbackPort

    $open = Invoke-SilmarilJson -CliArgs @('openbrowser', '--port', ([string]$port), '--timeout-ms', '12000', '--poll-ms', '300')
    $open.ok | Should -BeTrue

    $openUrl = Invoke-SilmarilJson -CliArgs @('openurl', $script:fixture, '--port', ([string]$port), '--timeout-ms', '5000')
    $openUrl.ok | Should -BeTrue

    $wait = Invoke-SilmarilJson -CliArgs @('wait-for', '#title', '--port', ([string]$port), '--timeout-ms', '5000', '--poll-ms', '100')
    $wait.ok | Should -BeTrue

    $text = Invoke-SilmarilJson -CliArgs @('get-text', '#title', '--port', ([string]$port), '--timeout-ms', '5000')
    $text.ok | Should -BeTrue
    $text.text | Should -Be 'Smoke Title'
  }

  It 'supports click and type with visual cursor mode' -Skip:($env:SILMARIL_RUN_INTEGRATION -ne '1') {
    if ([string]::IsNullOrWhiteSpace((Get-SilmarilBrowserPath))) {
      Set-ItResult -Skipped -Because 'Integration test skipped: no supported browser found.'
      return
    }

    $port = Get-FreeLoopbackPort

    (Invoke-SilmarilJson -CliArgs @('openbrowser', '--port', ([string]$port), '--timeout-ms', '12000', '--poll-ms', '300')).ok | Should -BeTrue
    (Invoke-SilmarilJson -CliArgs @('openurl', $script:fixture, '--port', ([string]$port), '--timeout-ms', '5000')).ok | Should -BeTrue
    (Invoke-SilmarilJson -CliArgs @('wait-for', '#go', '--port', ([string]$port), '--timeout-ms', '5000', '--poll-ms', '100')).ok | Should -BeTrue

    $click = Invoke-SilmarilJson -CliArgs @('click', '#go', '--yes', '--visual-cursor', '--port', ([string]$port), '--timeout-ms', '5000')
    $click.ok | Should -BeTrue
    $click.visualCursor | Should -BeTrue

    $status = Invoke-SilmarilJson -CliArgs @('get-text', '#status', '--port', ([string]$port), '--timeout-ms', '5000')
    $status.text | Should -Be 'Clicked'

    $type = Invoke-SilmarilJson -CliArgs @('type', '#name', 'Smoke Input', '--yes', '--visual-cursor', '--port', ([string]$port), '--timeout-ms', '5000')
    $type.ok | Should -BeTrue
    $type.visualCursor | Should -BeTrue

    $query = Invoke-SilmarilJson -CliArgs @('query', '#name', '--fields', 'value', '--limit', '1', '--port', ([string]$port), '--timeout-ms', '5000')
    $query.rows[0].value | Should -Be 'Smoke Input'
  }
}
