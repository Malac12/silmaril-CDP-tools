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

  function New-TestTempDirectory {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().Guid)
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
  }

  function Get-TestMitmdumpPath {
    $defaultCandidate = Join-Path (Get-SilmarilUserHome) 'tools/mitmproxy/12.2.1/mitmdump.exe'
    if (Test-Path -LiteralPath $defaultCandidate) {
      return $defaultCandidate
    }

    foreach ($name in @('mitmdump.exe', 'mitmdump')) {
      $command = Get-Command $name -ErrorAction SilentlyContinue
      if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return [string]$command.Source
      }
    }

    return $null
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

  It 'supports openurl-proxy auto-start when MITM is explicitly acknowledged' -Skip:($env:SILMARIL_RUN_INTEGRATION -ne '1') {
    if ([string]::IsNullOrWhiteSpace((Get-SilmarilBrowserPath))) {
      Set-ItResult -Skipped -Because 'Integration test skipped: no supported browser found.'
      return
    }

    $mitmdumpPath = Get-TestMitmdumpPath
    if ([string]::IsNullOrWhiteSpace($mitmdumpPath)) {
      Set-ItResult -Skipped -Because 'Integration test skipped: mitmdump not found.'
      return
    }

    $cdpPort = Get-FreeLoopbackPort
    $listenPort = Get-FreeLoopbackPort
    $tempDir = New-TestTempDirectory
    $rulesFile = Join-Path $tempDir 'rules.json'
    $profileDir = Join-Path $tempDir 'profile'
    $fixtureUri = ([System.Uri]::new((Resolve-Path -LiteralPath $script:fixture).Path)).AbsoluteUri
    Set-Content -LiteralPath $rulesFile -Value '{"rules":[]}' -Encoding UTF8

    $proxyPid = $null
    try {
      $open = Invoke-SilmarilJson -CliArgs @(
        'openurl-proxy',
        $script:fixture,
        '--allow-mitm',
        '--port', ([string]$cdpPort),
        '--listen-port', ([string]$listenPort),
        '--rules-file', $rulesFile,
        '--profile-dir', $profileDir,
        '--timeout-ms', '15000',
        '--poll-ms', '200'
      )

      $open.ok | Should -BeTrue
      $open.proxyStarted | Should -BeTrue
      $open.safeguard | Should -Be 'flag:--allow-mitm'
      $open.url | Should -Be $fixtureUri
      $proxyPid = $open.proxyPid

      (Invoke-SilmarilJson -CliArgs @('wait-for', '#title', '--port', ([string]$cdpPort), '--timeout-ms', '5000', '--poll-ms', '100')).ok | Should -BeTrue
      $text = Invoke-SilmarilJson -CliArgs @('get-text', '#title', '--port', ([string]$cdpPort), '--timeout-ms', '5000')
      $text.text | Should -Be 'Smoke Title'
    }
    finally {
      if ($null -ne $proxyPid) {
        Stop-Process -Id $proxyPid -Force -ErrorAction SilentlyContinue
      }
      Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'captures final-dom from the last effective run port' -Skip:($env:SILMARIL_RUN_INTEGRATION -ne '1') {
    if ([string]::IsNullOrWhiteSpace((Get-SilmarilBrowserPath))) {
      Set-ItResult -Skipped -Because 'Integration test skipped: no supported browser found.'
      return
    }

    $defaultPort = Get-FreeLoopbackPort
    $flowPort = Get-FreeLoopbackPort
    $tempDir = New-TestTempDirectory
    $artifactsDir = Join-Path $tempDir 'artifacts'
    $flowPath = Join-Path $tempDir 'flow.json'

    $flow = [ordered]@{
      name = 'port-override-smoke'
      settings = [ordered]@{
        artifactsDir = $artifactsDir
        port = $defaultPort
        timeoutMs = 12000
        pollMs = 300
      }
      steps = @(
        [ordered]@{ id = 'browser'; action = 'openbrowser'; port = $flowPort; timeoutMs = 12000; pollMs = 300 },
        [ordered]@{ id = 'page'; action = 'openUrl'; port = $flowPort; url = $script:fixture; timeoutMs = 5000 },
        [ordered]@{ id = 'wait'; action = 'wait-for'; port = $flowPort; selector = '#title'; timeoutMs = 5000; pollMs = 100 },
        [ordered]@{ id = 'query'; action = 'query'; port = $flowPort; selector = '#title'; fields = 'text'; limit = 1; timeoutMs = 5000 }
      )
    }

    try {
      ($flow | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $flowPath -Encoding UTF8

      $run = Invoke-SilmarilJson -CliArgs @('run', $flowPath, '--port', ([string]$defaultPort), '--timeout-ms', '12000', '--poll-ms', '300')
      $run.ok | Should -BeTrue

      $domPath = Join-Path $artifactsDir 'final-dom.html'
      Test-Path -LiteralPath $domPath | Should -BeTrue
      $dom = Get-Content -LiteralPath $domPath -Raw -Encoding UTF8
      $dom | Should -Match 'Smoke Title'
    }
    finally {
      Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
