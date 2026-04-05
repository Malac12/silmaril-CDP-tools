param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonPath = Join-Path -Path $scriptRoot -ChildPath "lib/common.ps1"

if (-not (Test-Path -Path $commonPath)) {
  Write-Error "Missing required file: $commonPath"
  exit 1
}

. $commonPath

function Show-Usage {
  $cliName = Get-SilmarilCliName
  Write-Host "Usage:"
  Write-Host "  $cliName openbrowser [--port n] [--timeout-ms n] [--poll-ms n] [--json]"
  Write-Host "  $cliName openUrl \"url\" [--port n] [--timeout-ms n] [--json]"
  Write-Host "  $cliName openurl-proxy \"url\" --allow-mitm [--allow-nonlocal-bind] [--listen-host host] [--listen-port port] [--rules-file \"path\"] [--profile-dir \"path\"] [--port n] [--timeout-ms n] [--poll-ms n] [--json]"
  Write-Host "  $cliName target-show [--port n] [--json]"
  Write-Host "  $cliName target-pin (--current | --target-id id | --url-match regex) --yes [--port n] [--json]"
  Write-Host "  $cliName target-clear --yes [--port n] [--json]"
  Write-Host "  $cliName get-currentUrl [--port n] [--json]"
  Write-Host "  $cliName list-urls [--port n] [--json]"
  Write-Host "  $cliName get-dom [\"selector\"] [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--json]"
  Write-Host "  $cliName get-text \"selector\" [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--json]"
  Write-Host "  $cliName query \"selector\" [--fields \"f1,f2,attr:name,prop:name\"] [--limit n] [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--json]"
  Write-Host "  $cliName exists \"selector\" [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--json]"
  Write-Host "  $cliName set-html \"selector\" (\"html\" | --html-file \"path\") --yes [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--json]"
  Write-Host "  $cliName set-text \"selector\" (\"text\" | --text-file \"path\") --yes [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--json]"
  Write-Host "  $cliName type \"selector\" (\"text\" | --text-file \"path\") --yes [--visual-cursor] [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--json]"
  Write-Host "  $cliName click \"selector\" --yes [--visual-cursor] [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--json]"
  Write-Host "  $cliName wait-for \"selector\" [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--poll-ms n] [--json]"
  Write-Host "  $cliName wait-for-any \"selector1\" \"selector2\" [\"selectorN\"...] [--counts] [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--poll-ms n] [--json]"
  Write-Host "  $cliName wait-for-gone \"selector\" [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--poll-ms n] [--json]"
  Write-Host "  $cliName wait-until-js \"expression\" [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--poll-ms n] [--json]"
  Write-Host "  $cliName wait-for-mutation [\"selector\"] [--details] [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--poll-ms n] [--json]"
  Write-Host "  $cliName eval-js \"expression\" --allow-unsafe-js --yes [--isolate-scope] [--result-json] [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--json]"
  Write-Host "  $cliName eval-js --file \"path-to-js\" --allow-unsafe-js --yes [--isolate-scope] [--result-json] [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--json]"
  Write-Host "  $cliName proxy-override [--allow-mitm] [--allow-nonlocal-bind] [--match \"url-regex\" --file \"local-file\" --yes] [--content-type \"mime\"] [--status code] [--rules-file \"path\"] [--listen-host host] [--listen-port port] [--mitmdump \"path\"] [--attach] [--dry-run] [--json]"
  Write-Host "  $cliName proxy-switch --match \"url-regex\" --original-file \"path\" --saved-file \"path\" --use (original|saved) --allow-mitm --yes [--status code] [--content-type \"mime\"] [--rules-file \"path\"] [--json]"
  Write-Host "  $cliName get-source [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--json]"
  Write-Host "  $cliName run \"flow.json\" [--artifacts-dir \"path\"] [--port n] [--target-id id | --url-match regex] [--timeout-ms n] [--poll-ms n] [--json]"
}

function Invoke-CommandScript {
  param(
    [string]$CommandName,
    [string[]]$CommandArgs,
    [bool]$JsonOutput = $false
  )

  $commandScript = Join-Path -Path $scriptRoot -ChildPath ("commands/" + $CommandName + ".ps1")
  if (-not (Test-Path -Path $commandScript)) {
    throw "Missing command implementation: $commandScript"
  }

  $hadPreviousJsonMode = Test-Path Env:SILMARIL_OUTPUT_JSON
  $previousJsonMode = $null
  if ($hadPreviousJsonMode) {
    $previousJsonMode = $env:SILMARIL_OUTPUT_JSON
  }

  try {
    if ($JsonOutput) {
      $env:SILMARIL_OUTPUT_JSON = "1"
    }
    else {
      Remove-Item Env:SILMARIL_OUTPUT_JSON -ErrorAction SilentlyContinue
    }

    & $commandScript -RemainingArgs $CommandArgs
  }
  finally {
    if ($hadPreviousJsonMode) {
      $env:SILMARIL_OUTPUT_JSON = $previousJsonMode
    }
    else {
      Remove-Item Env:SILMARIL_OUTPUT_JSON -ErrorAction SilentlyContinue
    }
  }
}

$jsonOutput = $false
$command = $null

try {
  if (-not $RemainingArgs -or $RemainingArgs.Count -lt 1) {
    if (-not $jsonOutput) {
      Show-Usage
    }
    throw "Command required."
  }

  $command = $RemainingArgs[0].ToLowerInvariant()
  $commandArgs = @()
  if ($RemainingArgs.Count -gt 1) {
    $commandArgs = $RemainingArgs[1..($RemainingArgs.Count - 1)]
  }

  if ($commandArgs.Count -gt 0) {
    $lastArg = $commandArgs[$commandArgs.Count - 1]
    if ([string]::Equals($lastArg, "--json", [System.StringComparison]::OrdinalIgnoreCase)) {
      $jsonOutput = $true
      if ($commandArgs.Count -eq 1) {
        $commandArgs = @()
      }
      else {
        $commandArgs = $commandArgs[0..($commandArgs.Count - 2)]
      }
    }
  }

  switch ($command) {
    "openbrowser" { Invoke-CommandScript -CommandName "openbrowser" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "openurl" { Invoke-CommandScript -CommandName "openurl" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "openurl-proxy" { Invoke-CommandScript -CommandName "openurl-proxy" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "target-show" { Invoke-CommandScript -CommandName "target-show" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "target-pin" { Invoke-CommandScript -CommandName "target-pin" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "target-clear" { Invoke-CommandScript -CommandName "target-clear" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "get-currenturl" { Invoke-CommandScript -CommandName "get-currenturl" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "list-urls" { Invoke-CommandScript -CommandName "list-urls" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "get-dom" { Invoke-CommandScript -CommandName "get-dom" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "get-text" { Invoke-CommandScript -CommandName "get-text" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "query" { Invoke-CommandScript -CommandName "query" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "exists" { Invoke-CommandScript -CommandName "exists" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "set-html" { Invoke-CommandScript -CommandName "set-html" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "set-text" { Invoke-CommandScript -CommandName "set-text" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "type" { Invoke-CommandScript -CommandName "type" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "click" { Invoke-CommandScript -CommandName "click" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "wait-for" { Invoke-CommandScript -CommandName "wait-for" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "wait-for-any" { Invoke-CommandScript -CommandName "wait-for-any" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "wait-for-gone" { Invoke-CommandScript -CommandName "wait-for-gone" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "wait-until-js" { Invoke-CommandScript -CommandName "wait-until-js" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "wait-for-mutation" { Invoke-CommandScript -CommandName "wait-for-mutation" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "eval-js" { Invoke-CommandScript -CommandName "eval-js" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "proxy-override" { Invoke-CommandScript -CommandName "proxy-override" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "proxy-switch" { Invoke-CommandScript -CommandName "proxy-switch" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "get-source" { Invoke-CommandScript -CommandName "get-source" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    "run" { Invoke-CommandScript -CommandName "run" -CommandArgs $commandArgs -JsonOutput $jsonOutput }
    default {
      if (-not $jsonOutput) {
        Show-Usage
      }
      throw "Unsupported command '$($RemainingArgs[0])'."
    }
  }
}
catch {
  $errorPayload = Get-SilmarilErrorContract -Command $command -Message $_.Exception.Message
  if ($jsonOutput) {
    Write-SilmarilJson -Value $errorPayload -Depth 10
  }
  else {
    Write-Error ("[{0}] {1}`nHint: {2}" -f $errorPayload.code, $errorPayload.message, $errorPayload.hint)
  }
  exit 1
}
