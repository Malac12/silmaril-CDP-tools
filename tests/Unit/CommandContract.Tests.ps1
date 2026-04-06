BeforeAll {
  $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $script:entryScript = Join-Path $script:repoRoot 'silmaril.ps1'
  . (Join-Path $script:repoRoot 'lib/common.ps1')
  $script:shellPath = (Get-Process -Id $PID).Path
  $script:shellArgs = @('-NoProfile')
  $script:isWindowsPlatform = (($PSVersionTable.PSEdition -eq 'Desktop') -or ($env:OS -eq 'Windows_NT') -or ((Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) -and $IsWindows))
  if ($script:isWindowsPlatform) {
    $script:shellArgs += @('-ExecutionPolicy', 'Bypass')
  }

  function Invoke-SilmarilRaw {
    param([string[]]$CliArgs)

    $output = & $script:shellPath @script:shellArgs -File $script:entryScript @CliArgs 2>&1
    $code = $LASTEXITCODE
    return [ordered]@{ output = @($output | ForEach-Object { [string]$_ }); code = $code }
  }

  function Get-SilmarilJsonPayload {
    param([object]$Result)

    $line = ($Result.output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($line)) {
      throw 'No JSON payload returned.'
    }

    return ($line | ConvertFrom-Json)
  }
}

Describe 'Dispatcher Error Contract' {
  It 'returns code message hint in json mode for invalid command' {
    $result = Invoke-SilmarilRaw -CliArgs @('unknown-command', '--json')

    $result.code | Should -Be 1
    $payload = Get-SilmarilJsonPayload -Result $result

    $payload.ok | Should -BeFalse
    $payload.code | Should -Not -BeNullOrEmpty
    $payload.message | Should -Not -BeNullOrEmpty
    $payload.hint | Should -Not -BeNullOrEmpty
  }

  It 'blocks eval-js until the explicit unsafe-js safeguard is acknowledged' {
    $result = Invoke-SilmarilRaw -CliArgs @('eval-js', 'document.title', '--yes', '--json')

    $result.code | Should -Be 1
    $payload = Get-SilmarilJsonPayload -Result $result

    $payload.code | Should -Be 'INVALID_ARGUMENT'
    $payload.message | Should -Match '--allow-unsafe-js'
  }

  It 'blocks openurl-proxy until the explicit mitm safeguard is acknowledged' {
    $result = Invoke-SilmarilRaw -CliArgs @('openurl-proxy', 'https://example.com', '--json')

    $result.code | Should -Be 1
    $payload = Get-SilmarilJsonPayload -Result $result

    $payload.code | Should -Be 'INVALID_ARGUMENT'
    $payload.message | Should -Match '--allow-mitm'
  }

  It 'blocks proxy-override until the explicit mitm safeguard is acknowledged' {
    $localFile = New-TemporaryFile
    try {
      Set-Content -LiteralPath $localFile.FullName -Value 'body {}' -Encoding UTF8

      $result = Invoke-SilmarilRaw -CliArgs @('proxy-override', '--match', 'https://example.com/app.css', '--file', $localFile.FullName, '--yes', '--json')

      $result.code | Should -Be 1
      $payload = Get-SilmarilJsonPayload -Result $result

      $payload.code | Should -Be 'INVALID_ARGUMENT'
      $payload.message | Should -Match '--allow-mitm'
    }
    finally {
      Remove-Item -LiteralPath $localFile.FullName -ErrorAction SilentlyContinue
    }
  }

  It 'blocks proxy-switch until the explicit mitm safeguard is acknowledged' {
    $originalFile = New-TemporaryFile
    $savedFile = New-TemporaryFile
    try {
      Set-Content -LiteralPath $originalFile.FullName -Value 'original' -Encoding UTF8
      Set-Content -LiteralPath $savedFile.FullName -Value 'saved' -Encoding UTF8

      $result = Invoke-SilmarilRaw -CliArgs @('proxy-switch', '--match', 'https://example.com/app.css', '--original-file', $originalFile.FullName, '--saved-file', $savedFile.FullName, '--use', 'saved', '--yes', '--json')

      $result.code | Should -Be 1
      $payload = Get-SilmarilJsonPayload -Result $result

      $payload.code | Should -Be 'INVALID_ARGUMENT'
      $payload.message | Should -Match '--allow-mitm'
    }
    finally {
      Remove-Item -LiteralPath $originalFile.FullName -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $savedFile.FullName -ErrorAction SilentlyContinue
    }
  }

  It 'requires explicit confirmation for target-pin' {
    $result = Invoke-SilmarilRaw -CliArgs @('target-pin', '--current', '--json')

    $result.code | Should -Be 1
    $payload = Get-SilmarilJsonPayload -Result $result

    $payload.code | Should -Be 'INVALID_ARGUMENT'
    $payload.message | Should -Match '--yes'
  }

  It 'requires explicit confirmation for target-clear' {
    $result = Invoke-SilmarilRaw -CliArgs @('target-clear', '--json')

    $result.code | Should -Be 1
    $payload = Get-SilmarilJsonPayload -Result $result

    $payload.code | Should -Be 'INVALID_ARGUMENT'
    $payload.message | Should -Match '--yes'
  }
}

Describe 'list-urls output contract' {
  It 'prints a clear empty-state message in text mode when no page targets exist' {
    Mock Get-SilmarilPageTargets { @() }
    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        ResolvedTargetId = ''
        ResolvedUrl = ''
        ResolvedTitle = ''
        SelectionMode = 'fallback'
        TargetStateSource = 'none'
      }
    }
    Mock Get-SilmarilAllTargetStates {
      [pscustomobject]@{
        pinned = $null
        ephemeral = $null
      }
    }
    Mock Test-SilmarilJsonOutput { $false }

    $result = & (Join-Path $script:repoRoot 'commands/list-urls.ps1') -RemainingArgs @()

    @($result) | Should -Be @('No URLs found')
  }
}

Describe 'visual cursor command wiring' {
  It 'passes visualCursor metadata through click when enabled' {
    $previousJsonMode = $env:SILMARIL_OUTPUT_JSON

    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-1'; webSocketDebuggerUrl = 'ws://example' }
        ResolvedTargetId = 'page-1'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'fallback'
        TargetStateSource = 'none'
        PageCount = 1
        CandidateCount = 0
      }
    }
    Mock Invoke-SilmarilVisualCursorCue { [pscustomobject]@{ ok = $true } }
    Mock Invoke-SilmarilRuntimeEvaluate {
      [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            ok = $true
          }
        }
      }
    }

    try {
      $env:SILMARIL_OUTPUT_JSON = '1'
      $result = & (Join-Path $script:repoRoot 'commands/click.ps1') -RemainingArgs @('#go', '--yes', '--visual-cursor')
      $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

      Assert-MockCalled Invoke-SilmarilVisualCursorCue -Times 1 -Exactly
      $payload.visualCursor | Should -BeTrue
    }
    finally {
      if ($null -eq $previousJsonMode) {
        Remove-Item Env:SILMARIL_OUTPUT_JSON -ErrorAction SilentlyContinue
      }
      else {
        $env:SILMARIL_OUTPUT_JSON = $previousJsonMode
      }
    }
  }

  It 'preserves inline type payload when visual-cursor is a trailing flag' {
    $previousJsonMode = $env:SILMARIL_OUTPUT_JSON

    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-2'; webSocketDebuggerUrl = 'ws://example' }
        ResolvedTargetId = 'page-2'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'fallback'
        TargetStateSource = 'none'
        PageCount = 1
        CandidateCount = 0
      }
    }
    Mock Invoke-SilmarilVisualCursorCue { [pscustomobject]@{ ok = $true } }
    Mock Invoke-SilmarilRuntimeEvaluate {
      [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            ok = $true
          }
        }
      }
    }

    try {
      $env:SILMARIL_OUTPUT_JSON = '1'
      $result = & (Join-Path $script:repoRoot 'commands/type.ps1') -RemainingArgs @('#name', 'hello', 'visual', 'mode', '--yes', '--visual-cursor')
      $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

      Assert-MockCalled Invoke-SilmarilVisualCursorCue -Times 1 -Exactly
      $payload.bytes | Should -Be ([System.Text.Encoding]::UTF8.GetByteCount('hello visual mode'))
      $payload.visualCursor | Should -BeTrue
    }
    finally {
      if ($null -eq $previousJsonMode) {
        Remove-Item Env:SILMARIL_OUTPUT_JSON -ErrorAction SilentlyContinue
      }
      else {
        $env:SILMARIL_OUTPUT_JSON = $previousJsonMode
      }
    }
  }
}

Describe 'openurl-proxy safeguard forwarding' {
  BeforeEach {
    $script:previousJsonMode = $env:SILMARIL_OUTPUT_JSON
    $script:previousHome = $env:HOME
    $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().Guid)
    $script:testHome = Join-Path $script:testRoot 'home'
    $script:profileDir = Join-Path $script:testRoot 'profile'
    $script:fixtureFile = Join-Path $script:testRoot 'page.html'
    $script:rulesFile = Join-Path $script:testRoot 'rules.json'
    $script:mitmdumpPath = Join-Path $script:testHome 'tools/mitmproxy/12.2.1/mitmdump.exe'
    $script:listenerCallCount = 0
    $script:portListenChecks = 0

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:mitmdumpPath) | Out-Null
    New-Item -ItemType Directory -Force -Path $script:profileDir | Out-Null
    Set-Content -LiteralPath $script:mitmdumpPath -Value '' -Encoding UTF8
    Set-Content -LiteralPath $script:fixtureFile -Value '<!doctype html><title>Proxy Smoke</title>' -Encoding UTF8
    Set-Content -LiteralPath $script:rulesFile -Value '{"rules":[]}' -Encoding UTF8
    $env:SILMARIL_OUTPUT_JSON = '1'
    $env:HOME = $script:testHome

    Mock Get-SilmarilListenerPid {
      $script:listenerCallCount += 1
      if ($script:listenerCallCount -eq 1) {
        return $null
      }

      return 4242
    }
    Mock Test-SilmarilPortListening {
      $script:portListenChecks += 1
      if ($script:portListenChecks -eq 1) {
        return $false
      }

      return $true
    }
    Mock Start-Process {
      [pscustomobject]@{
        HasExited = $false
        Id = 4242
        ExitCode = 0
      }
    }
    Mock Start-SilmarilBrowserProcess { 'browser.exe' }
    Mock Test-SilmarilCdpReady { $true }
  }

  AfterEach {
    if ($null -eq $script:previousJsonMode) {
      Remove-Item Env:SILMARIL_OUTPUT_JSON -ErrorAction SilentlyContinue
    }
    else {
      $env:SILMARIL_OUTPUT_JSON = $script:previousJsonMode
    }

    if ($null -eq $script:previousHome) {
      Remove-Item Env:HOME -ErrorAction SilentlyContinue
    }
    else {
      $env:HOME = $script:previousHome
    }

    Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  It 'forwards the MITM acknowledgement when auto-starting proxy-override' {
    $result = & (Join-Path $script:repoRoot 'commands/openurl-proxy.ps1') -RemainingArgs @(
      $script:fixtureFile,
      '--allow-mitm',
      '--rules-file', $script:rulesFile,
      '--profile-dir', $script:profileDir
    )

    $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

    $payload.ok | Should -BeTrue
    $payload.proxyStarted | Should -BeTrue
    $payload.proxyPid | Should -Be 4242
    $payload.safeguard | Should -Be 'flag:--allow-mitm'
  }
}
