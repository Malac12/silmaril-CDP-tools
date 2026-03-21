BeforeAll {
  . (Join-Path $PSScriptRoot 'LiveTestHelpers.ps1')
}

Describe 'Silmaril Live Public Regressions' -Tag 'Live' {
  It 'reads a public OpenAI article page' -Skip:($env:SILMARIL_RUN_LIVE -ne '1') {
    if ([string]::IsNullOrWhiteSpace((Get-SilmarilBrowserPath))) {
      Set-ItResult -Skipped -Because 'Live test skipped: no supported browser found.'
      return
    }

    $port = Get-FreeLoopbackPort
    (Invoke-SilmarilJson -CliArgs @('openbrowser', '--port', ([string]$port), '--timeout-ms', '20000', '--poll-ms', '300')).ok | Should -BeTrue
    (Invoke-SilmarilJson -CliArgs @('openurl', 'https://openai.com/index/introducing-gpt-5-4-mini-and-nano/', '--port', ([string]$port), '--timeout-ms', '10000')).ok | Should -BeTrue
    (Invoke-SilmarilJson -CliArgs @('wait-for', 'main', '--port', ([string]$port), '--timeout-ms', '15000', '--poll-ms', '200')).ok | Should -BeTrue

    $heading = Invoke-SilmarilJson -CliArgs @('get-text', 'h1', '--port', ([string]$port), '--timeout-ms', '15000')
    ([string]$heading.text).Length | Should -BeGreaterThan 3

    $links = Invoke-SilmarilJson -CliArgs @('query', 'a[href]', '--fields', 'text,href', '--limit', '10', '--port', ([string]$port), '--timeout-ms', '15000')
    $links.returnedCount | Should -BeGreaterThan 3
  }

  It 'reads a public GitHub repository page' -Skip:($env:SILMARIL_RUN_LIVE -ne '1') {
    if ([string]::IsNullOrWhiteSpace((Get-SilmarilBrowserPath))) {
      Set-ItResult -Skipped -Because 'Live test skipped: no supported browser found.'
      return
    }

    $port = Get-FreeLoopbackPort
    (Invoke-SilmarilJson -CliArgs @('openbrowser', '--port', ([string]$port), '--timeout-ms', '20000', '--poll-ms', '300')).ok | Should -BeTrue
    (Invoke-SilmarilJson -CliArgs @('openurl', 'https://github.com/openai/openai-python', '--port', ([string]$port), '--timeout-ms', '10000')).ok | Should -BeTrue
    (Invoke-SilmarilJson -CliArgs @('wait-for', 'main', '--port', ([string]$port), '--timeout-ms', '15000', '--poll-ms', '200')).ok | Should -BeTrue

    $title = Invoke-SilmarilJson -CliArgs @('get-text', 'title', '--port', ([string]$port), '--timeout-ms', '15000')
    ([string]$title.text) | Should -Match 'openai-python'

    $links = Invoke-SilmarilJson -CliArgs @('query', 'a[href]', '--fields', 'text,href', '--limit', '12', '--port', ([string]$port), '--timeout-ms', '15000')
    $links.returnedCount | Should -BeGreaterThan 5
  }

  It 'extracts dynamic Product Hunt links' -Skip:($env:SILMARIL_RUN_LIVE -ne '1') {
    if ([string]::IsNullOrWhiteSpace((Get-SilmarilBrowserPath))) {
      Set-ItResult -Skipped -Because 'Live test skipped: no supported browser found.'
      return
    }

    $port = Get-FreeLoopbackPort
    (Invoke-SilmarilJson -CliArgs @('openbrowser', '--port', ([string]$port), '--timeout-ms', '20000', '--poll-ms', '300')).ok | Should -BeTrue
    (Invoke-SilmarilJson -CliArgs @('openurl', 'https://www.producthunt.com/', '--port', ([string]$port), '--timeout-ms', '10000')).ok | Should -BeTrue
    $links = Invoke-SilmarilJsonEventually -CliArgs @('query', 'main a[href]', '--fields', 'text,href', '--limit', '8', '--port', ([string]$port), '--timeout-ms', '15000') -Attempts 12 -DelayMs 750 -Validator {
      param($payload)
      return ([int]$payload.returnedCount -gt 0)
    }
    $links.returnedCount | Should -BeGreaterThan 0
  }

  It 'extracts public YouTube watch links' -Skip:($env:SILMARIL_RUN_LIVE -ne '1') {
    if ([string]::IsNullOrWhiteSpace((Get-SilmarilBrowserPath))) {
      Set-ItResult -Skipped -Because 'Live test skipped: no supported browser found.'
      return
    }

    $port = Get-FreeLoopbackPort
    (Invoke-SilmarilJson -CliArgs @('openbrowser', '--port', ([string]$port), '--timeout-ms', '20000', '--poll-ms', '300')).ok | Should -BeTrue
    (Invoke-SilmarilJson -CliArgs @('openurl', 'https://www.youtube.com/@OpenAI/videos', '--port', ([string]$port), '--timeout-ms', '10000')).ok | Should -BeTrue
    $videos = Invoke-SilmarilJsonEventually -CliArgs @('query', 'a[href*="/watch"]', '--fields', 'text,href', '--limit', '8', '--port', ([string]$port), '--timeout-ms', '20000') -Attempts 12 -DelayMs 750 -Validator {
      param($payload)
      return ([int]$payload.returnedCount -gt 0)
    }
    $videos.returnedCount | Should -BeGreaterThan 0
  }

  It 'reproduces X multi-tab ambiguity and fixes it with target-pin' -Skip:($env:SILMARIL_RUN_LIVE -ne '1') {
    if ([string]::IsNullOrWhiteSpace((Get-SilmarilBrowserPath))) {
      Set-ItResult -Skipped -Because 'Live test skipped: no supported browser found.'
      return
    }

    $port = Get-FreeLoopbackPort
    $threadUrl = 'https://x.com/OpenAI/status/2034315401438580953'
    (Invoke-SilmarilJson -CliArgs @('openbrowser', '--port', ([string]$port), '--timeout-ms', '20000', '--poll-ms', '300')).ok | Should -BeTrue
    (Invoke-SilmarilJson -CliArgs @('openurl', 'https://x.com/OpenAI', '--port', ([string]$port), '--timeout-ms', '12000')).ok | Should -BeTrue
    (Invoke-SilmarilJson -CliArgs @('openurl', $threadUrl, '--port', ([string]$port), '--timeout-ms', '12000')).ok | Should -BeTrue

    $targets = Invoke-SilmarilJson -CliArgs @('list-urls', '--port', ([string]$port))
    $profileTarget = @($targets.targets | Where-Object { [string]$_.url -eq 'https://x.com/OpenAI' } | Select-Object -First 1)
    if ($null -eq $profileTarget) {
      throw 'Could not locate the @OpenAI profile tab in list-urls output.'
    }

    $ambiguous = Invoke-SilmarilRaw -CliArgs @('get-text', 'body', '--url-match', 'x\.com/OpenAI', '--port', ([string]$port))
    $ambiguous.code | Should -Be 1
    $ambiguous.payload.code | Should -Be 'TARGET_AMBIGUOUS'
    $ambiguous.payload.candidateCount | Should -BeGreaterThan 1

    $pin = Invoke-SilmarilJson -CliArgs @('target-pin', '--target-id', ([string]$profileTarget.id), '--port', ([string]$port), '--yes')
    $pin.pinnedTargetId | Should -Be ([string]$profileTarget.id)

    $resolved = Invoke-SilmarilJson -CliArgs @('get-text', 'body', '--url-match', 'x\.com/OpenAI', '--port', ([string]$port), '--timeout-ms', '20000')
    $resolved.resolvedTargetId | Should -Be ([string]$profileTarget.id)
    $resolved.targetStateSource | Should -Be 'pinned-target-id'
  }
}
