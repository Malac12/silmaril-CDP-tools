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

$seedScript = @'
document.title = "Silmaril Smoke";
document.body.innerHTML = '<main id="app"><h1 id="title">Smoke Title</h1><button id="go">Go</button></main>';
true;
'@
$seed = Invoke-SilmarilJson -CliArgs @('eval-js', $seedScript, '--allow-unsafe-js', '--yes', '--port', ([string]$Port), '--timeout-ms', '7000')
Assert-SilmarilTrue -Condition ([bool]$seed.ok) -Message 'Initial page seed failed.'

$wait = Invoke-SilmarilJson -CliArgs @('wait-for', '#title', '--port', ([string]$Port), '--timeout-ms', '7000', '--poll-ms', '100')
Assert-SilmarilTrue -Condition ([bool]$wait.ok) -Message 'wait-for failed.'

$text = Invoke-SilmarilJson -CliArgs @('get-text', '#title', '--port', ([string]$Port), '--timeout-ms', '7000')
Assert-SilmarilEqual -Actual ([string]$text.text) -Expected 'Smoke Title' -Message 'Unexpected initial title text.'

$urls = Invoke-SilmarilJson -CliArgs @('list-urls', '--port', ([string]$Port))
Assert-SilmarilTrue -Condition ([bool]$urls.ok) -Message 'list-urls failed.'
Assert-SilmarilTrue -Condition ((@($urls.targets).Count) -gt 0) -Message 'list-urls returned no targets.'

$setText = Invoke-SilmarilJson -CliArgs @('set-text', '#title', 'Smoke Title Updated', '--yes', '--port', ([string]$Port), '--timeout-ms', '7000')
Assert-SilmarilTrue -Condition ([bool]$setText.ok) -Message 'set-text failed.'

$updated = Invoke-SilmarilJson -CliArgs @('get-text', '#title', '--port', ([string]$Port), '--timeout-ms', '7000')
Assert-SilmarilEqual -Actual ([string]$updated.text) -Expected 'Smoke Title Updated' -Message 'Title text did not update.'

$eval = Invoke-SilmarilJson -CliArgs @('eval-js', 'document.title', '--allow-unsafe-js', '--yes', '--port', ([string]$Port), '--timeout-ms', '7000')
Assert-SilmarilTrue -Condition ([bool]$eval.ok) -Message 'eval-js failed.'

Write-Host 'macOS smoke test completed successfully.'
