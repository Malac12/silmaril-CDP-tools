Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SilmarilObjectPropertyValue {
  param(
    [object]$InputObject,
    [string]$Name,
    [object]$DefaultValue = $null
  )

  if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace($Name)) {
    return $DefaultValue
  }

  $propertyNames = @(Get-SilmarilPropertyNames -InputObject $InputObject)
  if (-not ($propertyNames -contains $Name)) {
    return $DefaultValue
  }

  return $InputObject.$Name
}

function Get-SilmarilStringArray {
  param(
    [object]$Value
  )

  if ($null -eq $Value) {
    return @()
  }

  $items = @()
  foreach ($entry in @($Value)) {
    if ($null -eq $entry) {
      continue
    }

    $text = ([string]$entry).Trim()
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      $items += $text
    }
  }

  return @($items)
}

function ConvertTo-SilmarilConfidenceValue {
  param(
    [object]$Value,
    [double]$DefaultValue = 0.5
  )

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return [double]$DefaultValue
  }

  $parsed = 0.0
  if (-not [double]::TryParse(([string]$Value), [ref]$parsed)) {
    throw "Confidence must be a number between 0 and 1."
  }

  if ($parsed -lt 0 -or $parsed -gt 1) {
    throw "Confidence must be between 0 and 1."
  }

  return [double]$parsed
}

function Get-SilmarilPageMemoryRoot {
  return (Join-Path -Path (Get-SilmarilStateRoot) -ChildPath "page-memory")
}

function Get-SilmarilPageMemoryRecordDirectory {
  param(
    [ValidateSet("stable", "session")]
    [string]$RecordType
  )

  return (Join-Path -Path (Get-SilmarilPageMemoryRoot) -ChildPath $RecordType)
}

function Test-SilmarilPageMemoryId {
  param(
    [string]$Id
  )

  if ([string]::IsNullOrWhiteSpace($Id)) {
    return $false
  }

  return ($Id -match '^[A-Za-z0-9._-]+$')
}

function Assert-SilmarilPageMemoryId {
  param(
    [string]$Id
  )

  if (-not (Test-SilmarilPageMemoryId -Id $Id)) {
    throw "Page memory id must match ^[A-Za-z0-9._-]+$."
  }
}

function Get-SilmarilPageMemoryRecordPath {
  param(
    [ValidateSet("stable", "session")]
    [string]$RecordType,
    [string]$Id
  )

  Assert-SilmarilPageMemoryId -Id $Id
  return (Join-Path -Path (Get-SilmarilPageMemoryRecordDirectory -RecordType $RecordType) -ChildPath ($Id + ".json"))
}

function Get-SilmarilPageMemoryExactUrl {
  param(
    [object]$Profile
  )

  $exactUrl = [string](Get-SilmarilObjectPropertyValue -InputObject $Profile -Name "exactUrl" -DefaultValue "")
  if ([string]::IsNullOrWhiteSpace($exactUrl)) {
    return ""
  }

  return (Get-SilmarilComparableUrl -Url $exactUrl)
}

function ConvertTo-SilmarilPageMemorySelectorRecord {
  param(
    [object]$Value
  )

  if ($null -eq $Value) {
    throw "Selector entries cannot be null."
  }

  $name = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "name" -DefaultValue "")).Trim()
  $selector = Normalize-SilmarilSelector -Selector ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "selector" -DefaultValue ""))
  $purpose = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "purpose" -DefaultValue "")).Trim()

  if ([string]::IsNullOrWhiteSpace($name)) {
    throw "Selector entries require a non-empty name."
  }
  if ([string]::IsNullOrWhiteSpace($selector)) {
    throw "Selector entries require a non-empty selector."
  }

  return [ordered]@{
    name           = $name
    selector       = $selector
    purpose        = $purpose
    confidence     = ConvertTo-SilmarilConfidenceValue -Value (Get-SilmarilObjectPropertyValue -InputObject $Value -Name "confidence" -DefaultValue 0.9) -DefaultValue 0.9
    lastVerifiedAt = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "lastVerifiedAt" -DefaultValue "")).Trim()
  }
}

function ConvertTo-SilmarilPageMemoryFactRecord {
  param(
    [object]$Value,
    [string]$Kind
  )

  if ($null -eq $Value) {
    throw "$Kind entries cannot be null."
  }

  $id = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "id" -DefaultValue "")).Trim()
  $statement = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "statement" -DefaultValue "")).Trim()
  if ([string]::IsNullOrWhiteSpace($statement)) {
    throw "$Kind entries require a non-empty statement."
  }

  return [ordered]@{
    id             = $id
    statement      = $statement
    confidence     = ConvertTo-SilmarilConfidenceValue -Value (Get-SilmarilObjectPropertyValue -InputObject $Value -Name "confidence" -DefaultValue 0.8) -DefaultValue 0.8
    evidence       = Get-SilmarilObjectPropertyValue -InputObject $Value -Name "evidence" -DefaultValue $null
    lastVerifiedAt = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "lastVerifiedAt" -DefaultValue "")).Trim()
  }
}

function ConvertTo-SilmarilPageMemoryPlaybookRecord {
  param(
    [object]$Value
  )

  if ($null -eq $Value) {
    throw "Playbook entries cannot be null."
  }

  $goal = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "goal" -DefaultValue "")).Trim()
  $steps = Get-SilmarilStringArray -Value (Get-SilmarilObjectPropertyValue -InputObject $Value -Name "steps" -DefaultValue @())
  if ($steps.Count -eq 0) {
    throw "Playbook entries require at least one step."
  }

  return [ordered]@{
    id             = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "id" -DefaultValue "")).Trim()
    goal           = $goal
    preconditions  = Get-SilmarilStringArray -Value (Get-SilmarilObjectPropertyValue -InputObject $Value -Name "preconditions" -DefaultValue @())
    steps          = @($steps)
    verification   = Get-SilmarilStringArray -Value (Get-SilmarilObjectPropertyValue -InputObject $Value -Name "verification" -DefaultValue @())
    confidence     = ConvertTo-SilmarilConfidenceValue -Value (Get-SilmarilObjectPropertyValue -InputObject $Value -Name "confidence" -DefaultValue 0.8) -DefaultValue 0.8
    lastVerifiedAt = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "lastVerifiedAt" -DefaultValue "")).Trim()
  }
}

function ConvertTo-SilmarilPageMemoryVerificationRecord {
  param(
    [object]$Value
  )

  if ($null -eq $Value) {
    return [ordered]@{
      selectors = @()
    }
  }

  return [ordered]@{
    selectors = @(
      Get-SilmarilStringArray -Value (Get-SilmarilObjectPropertyValue -InputObject $Value -Name "selectors" -DefaultValue @()) |
        ForEach-Object { Normalize-SilmarilSelector -Selector $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
  }
}

function ConvertTo-SilmarilStablePageMemoryRecord {
  param(
    [object]$Value
  )

  $id = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "id" -DefaultValue "")).Trim()
  Assert-SilmarilPageMemoryId -Id $id

  $profile = Get-SilmarilObjectPropertyValue -InputObject $Value -Name "profile" -DefaultValue $null
  if ($null -eq $profile) {
    throw "Stable page memory requires a profile object."
  }

  $domain = ([string](Get-SilmarilObjectPropertyValue -InputObject $profile -Name "domain" -DefaultValue "")).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($domain)) {
    throw "Stable page memory profile requires a non-empty domain."
  }

  $pathPattern = ([string](Get-SilmarilObjectPropertyValue -InputObject $profile -Name "pathPattern" -DefaultValue "")).Trim()
  if (-not [string]::IsNullOrWhiteSpace($pathPattern)) {
    [void][regex]::new($pathPattern)
  }

  $titlePattern = ([string](Get-SilmarilObjectPropertyValue -InputObject $profile -Name "titlePattern" -DefaultValue "")).Trim()
  if (-not [string]::IsNullOrWhiteSpace($titlePattern)) {
    [void][regex]::new($titlePattern)
  }

  $requiredMarkers = @(
    Get-SilmarilStringArray -Value (Get-SilmarilObjectPropertyValue -InputObject $profile -Name "requiredMarkers" -DefaultValue @()) |
      ForEach-Object { Normalize-SilmarilSelector -Selector $_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  $excludedMarkers = @(
    Get-SilmarilStringArray -Value (Get-SilmarilObjectPropertyValue -InputObject $profile -Name "excludedMarkers" -DefaultValue @()) |
      ForEach-Object { Normalize-SilmarilSelector -Selector $_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )

  $selectors = @()
  foreach ($selectorEntry in @(Get-SilmarilObjectPropertyValue -InputObject $Value -Name "selectors" -DefaultValue @())) {
    $selectors += [pscustomobject](ConvertTo-SilmarilPageMemorySelectorRecord -Value $selectorEntry)
  }

  $facts = @()
  foreach ($factEntry in @(Get-SilmarilObjectPropertyValue -InputObject $Value -Name "facts" -DefaultValue @())) {
    $facts += [pscustomobject](ConvertTo-SilmarilPageMemoryFactRecord -Value $factEntry -Kind "Fact")
  }

  $pitfalls = @()
  foreach ($pitfallEntry in @(Get-SilmarilObjectPropertyValue -InputObject $Value -Name "pitfalls" -DefaultValue @())) {
    $pitfalls += [pscustomobject](ConvertTo-SilmarilPageMemoryFactRecord -Value $pitfallEntry -Kind "Pitfall")
  }

  $playbooks = @()
  foreach ($playbookEntry in @(Get-SilmarilObjectPropertyValue -InputObject $Value -Name "playbooks" -DefaultValue @())) {
    $playbooks += [pscustomobject](ConvertTo-SilmarilPageMemoryPlaybookRecord -Value $playbookEntry)
  }

  $summary = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "summary" -DefaultValue "")).Trim()
  if ([string]::IsNullOrWhiteSpace($summary)) {
    throw "Stable page memory requires a non-empty summary."
  }

  return [ordered]@{
    recordType             = "stable"
    id                     = $id
    profile                = [ordered]@{
      scope           = ([string](Get-SilmarilObjectPropertyValue -InputObject $profile -Name "scope" -DefaultValue "page_type")).Trim()
      domain          = $domain
      pathPattern     = $pathPattern
      titlePattern    = $titlePattern
      exactUrl        = ([string](Get-SilmarilObjectPropertyValue -InputObject $profile -Name "exactUrl" -DefaultValue "")).Trim()
      requiredMarkers = @($requiredMarkers)
      excludedMarkers = @($excludedMarkers)
    }
    summary                = $summary
    selectors              = @($selectors)
    facts                  = @($facts)
    pitfalls               = @($pitfalls)
    playbooks              = @($playbooks)
    verification           = ConvertTo-SilmarilPageMemoryVerificationRecord -Value (Get-SilmarilObjectPropertyValue -InputObject $Value -Name "verification" -DefaultValue $null)
    confidence             = ConvertTo-SilmarilConfidenceValue -Value (Get-SilmarilObjectPropertyValue -InputObject $Value -Name "confidence" -DefaultValue 0.8) -DefaultValue 0.8
    lastVerifiedAt         = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "lastVerifiedAt" -DefaultValue "")).Trim()
    lastVerificationStatus = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "lastVerificationStatus" -DefaultValue "")).Trim()
    invalidated            = [bool](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "invalidated" -DefaultValue $false)
    invalidatedAtUtc       = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "invalidatedAtUtc" -DefaultValue "")).Trim()
    updatedAtUtc           = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "updatedAtUtc" -DefaultValue "")).Trim()
  }
}

function ConvertTo-SilmarilSessionPageMemoryRecord {
  param(
    [object]$Value
  )

  $id = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "id" -DefaultValue "")).Trim()
  Assert-SilmarilPageMemoryId -Id $id

  $session = Get-SilmarilObjectPropertyValue -InputObject $Value -Name "session" -DefaultValue $null
  if ($null -eq $session) {
    throw "Session page memory requires a session object."
  }

  $comparableUrl = ([string](Get-SilmarilObjectPropertyValue -InputObject $session -Name "comparableUrl" -DefaultValue "")).Trim()
  if (-not [string]::IsNullOrWhiteSpace($comparableUrl)) {
    $comparableUrl = Get-SilmarilComparableUrl -Url $comparableUrl
  }

  $targetId = ([string](Get-SilmarilObjectPropertyValue -InputObject $session -Name "targetId" -DefaultValue "")).Trim()
  $domain = ([string](Get-SilmarilObjectPropertyValue -InputObject $session -Name "domain" -DefaultValue "")).Trim().ToLowerInvariant()

  if ([string]::IsNullOrWhiteSpace($targetId) -and [string]::IsNullOrWhiteSpace($comparableUrl)) {
    throw "Session page memory requires session.targetId or session.comparableUrl."
  }

  if ([string]::IsNullOrWhiteSpace($domain) -and -not [string]::IsNullOrWhiteSpace($comparableUrl)) {
    try {
      $domain = ([System.Uri]::new($comparableUrl)).Host.ToLowerInvariant()
    }
    catch {
      $domain = ""
    }
  }

  $summary = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "summary" -DefaultValue "")).Trim()
  if ([string]::IsNullOrWhiteSpace($summary)) {
    throw "Session page memory requires a non-empty summary."
  }

  $selectors = @()
  foreach ($selectorEntry in @(Get-SilmarilObjectPropertyValue -InputObject $Value -Name "selectors" -DefaultValue @())) {
    $selectors += [pscustomobject](ConvertTo-SilmarilPageMemorySelectorRecord -Value $selectorEntry)
  }

  return [ordered]@{
    recordType             = "session"
    id                     = $id
    session                = [ordered]@{
      comparableUrl = $comparableUrl
      targetId      = $targetId
      domain        = $domain
    }
    summary                = $summary
    selectors              = @($selectors)
    verification           = ConvertTo-SilmarilPageMemoryVerificationRecord -Value (Get-SilmarilObjectPropertyValue -InputObject $Value -Name "verification" -DefaultValue $null)
    state                  = Get-SilmarilObjectPropertyValue -InputObject $Value -Name "state" -DefaultValue $null
    confidence             = ConvertTo-SilmarilConfidenceValue -Value (Get-SilmarilObjectPropertyValue -InputObject $Value -Name "confidence" -DefaultValue 0.8) -DefaultValue 0.8
    lastVerifiedAt         = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "lastVerifiedAt" -DefaultValue "")).Trim()
    lastVerificationStatus = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "lastVerificationStatus" -DefaultValue "")).Trim()
    invalidated            = [bool](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "invalidated" -DefaultValue $false)
    invalidatedAtUtc       = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "invalidatedAtUtc" -DefaultValue "")).Trim()
    updatedAtUtc           = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "updatedAtUtc" -DefaultValue "")).Trim()
  }
}

function ConvertTo-SilmarilPageMemoryRecord {
  param(
    [object]$Value
  )

  if ($null -eq $Value) {
    throw "Page memory file did not contain a record."
  }

  $recordType = ([string](Get-SilmarilObjectPropertyValue -InputObject $Value -Name "recordType" -DefaultValue "")).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($recordType)) {
    throw "Page memory record requires recordType set to stable or session."
  }

  switch ($recordType) {
    "stable" { return (ConvertTo-SilmarilStablePageMemoryRecord -Value $Value) }
    "session" { return (ConvertTo-SilmarilSessionPageMemoryRecord -Value $Value) }
    default { throw "Unsupported page memory recordType '$recordType'. Use stable or session." }
  }
}

function Read-SilmarilPageMemoryRecordFile {
  param(
    [string]$Path
  )

  $loaded = Read-SilmarilTextFile -Path $Path -Label "Page memory" -MaxBytes 1048576
  try {
    $parsed = ($loaded.content | ConvertFrom-Json)
  }
  catch {
    throw "Page memory file is not valid JSON: $Path"
  }

  return (ConvertTo-SilmarilPageMemoryRecord -Value $parsed)
}

function Get-SilmarilPageMemoryRecordPaths {
  param(
    [ValidateSet("stable", "session", "all")]
    [string]$RecordType = "all"
  )

  $paths = @()
  $types = @()
  switch ($RecordType) {
    "stable" { $types = @("stable") }
    "session" { $types = @("session") }
    default { $types = @("stable", "session") }
  }

  foreach ($type in $types) {
    $directory = Get-SilmarilPageMemoryRecordDirectory -RecordType $type
    if (-not (Test-Path -LiteralPath $directory)) {
      continue
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      $paths += [pscustomobject]@{
        recordType = $type
        path       = $file.FullName
      }
    }
  }

  return @($paths)
}

function Get-SilmarilPageMemoryRecords {
  param(
    [ValidateSet("stable", "session", "all")]
    [string]$RecordType = "all",
    [switch]$IncludeInvalidated
  )

  $records = @()
  foreach ($entry in @(Get-SilmarilPageMemoryRecordPaths -RecordType $RecordType)) {
    try {
      $record = Read-SilmarilPageMemoryRecordFile -Path ([string]$entry.path)
      if (-not $IncludeInvalidated -and [bool]$record.invalidated) {
        continue
      }

      $records += [pscustomobject]$record
    }
    catch {
      # Ignore malformed saved records during listing/lookup.
    }
  }

  return @($records)
}

function Get-SilmarilPageMemoryRecordById {
  param(
    [string]$Id
  )

  Assert-SilmarilPageMemoryId -Id $Id
  foreach ($record in @(Get-SilmarilPageMemoryRecords -RecordType all -IncludeInvalidated)) {
    if ([string]$record.id -eq $Id) {
      return $record
    }
  }

  return $null
}

function Save-SilmarilPageMemoryRecord {
  param(
    [hashtable]$Record
  )

  if ($null -eq $Record) {
    throw "Record cannot be null."
  }

  $recordType = [string]$Record.recordType
  $id = [string]$Record.id
  $existing = Get-SilmarilPageMemoryRecordById -Id $id
  if ($null -ne $existing -and [string]$existing.recordType -ne $recordType) {
    throw "Page memory id '$id' already exists with recordType '$($existing.recordType)'."
  }

  $directory = Get-SilmarilPageMemoryRecordDirectory -RecordType $recordType
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }

  $Record["updatedAtUtc"] = [DateTime]::UtcNow.ToString("o")
  $path = Get-SilmarilPageMemoryRecordPath -RecordType $recordType -Id $id
  Set-Content -LiteralPath $path -Encoding UTF8 -Value ($Record | ConvertTo-Json -Compress -Depth 20)
  return $path
}

function Get-SilmarilPageMemoryRecordDomain {
  param(
    [object]$Record
  )

  if ([string]$Record.recordType -eq "stable") {
    return ([string]$Record.profile.domain).Trim().ToLowerInvariant()
  }

  return ([string]$Record.session.domain).Trim().ToLowerInvariant()
}

function Get-SilmarilPageFingerprint {
  param(
    [object]$TargetContext
  )

  $url = [string]$TargetContext.ResolvedUrl
  $domain = ""
  $path = ""
  try {
    $uri = [System.Uri]::new($url)
    $domain = $uri.Host.ToLowerInvariant()
    $path = $uri.AbsolutePath
  }
  catch {
    $domain = ""
    $path = ""
  }

  return [ordered]@{
    targetId          = [string]$TargetContext.ResolvedTargetId
    url               = $url
    comparableUrl     = Get-SilmarilComparableUrl -Url $url
    title             = [string]$TargetContext.ResolvedTitle
    domain            = $domain
    path              = $path
    targetSelection   = [string]$TargetContext.SelectionMode
    targetStateSource = [string]$TargetContext.TargetStateSource
  }
}

function Get-SilmarilPageMemorySelectorStates {
  param(
    [psobject]$Target,
    [string[]]$Selectors,
    [int]$TimeoutMs = 10000
  )

  $normalizedSelectors = @(
    Get-SilmarilStringArray -Value $Selectors |
      ForEach-Object { Normalize-SilmarilSelector -Selector $_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
  )

  $states = [ordered]@{}
  foreach ($selector in $normalizedSelectors) {
    $states[$selector] = [pscustomobject]@{
      exists       = $false
      matchedCount = 0
      visibleCount = 0
      firstText    = ""
      firstRole    = ""
      firstLabel   = ""
      firstTag     = ""
      error        = ""
    }
  }

  if ($normalizedSelectors.Count -eq 0) {
    return $states
  }

  $selectorsJson = ConvertTo-Json -InputObject @($normalizedSelectors) -Compress -Depth 5
  $domSupportScript = Get-SilmarilDomSupportScript
  $expression = @"
(function(){
  const selectors = $selectorsJson;
  const result = {};
$($domSupportScript)
  for (const selector of selectors) {
    try {
      const nodes = Array.from(document.querySelectorAll(selector));
      const visibleNodes = nodes.filter(function(node){ return silmarilIsVisible(node); });
      const first = nodes.length > 0 ? silmarilDescribeElement(nodes[0]) : null;
      result[selector] = {
        exists: nodes.length > 0,
        matchedCount: nodes.length,
        visibleCount: visibleNodes.length,
        firstText: first ? String(first.text || '').slice(0, 200) : '',
        firstRole: first ? String(first.role || '') : '',
        firstLabel: first ? String(first.label || '') : '',
        firstTag: first ? String(first.tag || '') : '',
        error: ''
      };
    } catch (error) {
      result[selector] = {
        exists: false,
        matchedCount: 0,
        visibleCount: 0,
        firstText: '',
        firstRole: '',
        firstLabel: '',
        firstTag: '',
        error: String((error && error.message) ? error.message : error)
      };
    }
  }
  return result;
})()
"@

  $timeoutSec = ConvertTo-SilmarilTimeoutSec -TimeoutMs $TimeoutMs -PaddingMs 3000 -MinSeconds 10
  $evalResult = Invoke-SilmarilRuntimeEvaluate -Target $Target -Expression $expression -TimeoutSec $timeoutSec
  $value = Get-SilmarilEvalValue -EvalResult $evalResult -CommandName "page-memory selector probe"
  foreach ($name in @(Get-SilmarilPropertyNames -InputObject $value)) {
    $selectorState = $value.$name
    if ($selectorState -is [bool]) {
      $states[[string]$name] = [pscustomobject]@{
        exists       = [bool]$selectorState
        matchedCount = if ([bool]$selectorState) { 1 } else { 0 }
        visibleCount = 0
        firstText    = ""
        firstRole    = ""
        firstLabel   = ""
        firstTag     = ""
        error        = ""
      }
    }
    else {
      $states[[string]$name] = $selectorState
    }
  }

  return $states
}

function Get-SilmarilPageMemorySelectorExists {
  param(
    [hashtable]$SelectorStates,
    [string]$Selector
  )

  if ($null -eq $SelectorStates -or [string]::IsNullOrWhiteSpace($Selector)) {
    return $false
  }

  $state = $SelectorStates[$Selector]
  if ($null -eq $state) {
    return $false
  }

  if ($state -is [bool]) {
    return [bool]$state
  }

  $stateProps = @(Get-SilmarilPropertyNames -InputObject $state)
  if ($stateProps -contains "exists") {
    return [bool]$state.exists
  }

  return $false
}

function Get-SilmarilPageMemorySelectorState {
  param(
    [hashtable]$SelectorStates,
    [string]$Selector
  )

  if ($null -eq $SelectorStates -or [string]::IsNullOrWhiteSpace($Selector)) {
    return $null
  }

  $state = $SelectorStates[$Selector]
  if ($state -is [bool]) {
    return [pscustomobject]@{
      exists       = [bool]$state
      matchedCount = if ([bool]$state) { 1 } else { 0 }
      visibleCount = 0
      firstText    = ""
      firstRole    = ""
      firstLabel   = ""
      firstTag     = ""
      error        = ""
    }
  }

  return $state
}

function Get-SilmarilPageMemoryMatch {
  param(
    [object]$Record,
    [hashtable]$Fingerprint,
    [hashtable]$SelectorStates
  )

  if ($null -eq $Record -or $null -eq $Fingerprint) {
    return $null
  }

  if ([bool]$Record.invalidated) {
    return $null
  }

  $domain = Get-SilmarilPageMemoryRecordDomain -Record $Record
  if (-not [string]::IsNullOrWhiteSpace($domain) -and $domain -ne [string]$Fingerprint.domain) {
    return $null
  }

  if ([string]$Record.recordType -eq "session") {
    $sessionTargetId = ([string]$Record.session.targetId).Trim()
    $sessionComparableUrl = ([string]$Record.session.comparableUrl).Trim()
    $targetMatch = (-not [string]::IsNullOrWhiteSpace($sessionTargetId) -and $sessionTargetId -eq [string]$Fingerprint.targetId)
    $urlMatch = (-not [string]::IsNullOrWhiteSpace($sessionComparableUrl) -and $sessionComparableUrl -eq [string]$Fingerprint.comparableUrl)

    if (-not $targetMatch -and -not $urlMatch) {
      return $null
    }

    return [ordered]@{
      id            = [string]$Record.id
      recordType    = "session"
      matchLevel    = "exact"
      isRecommended = $true
      confidence    = [double]$Record.confidence
      summary       = [string]$Record.summary
      selectors     = @($Record.selectors)
      playbooks     = @()
      pitfalls      = @()
      state         = $Record.state
    }
  }

  $profile = $Record.profile
  $pathPattern = ([string]$profile.pathPattern).Trim()
  if (-not [string]::IsNullOrWhiteSpace($pathPattern) -and ([string]$Fingerprint.path -notmatch $pathPattern)) {
    return $null
  }

  $requiredMarkers = @(Get-SilmarilStringArray -Value $profile.requiredMarkers)
  foreach ($marker in $requiredMarkers) {
    if (-not (Get-SilmarilPageMemorySelectorExists -SelectorStates $SelectorStates -Selector $marker)) {
      return $null
    }
  }

  $excludedMarkers = @(Get-SilmarilStringArray -Value $profile.excludedMarkers)
  foreach ($marker in $excludedMarkers) {
    if (Get-SilmarilPageMemorySelectorExists -SelectorStates $SelectorStates -Selector $marker) {
      return $null
    }
  }

  $titlePattern = ([string]$profile.titlePattern).Trim()
  $titleMatched = $true
  if (-not [string]::IsNullOrWhiteSpace($titlePattern)) {
    $titleMatched = ([string]$Fingerprint.title -match $titlePattern)
  }

  $matchLevel = "weak"
  $exactUrl = Get-SilmarilPageMemoryExactUrl -Profile $profile
  if (-not [string]::IsNullOrWhiteSpace($exactUrl) -and $exactUrl -eq [string]$Fingerprint.comparableUrl) {
    $matchLevel = "exact"
  }
  elseif (-not [string]::IsNullOrWhiteSpace($pathPattern) -or $requiredMarkers.Count -gt 0) {
    $matchLevel = "strong"
  }

  $isRecommended = ($matchLevel -eq "exact" -or $matchLevel -eq "strong")

  return [ordered]@{
    id            = [string]$Record.id
    recordType    = "stable"
    matchLevel    = $matchLevel
    isRecommended = $isRecommended
    confidence    = [double]$Record.confidence
    summary       = [string]$Record.summary
    titleMatched  = $titleMatched
    selectors     = @($Record.selectors)
    playbooks     = @($Record.playbooks)
    pitfalls      = @($Record.pitfalls)
    state         = $null
  }
}

function Find-SilmarilPageMemoryMatches {
  param(
    [psobject]$Target,
    [hashtable]$Fingerprint,
    [object[]]$Records,
    [int]$TimeoutMs = 10000
  )

  $selectorsToProbe = @()
  foreach ($record in @($Records)) {
    if ([string]$record.recordType -ne "stable") {
      continue
    }

    $selectorsToProbe += @(Get-SilmarilStringArray -Value $record.profile.requiredMarkers)
    $selectorsToProbe += @(Get-SilmarilStringArray -Value $record.profile.excludedMarkers)
  }

  $selectorStates = Get-SilmarilPageMemorySelectorStates -Target $Target -Selectors $selectorsToProbe -TimeoutMs $TimeoutMs

  $matches = @()
  foreach ($record in @($Records)) {
    $match = Get-SilmarilPageMemoryMatch -Record $record -Fingerprint $Fingerprint -SelectorStates $selectorStates
    if ($null -ne $match) {
      $matches += [pscustomobject]$match
    }
  }

  $rank = @{
    exact = 3
    strong = 2
    weak = 1
  }

  return @(
    $matches |
      Sort-Object `
        @{ Expression = { if ($_.isRecommended) { 1 } else { 0 } }; Descending = $true }, `
        @{ Expression = { $rank[[string]$_.matchLevel] }; Descending = $true }, `
        @{ Expression = { [double]$_.confidence }; Descending = $true }, `
        @{ Expression = { [string]$_.id }; Descending = $false }
  )
}

function Verify-SilmarilPageMemoryRecord {
  param(
    [object]$Record,
    [psobject]$Target,
    [hashtable]$Fingerprint,
    [int]$TimeoutMs = 10000
  )

  if ($null -eq $Record) {
    throw "Record is required."
  }

  $selectorsToCheck = @()
  if ([string]$Record.recordType -eq "stable") {
    $selectorsToCheck += @(Get-SilmarilStringArray -Value $Record.profile.requiredMarkers)
    $selectorsToCheck += @(Get-SilmarilStringArray -Value $Record.profile.excludedMarkers)
  }

  $selectorsToCheck += @(Get-SilmarilStringArray -Value $Record.verification.selectors)
  foreach ($selectorRecord in @($Record.selectors)) {
    $selectorsToCheck += [string]$selectorRecord.selector
  }

  $selectorStates = Get-SilmarilPageMemorySelectorStates -Target $Target -Selectors $selectorsToCheck -TimeoutMs $TimeoutMs
  $checks = @()

  if ([string]$Record.recordType -eq "stable") {
    foreach ($marker in @(Get-SilmarilStringArray -Value $Record.profile.requiredMarkers)) {
      $state = Get-SilmarilPageMemorySelectorState -SelectorStates $selectorStates -Selector $marker
      $actual = Get-SilmarilPageMemorySelectorExists -SelectorStates $selectorStates -Selector $marker
      $checks += [ordered]@{
        kind     = "requiredMarker"
        target   = $marker
        expected = $true
        actual   = $actual
        passed   = ($actual -eq $true)
        state    = $state
      }
    }

    foreach ($marker in @(Get-SilmarilStringArray -Value $Record.profile.excludedMarkers)) {
      $state = Get-SilmarilPageMemorySelectorState -SelectorStates $selectorStates -Selector $marker
      $actual = Get-SilmarilPageMemorySelectorExists -SelectorStates $selectorStates -Selector $marker
      $checks += [ordered]@{
        kind     = "excludedMarker"
        target   = $marker
        expected = $false
        actual   = $actual
        passed   = ($actual -eq $false)
        state    = $state
      }
    }

    $profileMatch = Get-SilmarilPageMemoryMatch -Record $Record -Fingerprint $Fingerprint -SelectorStates $selectorStates
    $checks += [ordered]@{
      kind     = "profileMatch"
      target   = "stable-profile"
      expected = $true
      actual   = ($null -ne $profileMatch)
      passed   = ($null -ne $profileMatch)
    }
  }
  else {
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.session.targetId)) {
      $targetPassed = ([string]$Record.session.targetId -eq [string]$Fingerprint.targetId)
      $checks += [ordered]@{
        kind     = "targetId"
        target   = [string]$Record.session.targetId
        expected = $true
        actual   = $targetPassed
        passed   = $targetPassed
      }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Record.session.comparableUrl)) {
      $urlPassed = ([string]$Record.session.comparableUrl -eq [string]$Fingerprint.comparableUrl)
      $checks += [ordered]@{
        kind     = "comparableUrl"
        target   = [string]$Record.session.comparableUrl
        expected = $true
        actual   = $urlPassed
        passed   = $urlPassed
      }
    }
  }

  foreach ($selector in @(Get-SilmarilStringArray -Value $Record.verification.selectors)) {
    $state = Get-SilmarilPageMemorySelectorState -SelectorStates $selectorStates -Selector $selector
    $actual = Get-SilmarilPageMemorySelectorExists -SelectorStates $selectorStates -Selector $selector
    $checks += [ordered]@{
      kind     = "verificationSelector"
      target   = $selector
      expected = $true
      actual   = $actual
      passed   = ($actual -eq $true)
      state    = $state
    }
  }

  foreach ($selectorRecord in @($Record.selectors)) {
    $selector = [string]$selectorRecord.selector
    $state = Get-SilmarilPageMemorySelectorState -SelectorStates $selectorStates -Selector $selector
    $actual = Get-SilmarilPageMemorySelectorExists -SelectorStates $selectorStates -Selector $selector
    $checks += [ordered]@{
      kind     = "selector"
      target   = $selector
      expected = $true
      actual   = $actual
      passed   = ($actual -eq $true)
      state    = $state
    }
  }

  $overallVerified = ($checks.Count -gt 0) -and (-not (@($checks | Where-Object { -not [bool]$_.passed }).Count -gt 0))
  if ($checks.Count -eq 0) {
    $overallVerified = $true
  }

  $updatedConfidence = [double]$Record.confidence
  if ($overallVerified) {
    $updatedConfidence = [Math]::Min(1.0, $updatedConfidence + 0.05)
  }
  else {
    $updatedConfidence = [Math]::Max(0.0, $updatedConfidence - 0.2)
  }

  $recordHash = [ordered]@{}
  foreach ($propertyName in @(Get-SilmarilPropertyNames -InputObject $Record)) {
    $recordHash[$propertyName] = $Record.$propertyName
  }
  $recordHash["confidence"] = $updatedConfidence
  $recordHash["lastVerifiedAt"] = [DateTime]::UtcNow.ToString("o")
  $recordHash["lastVerificationStatus"] = if ($overallVerified) { "verified" } else { "suspect" }

  $path = Save-SilmarilPageMemoryRecord -Record $recordHash

  return [ordered]@{
    id                     = [string]$Record.id
    recordType             = [string]$Record.recordType
    overallVerified        = $overallVerified
    checks                 = @($checks)
    confidence             = [double]$Record.confidence
    updatedConfidence      = $updatedConfidence
    lastVerifiedAt         = [string]$recordHash.lastVerifiedAt
    lastVerificationStatus = [string]$recordHash.lastVerificationStatus
    path                   = $path
  }
}

function Invoke-SilmarilPageMemoryLookup {
  param(
    [string[]]$RemainingArgs
  )

  $common = Parse-SilmarilCommonArgs -Args $RemainingArgs -AllowPort -AllowTargetSelection -AllowTimeout
  $remaining = @($common.RemainingArgs)
  if ($remaining.Count -ne 0) {
    throw "page-memory lookup takes no positional arguments. Supported flags: --port, --target-id, --url-match, --timeout-ms"
  }

  $targetContext = Resolve-SilmarilPageTarget -Port ([int]$common.Port) -TargetId ([string]$common.TargetId) -UrlMatch ([string]$common.UrlMatch) -UrlContains ([string]$common.UrlContains) -TitleMatch ([string]$common.TitleMatch) -TitleContains ([string]$common.TitleContains)
  $fingerprint = Get-SilmarilPageFingerprint -TargetContext $targetContext
  $records = Get-SilmarilPageMemoryRecords -RecordType all
  $matches = Find-SilmarilPageMemoryMatches -Target $targetContext.Target -Fingerprint $fingerprint -Records $records -TimeoutMs ([int]$common.TimeoutMs)

  $data = Add-SilmarilTargetMetadata -Data ([ordered]@{
    port             = [int]$common.Port
    fingerprint      = $fingerprint
    matchCount       = @($matches).Count
    recommendedCount = @($matches | Where-Object { [bool]$_.isRecommended }).Count
    matches          = @($matches)
  }) -TargetContext $targetContext

  Write-SilmarilCommandResult -Command "page-memory.lookup" -Text ("Page memory matches: " + [string]@($matches).Count) -Data $data -Depth 20
}

function Invoke-SilmarilPageMemorySave {
  param(
    [string[]]$RemainingArgs
  )

  $filePath = ""
  $confirm = $false
  $i = 0
  while ($i -lt $RemainingArgs.Count) {
    $arg = [string]$RemainingArgs[$i]
    switch ($arg.ToLowerInvariant()) {
      "--file" {
        if (($i + 1) -ge $RemainingArgs.Count) {
          throw "--file requires a path."
        }
        $filePath = [string]$RemainingArgs[$i + 1]
        $i += 2
        continue
      }
      "--yes" {
        $confirm = $true
        $i += 1
        continue
      }
      default {
        throw 'page-memory save supports only --file "path" --yes'
      }
    }
  }

  if (-not $confirm) {
    throw "page-memory save requires explicit confirmation flag --yes"
  }
  if ([string]::IsNullOrWhiteSpace($filePath)) {
    throw 'page-memory save requires --file "path"'
  }

  $record = Read-SilmarilPageMemoryRecordFile -Path $filePath
  $path = Save-SilmarilPageMemoryRecord -Record $record
  Write-SilmarilCommandResult -Command "page-memory.save" -Text ("Saved page memory: " + [string]$record.id) -Data ([ordered]@{
    id         = [string]$record.id
    recordType = [string]$record.recordType
    summary    = [string]$record.summary
    path       = $path
  }) -Depth 20
}

function Invoke-SilmarilPageMemoryList {
  param(
    [string[]]$RemainingArgs
  )

  $domainFilter = ""
  $includeInvalidated = $false
  $i = 0
  while ($i -lt $RemainingArgs.Count) {
    $arg = [string]$RemainingArgs[$i]
    switch ($arg.ToLowerInvariant()) {
      "--domain" {
        if (($i + 1) -ge $RemainingArgs.Count) {
          throw "--domain requires a value."
        }
        $domainFilter = ([string]$RemainingArgs[$i + 1]).Trim().ToLowerInvariant()
        $i += 2
        continue
      }
      "--include-invalidated" {
        $includeInvalidated = $true
        $i += 1
        continue
      }
      default {
        throw 'page-memory list supports only --domain "domain" and --include-invalidated'
      }
    }
  }

  $records = Get-SilmarilPageMemoryRecords -RecordType all -IncludeInvalidated:([bool]$includeInvalidated)
  if (-not [string]::IsNullOrWhiteSpace($domainFilter)) {
    $records = @($records | Where-Object { (Get-SilmarilPageMemoryRecordDomain -Record $_) -eq $domainFilter })
  }

  $rows = @()
  foreach ($record in @($records)) {
    $rows += [ordered]@{
      id                     = [string]$record.id
      recordType             = [string]$record.recordType
      domain                 = Get-SilmarilPageMemoryRecordDomain -Record $record
      summary                = [string]$record.summary
      confidence             = [double]$record.confidence
      invalidated            = [bool]$record.invalidated
      lastVerifiedAt         = [string]$record.lastVerifiedAt
      lastVerificationStatus = [string]$record.lastVerificationStatus
      updatedAtUtc           = [string]$record.updatedAtUtc
    }
  }

  Write-SilmarilCommandResult -Command "page-memory.list" -Text ("Page memory records: " + [string]@($rows).Count) -Data ([ordered]@{
    count   = @($rows).Count
    records = @($rows)
  }) -Depth 20
}

function Invoke-SilmarilPageMemoryVerify {
  param(
    [string[]]$RemainingArgs
  )

  $id = ""
  $argsForCommon = @()
  $i = 0
  while ($i -lt $RemainingArgs.Count) {
    $arg = [string]$RemainingArgs[$i]
    if ($arg.ToLowerInvariant() -eq "--id") {
      if (($i + 1) -ge $RemainingArgs.Count) {
        throw "--id requires a value."
      }
      $id = [string]$RemainingArgs[$i + 1]
      $i += 2
      continue
    }

    $argsForCommon += $arg
    $i += 1
  }

  if ([string]::IsNullOrWhiteSpace($id)) {
    throw "page-memory verify requires --id <memoryId>"
  }

  $record = Get-SilmarilPageMemoryRecordById -Id $id
  if ($null -eq $record) {
    throw "Page memory record not found: $id"
  }

  $common = Parse-SilmarilCommonArgs -Args $argsForCommon -AllowPort -AllowTargetSelection -AllowTimeout
  if (@($common.RemainingArgs).Count -ne 0) {
    throw "page-memory verify supports only --id, --port, --target-id, --url-match, and --timeout-ms"
  }

  $targetContext = Resolve-SilmarilPageTarget -Port ([int]$common.Port) -TargetId ([string]$common.TargetId) -UrlMatch ([string]$common.UrlMatch) -UrlContains ([string]$common.UrlContains) -TitleMatch ([string]$common.TitleMatch) -TitleContains ([string]$common.TitleContains)
  $fingerprint = Get-SilmarilPageFingerprint -TargetContext $targetContext
  $result = Verify-SilmarilPageMemoryRecord -Record $record -Target $targetContext.Target -Fingerprint $fingerprint -TimeoutMs ([int]$common.TimeoutMs)
  $data = Add-SilmarilTargetMetadata -Data ([ordered]@{
    id                     = $result.id
    recordType             = $result.recordType
    fingerprint            = $fingerprint
    overallVerified        = $result.overallVerified
    checks                 = $result.checks
    confidence             = $result.confidence
    updatedConfidence      = $result.updatedConfidence
    lastVerifiedAt         = $result.lastVerifiedAt
    lastVerificationStatus = $result.lastVerificationStatus
    path                   = $result.path
  }) -TargetContext $targetContext

  Write-SilmarilCommandResult -Command "page-memory.verify" -Text ("Page memory verified: " + [string]$result.id) -Data $data -Depth 20
}

function Invoke-SilmarilPageMemoryInvalidate {
  param(
    [string[]]$RemainingArgs
  )

  $id = ""
  $confirm = $false
  $i = 0
  while ($i -lt $RemainingArgs.Count) {
    $arg = [string]$RemainingArgs[$i]
    switch ($arg.ToLowerInvariant()) {
      "--id" {
        if (($i + 1) -ge $RemainingArgs.Count) {
          throw "--id requires a value."
        }
        $id = [string]$RemainingArgs[$i + 1]
        $i += 2
        continue
      }
      "--yes" {
        $confirm = $true
        $i += 1
        continue
      }
      default {
        throw "page-memory invalidate supports only --id <memoryId> --yes"
      }
    }
  }

  if (-not $confirm) {
    throw "page-memory invalidate requires explicit confirmation flag --yes"
  }
  if ([string]::IsNullOrWhiteSpace($id)) {
    throw "page-memory invalidate requires --id <memoryId>"
  }

  $record = Get-SilmarilPageMemoryRecordById -Id $id
  if ($null -eq $record) {
    throw "Page memory record not found: $id"
  }

  $recordHash = [ordered]@{}
  foreach ($propertyName in @(Get-SilmarilPropertyNames -InputObject $record)) {
    $recordHash[$propertyName] = $record.$propertyName
  }
  $recordHash["invalidated"] = $true
  $recordHash["invalidatedAtUtc"] = [DateTime]::UtcNow.ToString("o")
  $path = Save-SilmarilPageMemoryRecord -Record $recordHash

  Write-SilmarilCommandResult -Command "page-memory.invalidate" -Text ("Page memory invalidated: " + [string]$record.id) -Data ([ordered]@{
    id               = [string]$record.id
    recordType       = [string]$record.recordType
    invalidated      = $true
    invalidatedAtUtc = [string]$recordHash.invalidatedAtUtc
    path             = $path
  }) -Depth 20
}
