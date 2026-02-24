Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SilmarilPropertyNames {
  param(
    [object]$InputObject
  )

  if ($null -eq $InputObject) {
    return @()
  }

  $names = @()
  foreach ($prop in $InputObject.PSObject.Properties) {
    if ($null -ne $prop -and -not [string]::IsNullOrWhiteSpace($prop.Name)) {
      $names += $prop.Name
    }
  }

  return $names
}

function Get-SilmarilBrowserPath {
  $roots = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:LOCALAPPDATA
  ) | Where-Object { $_ }

  $relativePaths = @(
    "Google\Chrome\Application\chrome.exe",
    "Chromium\Application\chrome.exe",
    "Microsoft\Edge\Application\msedge.exe"
  )

  foreach ($root in $roots) {
    foreach ($relative in $relativePaths) {
      $candidate = Join-Path -Path $root -ChildPath $relative
      if (Test-Path -Path $candidate) {
        return $candidate
      }
    }
  }

  return $null
}

function Get-SilmarilUserDataDir {
  return (Join-Path -Path $env:LOCALAPPDATA -ChildPath "Silmaril\chrome-cdp-profile")
}

function Get-SilmarilCdpTargets {
  param(
    [int]$Port = 9222
  )

  $targetsEndpoint = "http://127.0.0.1:$Port/json/list"
  try {
    $targets = Invoke-RestMethod -Method Get -Uri $targetsEndpoint -TimeoutSec 5
  }
  catch {
    throw "Unable to query CDP on port $Port. Start browser first: silmaril.cmd openbrowser"
  }

  if (-not $targets) {
    throw "No CDP targets found on port $Port."
  }

  return @($targets)
}

function Test-SilmarilCdpReady {
  param(
    [int]$Port = 9222
  )

  try {
    Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 1 | Out-Null
    return $true
  }
  catch {
    return $false
  }
}

function Normalize-SilmarilUrl {
  param(
    [string]$InputUrl
  )

  if ([string]::IsNullOrWhiteSpace($InputUrl)) {
    throw "openUrl requires a URL argument."
  }

  if ($InputUrl.StartsWith("//")) {
    return "https:$InputUrl"
  }

  return $InputUrl
}

function Test-SilmarilDefaultTabUrl {
  param(
    [string]$Url
  )

  if ([string]::IsNullOrWhiteSpace($Url)) {
    return $true
  }

  $normalized = $Url.ToLowerInvariant()
  return (
    $normalized -eq "about:blank" -or
    $normalized -eq "chrome://newtab/" -or
    $normalized -eq "edge://newtab/" -or
    $normalized.StartsWith("chrome-search://")
  )
}

function Get-SilmarilPageTargets {
  param(
    [int]$Port = 9222
  )

  $targets = Get-SilmarilCdpTargets -Port $Port
  $pages = @($targets | Where-Object { $_.type -eq "page" })
  if ($pages.Count -eq 0) {
    throw "No page targets found on port $Port."
  }

  return $pages
}

function Get-SilmarilPreferredPageTarget {
  param(
    [int]$Port = 9222
  )

  $pages = Get-SilmarilPageTargets -Port $Port
  $preferred = @($pages | Where-Object { -not (Test-SilmarilDefaultTabUrl -Url $_.url) })
  if ($preferred.Count -gt 0) {
    return $preferred[0]
  }

  return $pages[0]
}

function Invoke-SilmarilCdpCommand {
  param(
    [psobject]$Target,
    [string]$Method,
    [hashtable]$Params = @{},
    [int]$TimeoutSec = 10
  )

  if (-not $Target) {
    throw "Target is required for CDP command '$Method'."
  }

  if (-not $Target.webSocketDebuggerUrl) {
    throw "Target does not include webSocketDebuggerUrl."
  }

  $socket = [System.Net.WebSockets.ClientWebSocket]::new()
  $requestId = Get-Random -Minimum 100000 -Maximum 999999
  $payload = @{
    id     = $requestId
    method = $Method
    params = $Params
  } | ConvertTo-Json -Compress -Depth 20

  try {
    $uri = [System.Uri]$Target.webSocketDebuggerUrl
    $token = [System.Threading.CancellationToken]::None
    $socket.ConnectAsync($uri, $token).GetAwaiter().GetResult()

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sendSegment = [ArraySegment[byte]]::new($bytes)
    $socket.SendAsync($sendSegment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $token).GetAwaiter().GetResult()

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
      $buffer = New-Object byte[] 65536
      $messageStream = New-Object System.IO.MemoryStream
      do {
        $readSegment = [ArraySegment[byte]]::new($buffer)
        $receiveResult = $socket.ReceiveAsync($readSegment, $token).GetAwaiter().GetResult()

        if ($receiveResult.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
          throw "CDP WebSocket closed before response for '$Method'."
        }

        if ($receiveResult.Count -gt 0) {
          $messageStream.Write($buffer, 0, $receiveResult.Count)
        }
      } while (-not $receiveResult.EndOfMessage)

      $rawMessage = [System.Text.Encoding]::UTF8.GetString($messageStream.ToArray())
      $messageStream.Dispose()

      if ([string]::IsNullOrWhiteSpace($rawMessage)) {
        continue
      }

      $parsed = $null
      try {
        $parsed = $rawMessage | ConvertFrom-Json
      }
      catch {
        continue
      }

      $messages = @($parsed)
      $matchedById = $null
      foreach ($message in $messages) {
        if (-not $message) {
          continue
        }

        $propertyNames = @(Get-SilmarilPropertyNames -InputObject $message)
        if (($propertyNames -contains "id") -and $message.id -eq $requestId) {
          $matchedById = $message
          break
        }
      }

      if (-not $matchedById) {
        continue
      }

      $selectedProps = @(Get-SilmarilPropertyNames -InputObject $matchedById)
      if (($selectedProps -contains "error") -and $null -ne $matchedById.error) {
        throw "CDP $Method failed: $($matchedById.error.message)"
      }

      if (-not ($selectedProps -contains "result")) {
        throw "CDP $Method returned no result payload."
      }

      return $matchedById.result
    }

    throw "Timed out waiting for CDP response to '$Method'."
  }
  finally {
    try {
      if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $socket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
      }
    }
    catch {
      # Ignore close failures.
    }
    $socket.Dispose()
  }
}
