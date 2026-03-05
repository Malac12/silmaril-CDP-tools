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
