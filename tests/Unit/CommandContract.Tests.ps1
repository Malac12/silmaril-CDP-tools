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
