BeforeAll {
  $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $script:entryScript = Join-Path $script:repoRoot 'silmaril.ps1'
  $script:fixturePath = Join-Path $script:repoRoot 'tests/fixtures/page-memory-lichess-round.json'
  . (Join-Path $script:repoRoot 'lib/common.ps1')
  . (Join-Path $script:repoRoot 'lib/page-memory.ps1')
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

Describe 'page-memory command family' {
  BeforeEach {
    $script:previousStateDir = $env:SILMARIL_STATE_DIR
    $script:previousJsonMode = $env:SILMARIL_OUTPUT_JSON
    $script:testStateDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().Guid)
    New-Item -ItemType Directory -Force -Path $script:testStateDir | Out-Null
    $env:SILMARIL_STATE_DIR = $script:testStateDir
    $env:SILMARIL_OUTPUT_JSON = '1'
  }

  AfterEach {
    if ($null -eq $script:previousStateDir) {
      Remove-Item Env:SILMARIL_STATE_DIR -ErrorAction SilentlyContinue
    }
    else {
      $env:SILMARIL_STATE_DIR = $script:previousStateDir
    }

    if ($null -eq $script:previousJsonMode) {
      Remove-Item Env:SILMARIL_OUTPUT_JSON -ErrorAction SilentlyContinue
    }
    else {
      $env:SILMARIL_OUTPUT_JSON = $script:previousJsonMode
    }

    Remove-Item -LiteralPath $script:testStateDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  It 'saves and lists a stable page memory record through the dispatcher' {
    $saveResult = Invoke-SilmarilRaw -CliArgs @('page-memory', 'save', '--file', $script:fixturePath, '--yes', '--json')
    $saveResult.code | Should -Be 0
    $savePayload = Get-SilmarilJsonPayload -Result $saveResult

    $savePayload.command | Should -Be 'page-memory.save'
    $savePayload.id | Should -Be 'lichess-round-v1'
    $savePayload.recordType | Should -Be 'stable'

    $listResult = Invoke-SilmarilRaw -CliArgs @('page-memory', 'list', '--json')
    $listResult.code | Should -Be 0
    $listPayload = Get-SilmarilJsonPayload -Result $listResult

    $listPayload.command | Should -Be 'page-memory.list'
    $listPayload.count | Should -Be 1
    @($listPayload.records)[0].id | Should -Be 'lichess-round-v1'
  }

  It 'returns a strong lookup match for the lichess round fixture' {
    $record = Read-SilmarilPageMemoryRecordFile -Path $script:fixturePath
    [void](Save-SilmarilPageMemoryRecord -Record $record)

    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-1'; webSocketDebuggerUrl = 'ws://example'; url = 'https://lichess.org/I6o4Q2cS'; title = 'Round' }
        ResolvedTargetId = 'page-1'
        ResolvedUrl = 'https://lichess.org/I6o4Q2cS'
        ResolvedTitle = '杞埌鎮ㄨ蛋妫?- 瀵瑰紙 Stockfish level 1 鈥?lichess.org'
        SelectionMode = 'fallback'
        TargetStateSource = 'preferred-user-page'
        PageCount = 1
        CandidateCount = 0
        TargetActivated = $true
        TargetActivationMethod = 'http-activate'
        TargetActivationError = ''
      }
    }

    Mock Get-SilmarilPageMemorySelectorStates {
      [ordered]@{
        'body.playing' = $true
      }
    }

    $result = Invoke-SilmarilPageMemoryLookup -RemainingArgs @()
    $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

    $payload.command | Should -Be 'page-memory.lookup'
    $payload.matchCount | Should -Be 1
    @($payload.matches)[0].matchLevel | Should -Be 'strong'
    @($payload.matches)[0].isRecommended | Should -BeTrue
  }

  It 'verifies a record and refreshes its confidence/status' {
    $record = Read-SilmarilPageMemoryRecordFile -Path $script:fixturePath
    [void](Save-SilmarilPageMemoryRecord -Record $record)

    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-1'; webSocketDebuggerUrl = 'ws://example'; url = 'https://lichess.org/I6o4Q2cS'; title = 'Round' }
        ResolvedTargetId = 'page-1'
        ResolvedUrl = 'https://lichess.org/I6o4Q2cS'
        ResolvedTitle = '杞埌鎮ㄨ蛋妫?- 瀵瑰紙 Stockfish level 1 鈥?lichess.org'
        SelectionMode = 'fallback'
        TargetStateSource = 'preferred-user-page'
        PageCount = 1
        CandidateCount = 0
        TargetActivated = $true
        TargetActivationMethod = 'http-activate'
        TargetActivationError = ''
      }
    }

    Mock Get-SilmarilPageMemorySelectorStates {
      [ordered]@{
        'body.playing' = $true
        '#nvui-button' = $true
        'cg-board' = $true
        "input[name='move']" = $true
      }
    }

    $result = Invoke-SilmarilPageMemoryVerify -RemainingArgs @('--id', 'lichess-round-v1')
    $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

    $payload.command | Should -Be 'page-memory.verify'
    $payload.overallVerified | Should -BeTrue
    ($payload.checks | Where-Object { $_.kind -eq 'selector' } | Select-Object -First 1).state.exists | Should -BeTrue
    $payload.lastVerificationStatus | Should -Be 'verified'

    $saved = Get-SilmarilPageMemoryRecordById -Id 'lichess-round-v1'
    $saved.lastVerificationStatus | Should -Be 'verified'
    [double]$saved.confidence | Should -BeGreaterThan 0.96
  }

  It 'invalidates a saved record' {
    $record = Read-SilmarilPageMemoryRecordFile -Path $script:fixturePath
    [void](Save-SilmarilPageMemoryRecord -Record $record)

    $result = Invoke-SilmarilRaw -CliArgs @('page-memory', 'invalidate', '--id', 'lichess-round-v1', '--yes', '--json')
    $result.code | Should -Be 0
    $payload = Get-SilmarilJsonPayload -Result $result

    $payload.command | Should -Be 'page-memory.invalidate'
    $payload.invalidated | Should -BeTrue

    $saved = Get-SilmarilPageMemoryRecordById -Id 'lichess-round-v1'
    $saved.invalidated | Should -BeTrue
  }

  It 'matches session memory by comparable url exactly' {
    $sessionRecord = ConvertTo-SilmarilPageMemoryRecord -Value ([pscustomobject]@{
      recordType = 'session'
      id = 'session-note-1'
      session = [pscustomobject]@{
        comparableUrl = 'https://example.com/products/1#details'
      }
      summary = 'Session note for an exact page instance.'
      confidence = 0.7
    })

    [void](Save-SilmarilPageMemoryRecord -Record $sessionRecord)

    $fingerprint = [ordered]@{
      targetId = ''
      url = 'https://example.com/products/1'
      comparableUrl = 'https://example.com/products/1'
      title = 'Example'
      domain = 'example.com'
      path = '/products/1'
      targetSelection = 'fallback'
      targetStateSource = 'preferred-user-page'
    }

    $matches = Find-SilmarilPageMemoryMatches -Target $null -Fingerprint $fingerprint -Records @(Get-SilmarilPageMemoryRecords -RecordType all)

    @($matches).Count | Should -Be 1
    @($matches)[0].matchLevel | Should -Be 'exact'
    @($matches)[0].recordType | Should -Be 'session'
  }
}
