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

  It 'requires explicit confirmation for set-page' {
    $result = Invoke-SilmarilRaw -CliArgs @('set-page', '--current', '--json')

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

  It 'list-pages exposes page ids and selected page metadata' {
    Mock Get-SilmarilPageTargets {
      @(
        [pscustomobject]@{ id = 'page-1'; type = 'page'; url = 'https://example.com'; title = 'Example'; webSocketDebuggerUrl = 'ws://one' }
      )
    }
    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        ResolvedTargetId = 'page-1'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'fallback'
        TargetStateSource = 'preferred-user-page'
      }
    }
    Mock Get-SilmarilAllTargetStates {
      [pscustomobject]@{
        pinned = $null
        ephemeral = $null
      }
    }

    $previousJsonMode = $env:SILMARIL_OUTPUT_JSON
    try {
      $env:SILMARIL_OUTPUT_JSON = '1'
      $result = & (Join-Path $script:repoRoot 'commands/list-pages.ps1') -RemainingArgs @()
      $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

      $payload.command | Should -Be 'list-pages'
      $payload.selectedPageId | Should -Be 'page-1'
      $payload.pages[0].pageId | Should -Be 'page-1'
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

Describe 'visual cursor command wiring' {
  It 'returns selector recovery suggestions when click target is missing' {
    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-missing'; webSocketDebuggerUrl = 'ws://example' }
        ResolvedTargetId = 'page-missing'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'fallback'
        TargetStateSource = 'none'
        PageCount = 1
        CandidateCount = 0
      }
    }
    Mock Invoke-SilmarilRuntimeEvaluate {
      [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            ok = $false
            reason = 'not_found'
            actionability = [pscustomobject]@{
              matchedCount = 0
              visibleCount = 0
              recovery = [pscustomobject]@{
                suggestedSelectors = @('[data-testid="save"]')
                candidates = @(
                  [pscustomobject]@{
                    tag = 'button'
                    role = 'button'
                    label = 'Save'
                    selector = '[data-testid="save"]'
                    visible = $true
                  }
                )
              }
            }
          }
        }
      }
    }

    try {
      & (Join-Path $script:repoRoot 'commands/click.ps1') -RemainingArgs @('#missing', '--yes')
      throw 'Expected click failure.'
    }
    catch {
      $payload = Get-SilmarilErrorContract -Command 'click' -Message $_.Exception.Message
      $payload.code | Should -Be 'NOT_FOUND'
      $payload.suggestedSelectors[0] | Should -Be '[data-testid="save"]'
      $payload.candidates[0].label | Should -Be 'Save'
    }
  }

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

  It 'uses native value setters in the type expression for controlled inputs' {
    $typeCommandSource = Get-Content -LiteralPath (Join-Path $script:repoRoot 'commands/type.ps1') -Raw

    $typeCommandSource | Should -Match 'Object\.getOwnPropertyDescriptor'
    $typeCommandSource | Should -Match 'HTMLInputElement\.prototype'
    $typeCommandSource | Should -Match 'HTMLTextAreaElement\.prototype'
    $typeCommandSource | Should -Match 'value_mismatch'
    $typeCommandSource | Should -Match 'insertReplacementText'
    $typeCommandSource | Should -Match 'previousValue'
  }

  It 'returns previous and final values in type json output when available' {
    $previousJsonMode = $env:SILMARIL_OUTPUT_JSON

    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-3'; webSocketDebuggerUrl = 'ws://example' }
        ResolvedTargetId = 'page-3'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'fallback'
        TargetStateSource = 'none'
        PageCount = 1
        CandidateCount = 0
      }
    }
    Mock Invoke-SilmarilRuntimeEvaluate {
      [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            ok = $true
            previousValue = 'old value'
            value = 'new value'
            inputType = 'insertReplacementText'
          }
        }
      }
    }

    try {
      $env:SILMARIL_OUTPUT_JSON = '1'
      $result = & (Join-Path $script:repoRoot 'commands/type.ps1') -RemainingArgs @('#name', 'new', 'value', '--yes')
      $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

      $payload.previousValue | Should -Be 'old value'
      $payload.value | Should -Be 'new value'
      $payload.inputType | Should -Be 'insertReplacementText'
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

  It 'throws a clear error when typed value does not stick' {
    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-4'; webSocketDebuggerUrl = 'ws://example' }
        ResolvedTargetId = 'page-4'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'fallback'
        TargetStateSource = 'none'
        PageCount = 1
        CandidateCount = 0
      }
    }
    Mock Invoke-SilmarilRuntimeEvaluate {
      [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            ok = $false
            reason = 'value_mismatch'
            expected = 'hello'
            actual = 'helloold'
          }
        }
      }
    }

    {
      & (Join-Path $script:repoRoot 'commands/type.ps1') -RemainingArgs @('#name', 'hello', '--yes')
    } | Should -Throw "*Typed value did not stick*Expected 'hello' but found 'helloold'*"
  }
}

Describe 'scroll command wiring' {
  It 'supports selector scroll-into-view mode' {
    $previousJsonMode = $env:SILMARIL_OUTPUT_JSON

    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-scroll-1'; webSocketDebuggerUrl = 'ws://example' }
        ResolvedTargetId = 'page-scroll-1'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'fallback'
        TargetStateSource = 'none'
        PageCount = 1
        CandidateCount = 0
      }
    }
    Mock Invoke-SilmarilRuntimeEvaluate {
      [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            ok = $true
            mode = 'element'
            top = 240
            left = 18
          }
        }
      }
    }

    try {
      $env:SILMARIL_OUTPUT_JSON = '1'
      $result = & (Join-Path $script:repoRoot 'commands/scroll.ps1') -RemainingArgs @(
        '#result',
        '--behavior', 'smooth',
        '--block', 'start',
        '--inline', 'nearest'
      )
      $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

      $payload.mode | Should -Be 'element'
      $payload.selector | Should -Be '#result'
      $payload.behavior | Should -Be 'smooth'
      $payload.block | Should -Be 'start'
      $payload.inline | Should -Be 'nearest'
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

  It 'supports selector ref scroll-into-view mode' {
    $previousJsonMode = $env:SILMARIL_OUTPUT_JSON
    $previousStateDir = $env:SILMARIL_STATE_DIR
    $testStateDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().Guid)
    New-Item -ItemType Directory -Force -Path $testStateDir | Out-Null

    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-scroll-ref'; webSocketDebuggerUrl = 'ws://example' }
        ResolvedTargetId = 'page-scroll-ref'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'fallback'
        TargetStateSource = 'none'
        PageCount = 1
        CandidateCount = 0
      }
    }
    Mock Test-SilmarilSnapshotRefMatch {
      [pscustomobject]@{ ok = $true }
    }
    Mock Invoke-SilmarilRuntimeEvaluate {
      [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            ok = $true
            mode = 'element'
            top = 240
            left = 18
          }
        }
      }
    }

    try {
      $env:SILMARIL_OUTPUT_JSON = '1'
      $env:SILMARIL_STATE_DIR = $testStateDir
      Save-SilmarilSnapshotState -Port 9222 -State ([ordered]@{
        snapshotToken = 'snapshot-scroll'
        target = [ordered]@{
          id = 'page-scroll-ref'
          url = 'https://example.com'
          title = 'Example'
          comparableUrl = Get-SilmarilComparableUrl -Url 'https://example.com'
        }
        refs = @(
          [ordered]@{
            id = 'e1'
            selector = '#result'
            label = 'Result'
            kind = 'heading'
            role = 'heading'
            tag = 'h2'
          }
        )
      })

      $result = & (Join-Path $script:repoRoot 'commands/scroll.ps1') -RemainingArgs @(
        'e1',
        '--behavior', 'smooth',
        '--block', 'start',
        '--inline', 'nearest'
      )
      $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

      $payload.mode | Should -Be 'element'
      $payload.selector | Should -Be 'e1'
      $payload.normalizedSelector | Should -Be '#result'
      $payload.resolvedSelector | Should -Be '#result'
      $payload.resolvedRef.id | Should -Be 'e1'
      $payload.behavior | Should -Be 'smooth'
      $payload.block | Should -Be 'start'
      $payload.inline | Should -Be 'nearest'
    }
    finally {
      if ($null -eq $previousJsonMode) {
        Remove-Item Env:SILMARIL_OUTPUT_JSON -ErrorAction SilentlyContinue
      }
      else {
        $env:SILMARIL_OUTPUT_JSON = $previousJsonMode
      }

      if ($null -eq $previousStateDir) {
        Remove-Item Env:SILMARIL_STATE_DIR -ErrorAction SilentlyContinue
      }
      else {
        $env:SILMARIL_STATE_DIR = $previousStateDir
      }

      Remove-Item -LiteralPath $testStateDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'supports page delta scrolling' {
    $previousJsonMode = $env:SILMARIL_OUTPUT_JSON

    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-scroll-2'; webSocketDebuggerUrl = 'ws://example' }
        ResolvedTargetId = 'page-scroll-2'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'fallback'
        TargetStateSource = 'none'
        PageCount = 1
        CandidateCount = 0
      }
    }
    Mock Invoke-SilmarilRuntimeEvaluate {
      [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            ok = $true
            mode = 'delta'
            targetKind = 'page'
            scrollLeft = 0
            scrollTop = 800
          }
        }
      }
    }

    try {
      $env:SILMARIL_OUTPUT_JSON = '1'
      $result = & (Join-Path $script:repoRoot 'commands/scroll.ps1') -RemainingArgs @(
        '--x', '0',
        '--y', '800'
      )
      $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

      $payload.mode | Should -Be 'delta'
      $payload.targetKind | Should -Be 'page'
      $payload.x | Should -Be 0
      $payload.y | Should -Be 800
      $payload.scrollTop | Should -Be 800
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

  It 'returns structured recovery when the scroll container selector does not match' {
    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-scroll-3'; webSocketDebuggerUrl = 'ws://example' }
        ResolvedTargetId = 'page-scroll-3'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'fallback'
        TargetStateSource = 'none'
        PageCount = 1
        CandidateCount = 0
      }
    }
    Mock Invoke-SilmarilRuntimeEvaluate {
      [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            ok = $false
            reason = 'container_not_found'
            recovery = [pscustomobject]@{
              suggestedSelectors = @('#content')
              candidates = @(
                [pscustomobject]@{
                  tag = 'main'
                  selector = '#content'
                  label = 'Content'
                  visible = $true
                }
              )
            }
          }
        }
      }
    }

    try {
      & (Join-Path $script:repoRoot 'commands/scroll.ps1') -RemainingArgs @(
        '--container', '.missing-pane',
        '--y', '400'
      )
      throw 'Expected scroll failure.'
    }
    catch {
      $payload = Get-SilmarilErrorContract -Command 'scroll' -Message $_.Exception.Message
      $payload.code | Should -Be 'NOT_FOUND'
      $payload.suggestedSelectors[0] | Should -Be '#content'
    }
  }
}

Describe 'eval-js confirmation parsing' {
  It 'accepts --yes before target selection flags' {
    $previousJsonMode = $env:SILMARIL_OUTPUT_JSON

    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-5'; webSocketDebuggerUrl = 'ws://example' }
        ResolvedTargetId = 'page-5'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'explicit-target-id'
        TargetStateSource = 'explicit-target-id'
        PageCount = 1
        CandidateCount = 1
      }
    }
    Mock Invoke-SilmarilCdpCommand {
      [pscustomobject]@{
        result = [pscustomobject]@{
          type = 'string'
          value = 'Example title'
        }
      }
    }

    try {
      $env:SILMARIL_OUTPUT_JSON = '1'
      $result = & (Join-Path $script:repoRoot 'commands/eval-js.ps1') -RemainingArgs @(
        'document.title',
        '--yes',
        '--allow-unsafe-js',
        '--target-id',
        'page-5'
      )
      $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

      $payload.ok | Should -BeTrue
      $payload.value | Should -Be 'Example title'
      $payload.targetId | Should -Be 'page-5'
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
    $global:listenerCallCount = 0
    $global:portListenChecks = 0

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:mitmdumpPath) | Out-Null
    New-Item -ItemType Directory -Force -Path $script:profileDir | Out-Null
    Set-Content -LiteralPath $script:mitmdumpPath -Value '' -Encoding UTF8
    Set-Content -LiteralPath $script:fixtureFile -Value '<!doctype html><title>Proxy Smoke</title>' -Encoding UTF8
    Set-Content -LiteralPath $script:rulesFile -Value '{"rules":[]}' -Encoding UTF8
    $env:SILMARIL_OUTPUT_JSON = '1'
    $env:HOME = $script:testHome

    Mock Get-SilmarilListenerPid {
      $global:listenerCallCount += 1
      if ($global:listenerCallCount -eq 1) {
        return $null
      }

      return 4242
    }
    Mock Test-SilmarilPortListening {
      $global:portListenChecks += 1
      if ($global:portListenChecks -eq 1) {
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
    Remove-Variable -Name listenerCallCount -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name portListenChecks -Scope Global -ErrorAction SilentlyContinue
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

Describe 'snapshot ref command wiring' {
  BeforeEach {
    $script:previousJsonMode = $env:SILMARIL_OUTPUT_JSON
    $script:previousStateDir = $env:SILMARIL_STATE_DIR
    $script:testStateDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().Guid)
    New-Item -ItemType Directory -Force -Path $script:testStateDir | Out-Null
    $env:SILMARIL_OUTPUT_JSON = '1'
    $env:SILMARIL_STATE_DIR = $script:testStateDir
  }

  AfterEach {
    if ($null -eq $script:previousJsonMode) {
      Remove-Item Env:SILMARIL_OUTPUT_JSON -ErrorAction SilentlyContinue
    }
    else {
      $env:SILMARIL_OUTPUT_JSON = $script:previousJsonMode
    }

    if ($null -eq $script:previousStateDir) {
      Remove-Item Env:SILMARIL_STATE_DIR -ErrorAction SilentlyContinue
    }
    else {
      $env:SILMARIL_STATE_DIR = $script:previousStateDir
    }

    Remove-Item -LiteralPath $script:testStateDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  It 'allows click to accept a snapshot ref and emits resolved metadata' {
    Save-SilmarilSnapshotState -Port 9222 -State ([ordered]@{
      snapshotToken = 'snapshot-click'
      target = [ordered]@{
        id = 'page-1'
        url = 'https://example.com'
        title = 'Example'
        comparableUrl = Get-SilmarilComparableUrl -Url 'https://example.com'
      }
      refs = @(
        [ordered]@{
          id = 'e1'
          selector = '#go'
          label = 'Go'
          kind = 'button'
          role = 'button'
          tag = 'button'
        }
      )
    })

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
    Mock Test-SilmarilSnapshotRefMatch {
      [pscustomobject]@{ ok = $true }
    }
    Mock Invoke-SilmarilRuntimeEvaluate {
      [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            ok = $true
          }
        }
      }
    }

    $result = & (Join-Path $script:repoRoot 'commands/click.ps1') -RemainingArgs @('e1', '--yes')
    $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

    $payload.ok | Should -BeTrue
    $payload.selector | Should -Be 'e1'
    $payload.inputSelectorOrRef | Should -Be 'e1'
    $payload.normalizedSelector | Should -Be '#go'
    $payload.resolvedSelector | Should -Be '#go'
    $payload.resolvedRef.id | Should -Be 'e1'
    $payload.resolvedRef.snapshotToken | Should -Be 'snapshot-click'
    Assert-MockCalled Test-SilmarilSnapshotRefMatch -Times 1 -Exactly
  }

  It 'clears snapshot state alongside target-clear' {
    Save-SilmarilSnapshotState -Port 9222 -State ([ordered]@{
      snapshotToken = 'snapshot-clear'
      target = [ordered]@{
        id = 'page-1'
        url = 'https://example.com'
        title = 'Example'
        comparableUrl = Get-SilmarilComparableUrl -Url 'https://example.com'
      }
      refs = @()
    })

    $result = & (Join-Path $script:repoRoot 'commands/target-clear.ps1') -RemainingArgs @('--yes')
    $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

    $payload.ok | Should -BeTrue
    $payload.removedSnapshot | Should -BeTrue
    (Get-SilmarilSnapshotState -Port 9222) | Should -BeNullOrEmpty
  }

  It 'passes content coverage through snapshot and reports non-viewport output' {
    $previousJsonMode = $env:SILMARIL_OUTPUT_JSON

    Mock Resolve-SilmarilPageTarget {
      [pscustomobject]@{
        Target = [pscustomobject]@{ id = 'page-snapshot'; webSocketDebuggerUrl = 'ws://example' }
        ResolvedTargetId = 'page-snapshot'
        ResolvedUrl = 'https://example.com'
        ResolvedTitle = 'Example'
        SelectionMode = 'fallback'
        TargetStateSource = 'none'
        PageCount = 1
        CandidateCount = 0
      }
    }
    Mock Invoke-SilmarilRuntimeEvaluate {
      [pscustomobject]@{
        result = [pscustomobject]@{
          value = [pscustomobject]@{
            snapshotToken = 'snapshot-content'
            coverage = 'content'
            viewportOnly = $false
            refCount = 1
            refs = @(
              [pscustomobject]@{
                id = 'e1'
                selector = '#content-title'
                label = 'Content Focus Title'
                kind = 'heading'
                role = 'heading'
                tag = 'h1'
              }
            )
            nodes = @()
            lines = @('e1 heading ""Content Focus Title""')
          }
        }
      }
    }

    try {
      $env:SILMARIL_OUTPUT_JSON = '1'
      $result = & (Join-Path $script:repoRoot 'commands/snapshot.ps1') -RemainingArgs @('--coverage', 'content')
      $payload = (@($result) | Select-Object -Last 1 | ConvertFrom-Json)

      $payload.ok | Should -BeTrue
      $payload.coverage | Should -Be 'content'
      $payload.viewportOnly | Should -BeFalse
      $payload.refs[0].id | Should -Be 'e1'
      Assert-MockCalled Invoke-SilmarilRuntimeEvaluate -Times 1 -Exactly
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
