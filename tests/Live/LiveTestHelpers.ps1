$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$entryScript = Join-Path $repoRoot 'silmaril.ps1'
. (Join-Path $repoRoot 'lib/common.ps1')

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

function Invoke-SilmarilRaw {
  param([string[]]$CliArgs)

  $output = & $script:shellPath @script:shellArgs -File $entryScript @CliArgs '--json' 2>&1
  $code = $LASTEXITCODE
  $line = ($output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($line)) {
    throw 'No JSON payload returned from silmaril command.'
  }

  return [ordered]@{
    code    = $code
    payload = ($line | ConvertFrom-Json)
  }
}

function Invoke-SilmarilJson {
  param([string[]]$CliArgs)

  $result = Invoke-SilmarilRaw -CliArgs $CliArgs
  if ($result.code -ne 0) {
    throw ("Silmaril command failed: " + (($result.payload | ConvertTo-Json -Compress -Depth 20)))
  }

  return $result.payload
}

function Invoke-SilmarilJsonEventually {
  param(
    [string[]]$CliArgs,
    [scriptblock]$Validator = $null,
    [int]$Attempts = 10,
    [int]$DelayMs = 500
  )

  if ($Attempts -lt 1) {
    throw 'Attempts must be >= 1.'
  }

  $lastResult = $null
  for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
    $lastResult = Invoke-SilmarilRaw -CliArgs $CliArgs
    if ($lastResult.code -eq 0) {
      if ($null -eq $Validator) {
        return $lastResult.payload
      }

      if (& $Validator $lastResult.payload) {
        return $lastResult.payload
      }
    }

    if ($attempt -lt $Attempts) {
      Start-Sleep -Milliseconds $DelayMs
    }
  }

  if ($null -ne $lastResult) {
    if ($lastResult.code -eq 0) {
      throw ("Silmaril command did not reach the expected state: " + (($lastResult.payload | ConvertTo-Json -Compress -Depth 20)))
    }

    throw ("Silmaril command failed: " + (($lastResult.payload | ConvertTo-Json -Compress -Depth 20)))
  }

  throw 'Silmaril command did not produce a result.'
}
