param(
  [string]$SilmarilCommand = "",
  [int]$Port = 9222
)

$ErrorActionPreference = 'Stop'

if (-not ((Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS)) {
  throw 'Run-Mac-Smoke.ps1 must be executed on macOS.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SilmarilCommand)) {
  $SilmarilCommand = Join-Path $repoRoot 'silmaril-mac.sh'
}

if (-not (Test-Path -LiteralPath $SilmarilCommand)) {
  throw "Silmaril mac launcher not found: $SilmarilCommand"
}

function Assert-SilmarilTrue {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-SilmarilEqual {
  param(
    [object]$Actual,
    [object]$Expected,
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw ("{0} Expected='{1}' Actual='{2}'" -f $Message, $Expected, $Actual)
  }
}

function Invoke-SilmarilJson {
  param([string[]]$CliArgs)

  $output = & bash $SilmarilCommand @CliArgs '--json' 2>&1
  $code = $LASTEXITCODE
  if ([string]$env:SILMARIL_CDP_TRACE -eq '1') {
    foreach ($entry in @($output)) {
      $text = [string]$entry
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        Write-Host ("TRACE_CMD " + $text)
      }
    }
  }
  $line = ($output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($line)) {
    throw 'No output from silmaril command.'
  }

  $payload = $line | ConvertFrom-Json
  if ($code -ne 0) {
    throw ("Silmaril command failed: " + ($payload | ConvertTo-Json -Compress -Depth 20))
  }

  return $payload
}

$open = Invoke-SilmarilJson -CliArgs @('openbrowser', '--port', ([string]$Port), '--timeout-ms', '15000', '--poll-ms', '300')
Assert-SilmarilTrue -Condition ([bool]$open.ok) -Message 'openbrowser failed.'

$seedHtml = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Silmaril Smoke</title>
</head>
<body>
  <main id="app">
    <h1 id="title">Smoke Title</h1>
    <button id="go">Go</button>
  </main>
</body>
</html>
'@
$seedUrl = 'data:text/html;charset=utf-8,' + [System.Uri]::EscapeDataString($seedHtml)
$seed = Invoke-SilmarilJson -CliArgs @('openurl', $seedUrl, '--port', ([string]$Port), '--timeout-ms', '7000')
Assert-SilmarilTrue -Condition ([bool]$seed.ok) -Message 'Initial page openurl failed.'

$wait = Invoke-SilmarilJson -CliArgs @('wait-for', '#title', '--port', ([string]$Port), '--timeout-ms', '7000', '--poll-ms', '100')
Assert-SilmarilTrue -Condition ([bool]$wait.ok) -Message 'wait-for failed.'

$text = Invoke-SilmarilJson -CliArgs @('get-text', '#title', '--port', ([string]$Port), '--timeout-ms', '7000')
Assert-SilmarilEqual -Actual ([string]$text.text) -Expected 'Smoke Title' -Message 'Unexpected initial title text.'

$urls = Invoke-SilmarilJson -CliArgs @('list-urls', '--port', ([string]$Port))
Assert-SilmarilTrue -Condition ([bool]$urls.ok) -Message 'list-urls failed.'
Assert-SilmarilTrue -Condition ((@($urls.targets).Count) -gt 0) -Message 'list-urls returned no targets.'

$pages = Invoke-SilmarilJson -CliArgs @('list-pages', '--port', ([string]$Port))
Assert-SilmarilTrue -Condition ([bool]$pages.ok) -Message 'list-pages failed.'
Assert-SilmarilTrue -Condition ((@($pages.pages).Count) -gt 0) -Message 'list-pages returned no pages.'

$setPage = Invoke-SilmarilJson -CliArgs @('set-page', '--current', '--yes', '--port', ([string]$Port))
Assert-SilmarilTrue -Condition ([bool]$setPage.ok) -Message 'set-page failed.'

$setText = Invoke-SilmarilJson -CliArgs @('set-text', '#title', 'Smoke Title Updated', '--yes', '--port', ([string]$Port), '--timeout-ms', '7000')
Assert-SilmarilTrue -Condition ([bool]$setText.ok) -Message 'set-text failed.'

$updated = Invoke-SilmarilJson -CliArgs @('get-text', '#title', '--port', ([string]$Port), '--timeout-ms', '7000')
Assert-SilmarilEqual -Actual ([string]$updated.text) -Expected 'Smoke Title Updated' -Message 'Title text did not update.'

$eval = Invoke-SilmarilJson -CliArgs @('eval-js', 'document.title', '--allow-unsafe-js', '--yes', '--port', ([string]$Port), '--timeout-ms', '7000')
Assert-SilmarilTrue -Condition ([bool]$eval.ok) -Message 'eval-js failed.'

Write-Host 'macOS smoke test completed successfully.'
