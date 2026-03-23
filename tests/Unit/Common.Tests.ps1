BeforeAll {
  $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  . (Join-Path $repoRoot 'lib\common.ps1')
}

Describe 'Parse-SilmarilCommonArgs' {
  It 'parses common flags and preserves remaining args' {
    $result = Parse-SilmarilCommonArgs -Args @('query', '#x', '--port', '9333', '--target-id', 'abc', '--timeout-ms', '15000', '--poll-ms', '300') -AllowPort -AllowTargetSelection -AllowTimeout -AllowPoll

    $result.Port | Should -Be 9333
    $result.TargetId | Should -Be 'abc'
    $result.UrlMatch | Should -BeNullOrEmpty
    $result.TimeoutMs | Should -Be 15000
    $result.PollMs | Should -Be 300
    $result.RemainingArgs | Should -Be @('query', '#x')
  }

  It 'throws when both target flags are present' {
    {
      Parse-SilmarilCommonArgs -Args @('--target-id', 'a', '--url-match', 'x') -AllowTargetSelection
    } | Should -Throw
  }
}

Describe 'Normalize-SilmarilSelector' {
  It 'quotes unquoted attribute selector values' {
    (Normalize-SilmarilSelector -Selector '[data-test=launch]') | Should -Be '[data-test="launch"]'
    (Normalize-SilmarilSelector -Selector 'a[href^=/products/]') | Should -Be 'a[href^="/products/"]'
  }

  It 'removes one outer quote layer and normalizes smart quotes' {
    (Normalize-SilmarilSelector -Selector '"[data-test=''comments-feed'']"') | Should -Be "[data-test='comments-feed']"
    $smartOpen = [string][char]0x201C
    $smartClose = [string][char]0x201D
    (Normalize-SilmarilSelector -Selector ("[title={0}hello{1}]" -f $smartOpen, $smartClose)) | Should -Be '[title="hello"]'
  }
}

Describe 'High-risk helpers' {
  It 'treats common opt-in values as truthy' {
    (Test-SilmarilTruthyValue -Value '1') | Should -BeTrue
    (Test-SilmarilTruthyValue -Value 'true') | Should -BeTrue
    (Test-SilmarilTruthyValue -Value 'yes') | Should -BeTrue
    (Test-SilmarilTruthyValue -Value 'on') | Should -BeTrue
    (Test-SilmarilTruthyValue -Value '0') | Should -BeFalse
  }

  It 'recognizes loopback hosts' {
    (Test-SilmarilLoopbackHost -ListenHost '127.0.0.1') | Should -BeTrue
    (Test-SilmarilLoopbackHost -ListenHost 'localhost') | Should -BeTrue
    (Test-SilmarilLoopbackHost -ListenHost '::1') | Should -BeTrue
    (Test-SilmarilLoopbackHost -ListenHost '0.0.0.0') | Should -BeFalse
  }
}

Describe 'Resolve-SilmarilPageTarget' {
  BeforeEach {
    $script:previousStateDir = $env:SILMARIL_STATE_DIR
    $script:testStateDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().Guid)
    $env:SILMARIL_STATE_DIR = $script:testStateDir
    New-Item -ItemType Directory -Force -Path $script:testStateDir | Out-Null
  }

  AfterEach {
    $stateDirToRemove = $script:testStateDir
    if ($null -eq $script:previousStateDir) {
      Remove-Item Env:SILMARIL_STATE_DIR -ErrorAction SilentlyContinue
    }
    else {
      $env:SILMARIL_STATE_DIR = $script:previousStateDir
    }

    if (-not [string]::IsNullOrWhiteSpace($stateDirToRemove)) {
      Remove-Item -LiteralPath $stateDirToRemove -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'reuses the previous target id when page order changes' {
    Mock Invoke-SilmarilActivateTarget {
      [pscustomobject]@{
        Attempted = $true
        Activated = $true
        Method    = 'http-activate'
        Error     = $null
      }
    }

    Mock Get-SilmarilCdpTargets {
      @(
        [pscustomobject]@{ id = 'page-selected'; type = 'page'; url = 'https://selected.example.com'; title = 'Selected'; webSocketDebuggerUrl = 'ws://selected' },
        [pscustomobject]@{ id = 'page-other'; type = 'page'; url = 'https://other.example.com'; title = 'Other'; webSocketDebuggerUrl = 'ws://other' }
      )
    } -Verifiable

    $first = Resolve-SilmarilPageTarget -Port 9777
    $first.ResolvedTargetId | Should -Be 'page-selected'
    $first.SelectionMode | Should -Be 'fallback'
    $first.TargetStateSource | Should -Be 'preferred-user-page'
    $first.TargetActivated | Should -BeTrue
    $first.TargetActivationMethod | Should -Be 'http-activate'

    Mock Get-SilmarilCdpTargets {
      @(
        [pscustomobject]@{ id = 'page-other'; type = 'page'; url = 'https://other.example.com'; title = 'Other'; webSocketDebuggerUrl = 'ws://other' },
        [pscustomobject]@{ id = 'page-selected'; type = 'page'; url = 'https://selected.example.com'; title = 'Selected'; webSocketDebuggerUrl = 'ws://selected' }
      )
    }

    $second = Resolve-SilmarilPageTarget -Port 9777
    $second.ResolvedTargetId | Should -Be 'page-selected'
    $second.SelectionMode | Should -Be 'saved-state'
    $second.TargetStateSource | Should -Be 'ephemeral-target-id'
    Assert-MockCalled Invoke-SilmarilActivateTarget -Times 2 -Exactly
  }

  It 'falls back to the previous url when the target id changed after rerender' {
    Mock Invoke-SilmarilActivateTarget {
      [pscustomobject]@{
        Attempted = $true
        Activated = $true
        Method    = 'http-activate'
        Error     = $null
      }
    }

    Save-SilmarilTargetState -Port 9888 -Target ([pscustomobject]@{
      id = 'stale-target'
      type = 'page'
      url = 'https://selected.example.com/path#section'
      title = 'Selected'
      webSocketDebuggerUrl = 'ws://stale'
    }) -SelectionMode 'preferred-user-page' -Kind 'ephemeral'

    Mock Get-SilmarilCdpTargets {
      @(
        [pscustomobject]@{ id = 'new-target'; type = 'page'; url = 'https://selected.example.com/path'; title = 'Selected'; webSocketDebuggerUrl = 'ws://new' },
        [pscustomobject]@{ id = 'page-other'; type = 'page'; url = 'https://other.example.com'; title = 'Other'; webSocketDebuggerUrl = 'ws://other' }
      )
    }

    $resolved = Resolve-SilmarilPageTarget -Port 9888
    $resolved.ResolvedTargetId | Should -Be 'new-target'
    $resolved.SelectionMode | Should -Be 'saved-state'
    $resolved.TargetStateSource | Should -Be 'ephemeral-comparable-url'
    $resolved.TargetActivated | Should -BeTrue
  }

  It 'prefers pinned state over ephemeral state' {
    Mock Invoke-SilmarilActivateTarget {
      [pscustomobject]@{
        Attempted = $true
        Activated = $true
        Method    = 'http-activate'
        Error     = $null
      }
    }

    Save-SilmarilTargetState -Port 9990 -Target ([pscustomobject]@{
      id = 'page-pinned'
      type = 'page'
      url = 'https://pinned.example.com'
      title = 'Pinned'
      webSocketDebuggerUrl = 'ws://pinned'
    }) -SelectionMode 'target-pin' -Kind 'pinned'

    Save-SilmarilTargetState -Port 9990 -Target ([pscustomobject]@{
      id = 'page-ephemeral'
      type = 'page'
      url = 'https://ephemeral.example.com'
      title = 'Ephemeral'
      webSocketDebuggerUrl = 'ws://ephemeral'
    }) -SelectionMode 'openurl-new-target' -Kind 'ephemeral'

    Mock Get-SilmarilCdpTargets {
      @(
        [pscustomobject]@{ id = 'page-ephemeral'; type = 'page'; url = 'https://ephemeral.example.com'; title = 'Ephemeral'; webSocketDebuggerUrl = 'ws://ephemeral' },
        [pscustomobject]@{ id = 'page-pinned'; type = 'page'; url = 'https://pinned.example.com'; title = 'Pinned'; webSocketDebuggerUrl = 'ws://pinned' }
      )
    }

    $resolved = Resolve-SilmarilPageTarget -Port 9990
    $resolved.ResolvedTargetId | Should -Be 'page-pinned'
    $resolved.TargetStateSource | Should -Be 'pinned-target-id'
    $resolved.TargetActivated | Should -BeTrue
  }

  It 'throws a structured ambiguity error for explicit url-match with multiple candidates and no pin' {
    Mock Get-SilmarilCdpTargets {
      @(
        [pscustomobject]@{ id = 'page-a'; type = 'page'; url = 'https://x.com/OpenAI'; title = 'Profile'; webSocketDebuggerUrl = 'ws://a' },
        [pscustomobject]@{ id = 'page-b'; type = 'page'; url = 'https://x.com/OpenAI/status/1'; title = 'Thread'; webSocketDebuggerUrl = 'ws://b' }
      )
    }

    try {
      Resolve-SilmarilPageTarget -Port 9991 -UrlMatch 'x\.com/OpenAI'
      throw 'Expected ambiguity error.'
    }
    catch {
      $payload = Get-SilmarilErrorContract -Command 'get-text' -Message $_.Exception.Message
      $payload.code | Should -Be 'TARGET_AMBIGUOUS'
      $payload.candidateCount | Should -Be 2
    }
  }

  It 'uses a pinned target to break explicit url-match ambiguity' {
    Mock Invoke-SilmarilActivateTarget {
      [pscustomobject]@{
        Attempted = $true
        Activated = $true
        Method    = 'http-activate'
        Error     = $null
      }
    }

    Save-SilmarilTargetState -Port 9992 -Target ([pscustomobject]@{
      id = 'page-b'
      type = 'page'
      url = 'https://x.com/OpenAI/status/1'
      title = 'Thread'
      webSocketDebuggerUrl = 'ws://b'
    }) -SelectionMode 'target-pin' -Kind 'pinned'

    Mock Get-SilmarilCdpTargets {
      @(
        [pscustomobject]@{ id = 'page-a'; type = 'page'; url = 'https://x.com/OpenAI'; title = 'Profile'; webSocketDebuggerUrl = 'ws://a' },
        [pscustomobject]@{ id = 'page-b'; type = 'page'; url = 'https://x.com/OpenAI/status/1'; title = 'Thread'; webSocketDebuggerUrl = 'ws://b' }
      )
    }

    $resolved = Resolve-SilmarilPageTarget -Port 9992 -UrlMatch 'x\.com/OpenAI'
    $resolved.ResolvedTargetId | Should -Be 'page-b'
    $resolved.SelectionMode | Should -Be 'explicit-url-match'
    $resolved.TargetStateSource | Should -Be 'pinned-target-id'
    $resolved.TargetActivated | Should -BeTrue
  }

  It 'does not fail target resolution when visual activation fails' {
    Mock Invoke-SilmarilActivateTarget {
      [pscustomobject]@{
        Attempted = $true
        Activated = $false
        Method    = 'http-activate'
        Error     = 'activation failed'
      }
    }

    Mock Get-SilmarilCdpTargets {
      @(
        [pscustomobject]@{ id = 'page-selected'; type = 'page'; url = 'https://selected.example.com'; title = 'Selected'; webSocketDebuggerUrl = 'ws://selected' }
      )
    }

    $resolved = Resolve-SilmarilPageTarget -Port 9993
    $resolved.ResolvedTargetId | Should -Be 'page-selected'
    $resolved.TargetActivated | Should -BeFalse
    $resolved.TargetActivationError | Should -Be 'activation failed'
  }
}

Describe 'Invoke-SilmarilSelectorWait' {
  It 'serializes a single selector as a JSON array' {
    $script:capturedSelectorWaitExpression = $null

    Mock Invoke-SilmarilRuntimeEvaluate {
      param($Target, $Expression, $TimeoutSec)
      $script:capturedSelectorWaitExpression = $Expression
      return [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            ok = $true
            matchedSelector = '[data-test="launch"]'
            elapsedMs = 0
          }
        }
      }
    }

    $result = Invoke-SilmarilSelectorWait -Target ([pscustomobject]@{ id = 'page-1'; webSocketDebuggerUrl = 'ws://example' }) -Selectors @('[data-test="launch"]') -Mode 'visible' -TimeoutMs 500 -PollMs 50 -CommandName 'wait-for'

    $result.ok | Should -BeTrue
    $script:capturedSelectorWaitExpression.Contains('var sels = ["[data-test=\"launch\"]"];') | Should -BeTrue
  }
}

Describe 'Get-SilmarilErrorContract' {
  It 'returns standardized keys' {
    $err = Get-SilmarilErrorContract -Command 'wait-for' -Message 'Timed out waiting for selector: #x'

    $err.ok | Should -BeFalse
    $err.command | Should -Be 'wait-for'
    $err.code | Should -Be 'TIMEOUT'
    $err.message | Should -Match 'Timed out'
    $err.hint | Should -Not -BeNullOrEmpty
  }
}

Describe 'Add-SilmarilTargetMetadata' {
  It 'includes target activation details when available' {
    $data = Add-SilmarilTargetMetadata -Data @{} -TargetContext ([pscustomobject]@{
      ResolvedTargetId         = 'page-1'
      ResolvedUrl              = 'https://example.com'
      ResolvedTitle            = 'Example'
      SelectionMode            = 'explicit-target-id'
      TargetStateSource        = 'explicit-target-id'
      PageCount                = 2
      CandidateCount           = 0
      TargetActivated          = $false
      TargetActivationMethod   = 'http-activate'
      TargetActivationError    = 'activation failed'
    })

    $data.targetActivated | Should -BeFalse
    $data.targetActivationMethod | Should -Be 'http-activate'
    $data.targetActivationError | Should -Be 'activation failed'
  }
}
