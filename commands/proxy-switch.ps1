param(
  [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path -Path $scriptRoot -ChildPath "lib\common.ps1")

if (-not $RemainingArgs) {
  $RemainingArgs = @()
}

$matchRegex = $null
$originalFileRaw = $null
$savedFileRaw = $null
$useMode = $null
$rulesFile = Join-Path -Path $scriptRoot -ChildPath "tools\mitm\rules.json"
$statusCode = $null
$contentType = $null
$confirmWrite = $false

$i = 0
while ($i -lt $RemainingArgs.Count) {
  $arg = [string]$RemainingArgs[$i]
  $argLower = $arg.ToLowerInvariant()

  switch ($argLower) {
    "--match" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-switch --match requires a regex pattern."
      }
      $matchRegex = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--original-file" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-switch --original-file requires a path."
      }
      $originalFileRaw = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--saved-file" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-switch --saved-file requires a path."
      }
      $savedFileRaw = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--use" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-switch --use requires either 'original' or 'saved'."
      }
      $useMode = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--rules-file" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-switch --rules-file requires a path."
      }
      $rulesFile = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--status" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-switch --status requires an integer value."
      }
      $rawStatus = [string]$RemainingArgs[$i + 1]
      $parsedStatus = 0
      if (-not [int]::TryParse($rawStatus, [ref]$parsedStatus)) {
        throw "proxy-switch --status must be an integer. Received: $rawStatus"
      }
      if ($parsedStatus -lt 100 -or $parsedStatus -gt 599) {
        throw "proxy-switch --status must be between 100 and 599."
      }
      $statusCode = $parsedStatus
      $i += 2
      continue
    }
    "--content-type" {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "proxy-switch --content-type requires a MIME type value."
      }
      $contentType = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }
    "--yes" {
      $confirmWrite = $true
      $i += 1
      continue
    }
    default {
      throw "Unsupported flag '$arg' for proxy-switch."
    }
  }
}

if ([string]::IsNullOrWhiteSpace($matchRegex)) {
  throw "proxy-switch requires --match."
}
if ([string]::IsNullOrWhiteSpace($originalFileRaw)) {
  throw "proxy-switch requires --original-file."
}
if ([string]::IsNullOrWhiteSpace($savedFileRaw)) {
  throw "proxy-switch requires --saved-file."
}
if ([string]::IsNullOrWhiteSpace($useMode)) {
  throw "proxy-switch requires --use original|saved."
}
if (-not $confirmWrite) {
  throw "proxy-switch requires explicit confirmation flag --yes."
}

$useLower = $useMode.ToLowerInvariant()
if ($useLower -ne "original" -and $useLower -ne "saved") {
  throw "proxy-switch --use must be 'original' or 'saved'."
}

$originalResolved = Resolve-Path -LiteralPath $originalFileRaw -ErrorAction SilentlyContinue
if (-not $originalResolved) {
  throw "Original file not found: $originalFileRaw"
}
$originalFile = [string]$originalResolved.Path

$savedResolved = Resolve-Path -LiteralPath $savedFileRaw -ErrorAction SilentlyContinue
if (-not $savedResolved) {
  throw "Saved file not found: $savedFileRaw"
}
$savedFile = [string]$savedResolved.Path

$selectedFile = if ($useLower -eq "original") { $originalFile } else { $savedFile }

$resolvedRules = $rulesFile
$rulesResolvedInfo = Resolve-Path -LiteralPath $rulesFile -ErrorAction SilentlyContinue
if ($rulesResolvedInfo) {
  $resolvedRules = [string]$rulesResolvedInfo.Path
}
else {
  $rulesParent = Split-Path -Parent $rulesFile
  if ([string]::IsNullOrWhiteSpace($rulesParent)) {
    throw "Invalid --rules-file path: $rulesFile"
  }
  New-Item -Path $rulesParent -ItemType Directory -Force | Out-Null
  $resolvedRules = [System.IO.Path]::GetFullPath($rulesFile)
}

$rulesObject = [ordered]@{ rules = @() }
if (Test-Path -LiteralPath $resolvedRules) {
  $rawRules = Get-Content -LiteralPath $resolvedRules -Raw -Encoding UTF8
  if (-not [string]::IsNullOrWhiteSpace($rawRules)) {
    try {
      $parsedRules = $rawRules | ConvertFrom-Json
    }
    catch {
      throw "Failed to parse rules file JSON: $resolvedRules"
    }

    if ($parsedRules) {
      $rulesObject = [ordered]@{}
      foreach ($prop in $parsedRules.PSObject.Properties) {
        $rulesObject[$prop.Name] = $prop.Value
      }
    }
  }
}

if (-not $rulesObject.Contains("rules") -or $null -eq $rulesObject["rules"]) {
  $rulesObject["rules"] = @()
}

$rulesList = @($rulesObject["rules"])
$existingRule = $null
$existingIndex = -1
for ($idx = 0; $idx -lt $rulesList.Count; $idx++) {
  $candidate = $rulesList[$idx]
  if ($null -eq $candidate) {
    continue
  }

  if ([string]::Equals([string]$candidate.match, $matchRegex, [System.StringComparison]::Ordinal)) {
    $existingRule = $candidate
    $existingIndex = $idx
    break
  }
}

$finalStatus = 200
if ($null -ne $statusCode) {
  $finalStatus = [int]$statusCode
}
elseif ($null -ne $existingRule -and (Get-SilmarilPropertyNames -InputObject $existingRule) -contains "status" -and $null -ne $existingRule.status) {
  $finalStatus = [int]$existingRule.status
}

$finalContentType = $contentType
if (
  [string]::IsNullOrWhiteSpace($finalContentType) -and
  $null -ne $existingRule -and
  (Get-SilmarilPropertyNames -InputObject $existingRule) -contains "contentType" -and
  $null -ne $existingRule.contentType
) {
  $finalContentType = [string]$existingRule.contentType
}

$newRule = [ordered]@{
  match  = $matchRegex
  file   = $selectedFile
  status = $finalStatus
}
if (-not [string]::IsNullOrWhiteSpace($finalContentType)) {
  $newRule["contentType"] = $finalContentType
}

$action = "added"
if ($existingIndex -ge 0) {
  $rulesList[$existingIndex] = [pscustomobject]$newRule
  $action = "updated"
}
else {
  $rulesList += [pscustomobject]$newRule
}

$rulesObject["rules"] = @($rulesList)
$rulesJson = $rulesObject | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($resolvedRules, $rulesJson, [System.Text.UTF8Encoding]::new($false))

Write-SilmarilCommandResult -Command "proxy-switch" -Text "Switched rule to $useLower file for match: $matchRegex" -Data @{
  match        = $matchRegex
  use          = $useLower
  selectedFile = $selectedFile
  originalFile = $originalFile
  savedFile    = $savedFile
  rulesFile    = $resolvedRules
  action       = $action
  status       = $finalStatus
  contentType  = $finalContentType
}
