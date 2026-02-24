param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonPath = Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1"

if (-not (Test-Path -Path $commonPath)) {
  Write-Error "Missing required file: $commonPath"
  exit 1
}

. $commonPath

function Show-Usage {
  Write-Host "Usage:"
  Write-Host "  silmaril.cmd openbrowser"
  Write-Host "  silmaril.cmd openUrl ""url"""
  Write-Host "  silmaril.cmd get-currentUrl"
  Write-Host "  silmaril.cmd list-urls"
  Write-Host "  silmaril.cmd get-dom [""selector""]"
  Write-Host "  silmaril.cmd get-text ""selector"""
  Write-Host "  silmaril.cmd set-html ""selector"" ""html"" --yes"
  Write-Host "  silmaril.cmd set-text ""selector"" ""text"" --yes"
  Write-Host "  silmaril.cmd click ""selector"" --yes"
  Write-Host "  silmaril.cmd get-source"
}

function Invoke-CommandScript {
  param(
    [string]$CommandName,
    [string[]]$CommandArgs
  )

  $commandScript = Join-Path -Path $scriptRoot -ChildPath ("commands\" + $CommandName + ".ps1")
  if (-not (Test-Path -Path $commandScript)) {
    throw "Missing command implementation: $commandScript"
  }

  & $commandScript -RemainingArgs $CommandArgs
}

try {
  if (-not $RemainingArgs -or $RemainingArgs.Count -lt 1) {
    Show-Usage
    throw "Command required."
  }

  $command = $RemainingArgs[0].ToLowerInvariant()
  $commandArgs = @()
  if ($RemainingArgs.Count -gt 1) {
    $commandArgs = $RemainingArgs[1..($RemainingArgs.Count - 1)]
  }

  switch ($command) {
    "openbrowser" {
      Invoke-CommandScript -CommandName "openbrowser" -CommandArgs $commandArgs
    }
    "openurl" {
      Invoke-CommandScript -CommandName "openurl" -CommandArgs $commandArgs
    }
    "get-currenturl" {
      Invoke-CommandScript -CommandName "get-currenturl" -CommandArgs $commandArgs
    }
    "list-urls" {
      Invoke-CommandScript -CommandName "list-urls" -CommandArgs $commandArgs
    }
    "get-dom" {
      Invoke-CommandScript -CommandName "get-dom" -CommandArgs $commandArgs
    }
    "get-text" {
      Invoke-CommandScript -CommandName "get-text" -CommandArgs $commandArgs
    }
    "set-html" {
      Invoke-CommandScript -CommandName "set-html" -CommandArgs $commandArgs
    }
    "set-text" {
      Invoke-CommandScript -CommandName "set-text" -CommandArgs $commandArgs
    }
    "click" {
      Invoke-CommandScript -CommandName "click" -CommandArgs $commandArgs
    }
    "get-source" {
      Invoke-CommandScript -CommandName "get-source" -CommandArgs $commandArgs
    }
    default {
      Show-Usage
      throw "Unsupported command '$($RemainingArgs[0])'."
    }
  }
}
catch {
  Write-Error $_.Exception.Message
  exit 1
}
