param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1")

$common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout
$RemainingArgs = @($common.RemainingArgs)
$port = [int]$common.Port
$targetId = [string]$common.TargetId
$urlMatch = [string]$common.UrlMatch
$timeoutMs = [int]$common.TimeoutMs

$coverage = "viewport"
$filteredArgs = @()
$i = 0
while ($i -lt $RemainingArgs.Count) {
  $arg = [string]$RemainingArgs[$i]
  $argLower = $arg.ToLowerInvariant()

  switch ($argLower) {
    "--coverage" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "--coverage requires one of: viewport, content."
      }

      $coverage = ([string]$RemainingArgs[$i + 1]).Trim().ToLowerInvariant()
      if ($coverage -notin @("viewport", "content")) {
        throw "--coverage must be one of: viewport, content."
      }

      $i += 2
      continue
    }
    default {
      $filteredArgs += $arg
      $i += 1
      continue
    }
  }
}

if ($filteredArgs.Count -ne 0) {
  throw "snapshot takes no positional arguments. Supported flags: --coverage viewport|content, --port, --target-id, --url-match, --timeout-ms"
}

$runtimePath = Join-Path -Path $scriptRoot -ChildPath "tools/snapshot-runtime.js"
$runtime = Read-SilmarilTextFile -Path $runtimePath -Label "Snapshot runtime" -MaxBytes 1048576
$runtimeOptions = [ordered]@{
  coverage = $coverage
}
$runtimeOptionsJs = $runtimeOptions | ConvertTo-Json -Compress

$targetContext = Resolve-SilmarilPageTarget -Port $port -TargetId $targetId -UrlMatch $urlMatch
$target = $targetContext.Target
$timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $timeoutMs -PaddingMs 3000 -MinSeconds 10
$expression = "globalThis.__silmarilSnapshotOptions = $runtimeOptionsJs;`n$([string]$runtime.content)"
$evalResult = Invoke-SilmarilRuntimeEvaluate -Target $target -Expression $expression -TimeoutSec $timeoutSec
$value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "snapshot"
if ($null -eq $value) {
  throw "snapshot result value is null."
}

$capturedAtUtc = [DateTime]::UtcNow.ToString("o")
$refs = @()
if ($value.PSObject.Properties.Name -contains "refs" -and $null -ne $value.refs) {
  $refs = @($value.refs)
}
$nodes = @()
if ($value.PSObject.Properties.Name -contains "nodes" -and $null -ne $value.nodes) {
  $nodes = @($value.nodes)
}
$lines = @()
if ($value.PSObject.Properties.Name -contains "lines" -and $null -ne $value.lines) {
  $lines = @($value.lines)
}

$snapshotState = [ordered]@{
  snapshotToken = [string]$value.snapshotToken
  coverage      = [string]$value.coverage
  viewportOnly  = [bool]$value.viewportOnly
  capturedAtUtc = $capturedAtUtc
  target        = [ordered]@{
    id            = [string]$targetContext.ResolvedTargetId
    url           = [string]$targetContext.ResolvedUrl
    title         = [string]$targetContext.ResolvedTitle
    comparableUrl = Get-SilmarilComparableUrl -Url ([string]$targetContext.ResolvedUrl)
  }
  refs          = $refs
}
Save-SilmarilSnapshotState -Port $port -State $snapshotState

$text = if ($lines.Count -gt 0) { $lines -join [Environment]::NewLine } else { "Snapshot captured." }
$data = Add-SilmarilTargetMetadata -Data ([ordered]@{
  snapshotToken = [string]$value.snapshotToken
  coverage      = [string]$value.coverage
  viewportOnly  = [bool]$value.viewportOnly
  refCount      = [int]$value.refCount
  capturedAtUtc = $capturedAtUtc
  refs          = $refs
  nodes         = $nodes
}) -TargetContext $targetContext

Write-SilmarilCommandResult -Command "snapshot" -Text $text -Data $data -Depth 30
