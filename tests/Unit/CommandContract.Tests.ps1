BeforeAll {
  $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $script:entryScript = Join-Path $script:repoRoot 'silmaril.ps1'

  function Invoke-SilmarilRaw {
    param([string[]]$CliArgs)

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:entryScript @CliArgs 2>&1
    $code = $LASTEXITCODE
    return [ordered]@{ output = @($output | ForEach-Object { [string]$_ }); code = $code }
  }
}

Describe 'Dispatcher Error Contract' {
  It 'returns code message hint in json mode for invalid command' {
    $result = Invoke-SilmarilRaw -CliArgs @('unknown-command', '--json')

    $result.code | Should -Be 1
    $line = ($result.output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    $payload = $line | ConvertFrom-Json

    $payload.ok | Should -BeFalse
    $payload.code | Should -Not -BeNullOrEmpty
    $payload.message | Should -Not -BeNullOrEmpty
    $payload.hint | Should -Not -BeNullOrEmpty
  }
}


