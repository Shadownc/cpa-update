<#
.SYNOPSIS
  Download and extract the latest stable CLIProxyAPI Windows amd64 release.

.DESCRIPTION
  - Queries GitHub Releases API for the latest stable (non-prerelease) release.
  - Finds the asset matching *_windows_amd64.zip.
  - Downloads the zip into the current working directory ($PWD).
  - Extracts into a dedicated folder: ./CLIProxyAPI/ (shallow layout).
  - Ensures config.yaml exists, and patches secret-key / api-keys / proxy-url / codex-api-key.

  Notes:
  - This script is intended to be run from the directory where you want the ZIP downloaded.
  - Extraction is kept under ./CLIProxyAPI/ to avoid scattering files.

.PARAMETER Owner
  GitHub repo owner. Default: router-for-me

.PARAMETER Repo
  GitHub repo name. Default: CLIProxyAPI

.PARAMETER AssetPattern
  Asset name wildcard. Default: *_windows_amd64.zip

.PARAMETER InstallRoot
  Root directory for extracted releases. Default: $PWD\CLIProxyAPI

.PARAMETER GitHubToken
  Optional GitHub token. If omitted, uses $env:GITHUB_TOKEN.

.PARAMETER Force
  Redownload/re-extract even if target exists.

.EXAMPLE
  pwsh .\update-cliproxyapi.ps1

.EXAMPLE
  $env:GITHUB_TOKEN = "..."; pwsh .\update-cliproxyapi.ps1 -Verbose

#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [Parameter()] [string] $Owner = 'router-for-me',
  [Parameter()] [string] $Repo = 'CLIProxyAPI',
  [Parameter()] [string] $AssetPattern = '*_windows_amd64.zip',
  [Parameter()] [string] $InstallRoot = (Join-Path (Get-Location) 'CLIProxyAPI'),
  [Parameter()] [string] $GitHubToken,
  [Parameter()] [switch] $Force,

  # Patch config file (read desired values from this YAML-like file)
  [Parameter()] [string] $PatchConfigPath = (Join-Path (Get-Location) 'config.patch.yaml')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info([string] $Message)  { Write-Host $Message }
function Write-Warn([string] $Message)  { Write-Warning $Message }
function Write-Fail([string] $Message)  { throw $Message }

function Use-Tls12 {
  # Windows PowerShell 5.1 may default to older TLS; GitHub requires TLS 1.2+
  try {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
  } catch {
    # If this fails, we'll still attempt the request; error messages will guide user.
    Write-Verbose "Failed to set TLS 1.2: $($_.Exception.Message)"
  }
}

function New-GitHubHeaders {
  param([string] $Token)

  $h = @{
    'User-Agent' = 'cpa-update-script'
    'Accept'     = 'application/vnd.github+json'
  }

  if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = $env:GITHUB_TOKEN
  }

  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $h['Authorization'] = "Bearer $Token"
  }

  return $h
}

function Invoke-GitHubJson {
  param(
    [Parameter(Mandatory = $true)] [string] $Uri,
    [Parameter(Mandatory = $true)] [hashtable] $Headers
  )

  try {
    Write-Verbose "GET $Uri"
    return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
  } catch {
    # Give a helpful message for rate limit
    $msg = $_.Exception.Message
    if ($msg -match '403' -or $msg -match 'rate limit') {
      Write-Warn "GitHub API request failed (possibly rate-limited). Consider setting GITHUB_TOKEN or passing -GitHubToken. Details: $msg"
    }
    throw
  }
}

function Test-SafeZipEntryName {
  param([Parameter(Mandatory = $true)] [string] $EntryName)

  # Reject absolute paths
  if ($EntryName -match '^[A-Za-z]:\\' -or $EntryName -match '^[\\/]+') { return $false }

  # Normalize separators for checks
  $n = $EntryName -replace '\\', '/'

  # Reject parent directory traversal
  if ($n -match '(^|/)\.\.(\/|$)') { return $false }

  return $true
}

function Assert-ZipIsSafe {
  param(
    [Parameter(Mandatory = $true)] [string] $ZipPath
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem

  $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    foreach ($entry in $zip.Entries) {
      if (-not (Test-SafeZipEntryName -EntryName $entry.FullName)) {
        Write-Fail "Unsafe zip entry path detected: '$($entry.FullName)'. Aborting extraction."
      }
    }
  } finally {
    $zip.Dispose()
  }
}

function Ensure-Directory {
  param([Parameter(Mandatory = $true)] [string] $Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Download-File {
  param(
    [Parameter(Mandatory = $true)] [string] $Url,
    [Parameter(Mandatory = $true)] [string] $OutFile,
    [Parameter(Mandatory = $true)] [hashtable] $Headers
  )

  # Invoke-WebRequest follows redirects by default.
  Write-Verbose "Downloading $Url -> $OutFile"
  # GitHub asset download URLs often redirect; allow redirects.
  Invoke-WebRequest -Uri $Url -Headers $Headers -OutFile $OutFile -Method Get -MaximumRedirection 10 -ErrorAction Stop | Out-Null
}

Use-Tls12

$headers = New-GitHubHeaders -Token $GitHubToken
$apiLatest = "https://api.github.com/repos/$Owner/$Repo/releases/latest"

$release = Invoke-GitHubJson -Uri $apiLatest -Headers $headers

if (-not $release) {
  Write-Fail "Failed to fetch release metadata from $apiLatest"
}

$tag = [string]$release.tag_name
if ([string]::IsNullOrWhiteSpace($tag)) {
  Write-Fail "Release metadata missing tag_name"
}

Write-Info "Repo: $Owner/$Repo"
Write-Info "Latest stable tag: $tag"

$assets = @($release.assets)
if (-not $assets -or $assets.Count -eq 0) {
  Write-Fail "Release '$tag' has no assets. Try again later."
}

$matched = @($assets | Where-Object { $_.name -like $AssetPattern })
if ($matched.Count -eq 0) {
  $names = ($assets | ForEach-Object { $_.name }) -join ", "
  Write-Fail "No asset matched pattern '$AssetPattern'. Available assets: $names"
}
if ($matched.Count -gt 1) {
  Write-Warn "Multiple assets matched pattern '$AssetPattern'. Using the most recently updated one."
  $matched = @($matched | Sort-Object -Property updated_at -Descending)
}

$asset = $matched[0]
$assetName = [string]$asset.name
$assetUrl  = [string]$asset.browser_download_url
$assetSize = [int64]$asset.size

if ([string]::IsNullOrWhiteSpace($assetUrl)) {
  Write-Fail "Selected asset '$assetName' missing browser_download_url"
}

$zipPath = Join-Path (Get-Location) $assetName
$partialPath = "$zipPath.partial"

Write-Info "Asset: $assetName ($assetSize bytes)"
Write-Info "Zip path: $zipPath"

$needDownload = $true
if ((Test-Path -LiteralPath $zipPath) -and (-not $Force)) {
  try {
    $len = (Get-Item -LiteralPath $zipPath).Length
    if ($assetSize -gt 0 -and $len -eq $assetSize) {
      Write-Info "Zip already exists with expected size; skipping download."
      $needDownload = $false
    } else {
      Write-Warn "Existing zip size mismatch (have $len, expected $assetSize); will re-download."
    }
  } catch {
    Write-Warn "Unable to stat existing zip; will re-download."
  }
}

if ($needDownload) {
  if ($PSCmdlet.ShouldProcess($zipPath, "Download $assetUrl")) {
    if (Test-Path -LiteralPath $partialPath) {
      Remove-Item -LiteralPath $partialPath -Force
    }

    Download-File -Url $assetUrl -OutFile $partialPath -Headers $headers

    $dlLen = (Get-Item -LiteralPath $partialPath).Length
    if ($assetSize -gt 0 -and $dlLen -ne $assetSize) {
      Remove-Item -LiteralPath $partialPath -Force
      Write-Fail "Downloaded file size mismatch (have $dlLen, expected $assetSize)."
    }

    Move-Item -LiteralPath $partialPath -Destination $zipPath -Force
  }
}

# Prepare install paths
function Get-FullPath {
  param([Parameter(Mandatory = $true)] [string] $Path)

  try {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    return $resolved.Path
  } catch {
    # If path does not exist yet, resolve relative paths against current directory
    if ([System.IO.Path]::IsPathRooted($Path)) {
      return $Path
    }
    return (Join-Path (Get-Location) $Path)
  }
}

function Get-InsertIndexForTopLevelKeys {
  param([Parameter()] [string[]] $Lines)

  $i = 0
  while ($i -lt $Lines.Count) {
    $t = $Lines[$i].Trim()
    if ($t -eq '' -or $t.StartsWith('#') -or $t -eq '---') {
      $i++
      continue
    }
    break
  }
  return $i
}

function Get-TopLevelBlockRange {
  param(
    [Parameter()] [string[]] $Lines,
    [Parameter(Mandatory = $true)] [string] $KeyName
  )

  $start = -1
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    $line = $Lines[$i]

    # Only match true top-level keys (no indentation). Also tolerate a UTF-8 BOM on the first line.
    if ($line -match "^(?:\uFEFF)?$([regex]::Escape($KeyName))\s*:\s*(#.*)?$") {
      $start = $i
      break
    }
  }
  if ($start -lt 0) { return $null }

  $end = $Lines.Count
  for ($j = $start + 1; $j -lt $Lines.Count; $j++) {
    $l = $Lines[$j]

    # Next top-level key (non-indented, not comment)
    if ($l -match '^(?:\uFEFF)?[^#\s][^:]*:\s*') {
      $end = $j
      break
    }
  }

  return @{ Start = $start; End = $end }
}

function Get-ScalarTopLevelValue {
  param(
    [Parameter()] [string[]] $Lines,
    [Parameter(Mandatory = $true)] [string] $KeyName
  )

  foreach ($line in $Lines) {
    # Only match true top-level scalar keys (no indentation)
    if ($line -match "^(?:\uFEFF)?$([regex]::Escape($KeyName))\s*:\s*(.*?)\s*(#.*)?$") {
      return $Matches[1]
    }
  }
  return $null
}

function Get-ApiKeysFromConfig {
  param([Parameter()] [string[]] $Lines)

  $range = Get-TopLevelBlockRange -Lines $Lines -KeyName 'api-keys'
  if (-not $range) { return @() }

  $keys = New-Object System.Collections.Generic.List[string]
  for ($i = $range.Start + 1; $i -lt $range.End; $i++) {
    $line = $Lines[$i]
    if ($line -match '^\s*-\s*(.*?)\s*(#.*)?$') {
      $v = $Matches[1]
      if (-not [string]::IsNullOrWhiteSpace($v)) {
        $keys.Add($v)
      }
    }
  }

  return $keys.ToArray()
}

function Upsert-ScalarTopLevelKey {
  param(
    [Parameter()] [string[]] $Lines,
    [Parameter(Mandatory = $true)] [string] $KeyName,
    [Parameter(Mandatory = $true)] [string] $Value
  )

  for ($i = 0; $i -lt $Lines.Count; $i++) {
    # Only match true top-level scalar keys (no indentation)
    if ($Lines[$i] -match "^(?:\uFEFF)?$([regex]::Escape($KeyName))\s*:\s*(.*?)\s*(#.*)?$") {
      # Keep existing value; do not overwrite
      return $Lines
    }
  }

  $idx = Get-InsertIndexForTopLevelKeys -Lines $Lines
  $newLines = @()
  if ($idx -gt 0) { $newLines += $Lines[0..($idx-1)] }
  $newLines += "${KeyName}: $Value"
  if ($idx -lt $Lines.Count) { $newLines += $Lines[$idx..($Lines.Count-1)] }
  return $newLines
}

function Set-ScalarTopLevelKey {
  param(
    [Parameter()] [string[]] $Lines,
    [Parameter(Mandatory = $true)] [string] $KeyName,
    [Parameter(Mandatory = $true)] [string] $Value
  )

  for ($i = 0; $i -lt $Lines.Count; $i++) {
    # Only match true top-level scalar keys (no indentation)
    if ($Lines[$i] -match "^(?:\uFEFF)?$([regex]::Escape($KeyName))\s*:\s*(.*?)\s*(#.*)?$") {
      $comment = $Matches[2]
      if ([string]::IsNullOrWhiteSpace($comment)) {
        $Lines[$i] = "${KeyName}: $Value"
      } else {
        $Lines[$i] = "${KeyName}: $Value$comment"
      }
      return $Lines
    }
  }

  # Key not found: insert like Upsert
  $idx = Get-InsertIndexForTopLevelKeys -Lines $Lines
  $newLines = @()
  if ($idx -gt 0) { $newLines += $Lines[0..($idx-1)] }
  $newLines += "${KeyName}: $Value"
  if ($idx -lt $Lines.Count) { $newLines += $Lines[$idx..($Lines.Count-1)] }
  return $newLines
}

function Upsert-ApiKeys {
  param(
    [Parameter()] [string[]] $Lines,
    [Parameter(Mandatory = $true)] [string[]] $EnsureKeys
  )

  $existing = @(Get-ApiKeysFromConfig -Lines $Lines)
  $merged = New-Object System.Collections.Generic.List[string]

  foreach ($k in $existing) {
    if (-not $merged.Contains($k)) { $merged.Add($k) }
  }
  foreach ($k in $EnsureKeys) {
    if (-not $merged.Contains($k)) { $merged.Add($k) }
  }

  $block = @('api-keys:')
  foreach ($k in $merged) {
    $block += "  - $k"
  }

  $range = Get-TopLevelBlockRange -Lines $Lines -KeyName 'api-keys'
  if ($range) {
    $newLines = @()
    if ($range.Start -gt 0) { $newLines += $Lines[0..($range.Start-1)] }
    $newLines += $block
    if ($range.End -lt $Lines.Count) { $newLines += $Lines[$range.End..($Lines.Count-1)] }
    return $newLines
  }

  $idx = Get-InsertIndexForTopLevelKeys -Lines $Lines
  $newLines = @()
  if ($idx -gt 0) { $newLines += $Lines[0..($idx-1)] }
  $newLines += $block
  if ($idx -lt $Lines.Count) { $newLines += $Lines[$idx..($Lines.Count-1)] }
  return $newLines
}

function Replace-CodexApiKeyBlock {
  param(
    [Parameter()] [string[]] $Lines,
    [Parameter(Mandatory = $true)] [string[]] $CodexBlockLines
  )

  $range = Get-TopLevelBlockRange -Lines $Lines -KeyName 'codex-api-key'
  if ($range) {
    $newLines = @()
    if ($range.Start -gt 0) { $newLines += $Lines[0..($range.Start-1)] }
    $newLines += $CodexBlockLines
    if ($range.End -lt $Lines.Count) { $newLines += $Lines[$range.End..($Lines.Count-1)] }
    return $newLines
  }

  # Append at end
  $newLines = @($Lines)
  if ($newLines.Count -gt 0 -and $newLines[-1].Trim() -ne '') {
    $newLines += ''
  }
  $newLines += $CodexBlockLines
  return $newLines
}

function Parse-PatchConfig {
  param([Parameter(Mandatory = $true)] [string] $Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $raw = $raw -replace "\r?\n$", ''
  $lines = @($raw -split "\r?\n")

  $out = [ordered]@{
    SecretKey = $null
    ApiKeys   = @()

    # Top-level proxy-url (NOT the ones inside codex-api-key-block)
    # Use $null for "not provided"; empty string "" is allowed (to clear the value).
    ProxyUrl  = $null

    CodexBlock = $null
  }

  $baseIndent = $null
  $codexSource = $null

  $i = 0
  while ($i -lt $lines.Count) {
    $line = $lines[$i]

    # Be robust to odd whitespace/encodings: strip BOM on the line start, then ignore indentation.
    $trimStart = $line.TrimStart().TrimStart([char]0xFEFF)

    if ($trimStart -eq '' -or $trimStart.StartsWith('#') -or $trimStart -eq '---') { $i++; continue }

    $headerIndent = $line.Length - $line.TrimStart().Length
    if ($null -eq $baseIndent) { $baseIndent = $headerIndent }

    if ($trimStart -match '^secret-key\s*:\s*(.*?)\s*(#.*)?$') {
      $v = $Matches[1].Trim()
      # Strip quotes (both single and double) if present
      if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
        $v = $v.Substring(1, $v.Length - 2)
      } else {
        $v = $v.Trim('"').Trim("'")
      }

      if (-not [string]::IsNullOrWhiteSpace($v)) {
        Write-Verbose "Parsed patch: secret-key"
        $out.SecretKey = $v
      }
      $i++
      continue
    }

    if ($trimStart -match '^api-keys\s*:\s*(#.*)?$') {
      if ($headerIndent -ne $baseIndent) { $i++; continue }

      $keys = New-Object System.Collections.Generic.List[string]
      $i++
      while ($i -lt $lines.Count) {
        $l2 = $lines[$i]
        $t2 = $l2.TrimStart().TrimStart([char]0xFEFF)

        if ($t2 -eq '' -or $t2.StartsWith('#')) { $i++; continue }

        $indent2 = $l2.Length - $l2.TrimStart().Length
        if ($indent2 -le $headerIndent) { break }

        if ($t2 -match '^-\s*(.*?)\s*(#.*)?$') {
          $k = $Matches[1].Trim()
          if ($k.Length -ge 2 -and (($k.StartsWith('"') -and $k.EndsWith('"')) -or ($k.StartsWith("'") -and $k.EndsWith("'")))) {
            $k = $k.Substring(1, $k.Length - 2)
          } else {
            $k = $k.Trim('"').Trim("'")
          }
          if (-not [string]::IsNullOrWhiteSpace($k)) { $keys.Add($k) }
        }
        $i++
      }
      $out.ApiKeys = $keys.ToArray()
      continue
    }

    if ($trimStart -match '^proxy-url\s*:\s*(.*?)\s*(#.*)?$') {
      if ($headerIndent -ne $baseIndent) { $i++; continue }

      $v = $Matches[1].Trim()
      # Strip quotes (both single and double) if present
      if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
        $v = $v.Substring(1, $v.Length - 2)
      } else {
        $v = $v.Trim('"').Trim("'")
      }

      # Allow empty string to mean "clear proxy-url"; $null means "not provided".
      Write-Verbose "Parsed patch: proxy-url"
      $out.ProxyUrl = $v
      $i++
      continue
    }

    if ($trimStart -match '^codex-api-key-block\s*:\s*\|[\+\-]?\s*(#.*)?$') {
      if ($headerIndent -ne $baseIndent) { $i++; continue }

      $codexSource = 'codex-api-key-block'

      $blockLines = New-Object System.Collections.Generic.List[string]
      $i++
      while ($i -lt $lines.Count) {
        $l2 = $lines[$i]
        $t2 = $l2.TrimStart().TrimStart([char]0xFEFF)

        # YAML literal blocks end when indentation returns to (or below) the header indentation.
        if ($t2 -ne '' -and -not $t2.StartsWith('#')) {
          $indent2 = $l2.Length - $l2.TrimStart().Length
          if ($indent2 -le $headerIndent) { break }
        }

        $blockLines.Add($l2)
        $i++
      }

      # Normalize block indentation: strip the minimum indent of non-blank lines.
      $minIndent = $null
      foreach ($bl in $blockLines) {
        if ([string]::IsNullOrWhiteSpace($bl)) { continue }
        $ind = $bl.Length - $bl.TrimStart().Length
        if ($null -eq $minIndent -or $ind -lt $minIndent) { $minIndent = $ind }
      }
      if ($null -eq $minIndent) { $minIndent = 0 }

      $normalized = @()
      foreach ($bl in $blockLines) {
        if ($bl.Length -ge $minIndent) { $normalized += $bl.Substring($minIndent) } else { $normalized += $bl }
      }

      $out.CodexBlock = ($normalized -join "`n").TrimEnd()
      continue
    }

    # Compatibility: allow users to provide codex-api-key directly (instead of codex-api-key-block)
    if ($trimStart -match '^codex-api-key\s*:\s*(#.*)?$') {
      if ($headerIndent -ne $baseIndent) { $i++; continue }

      $codexSource = 'codex-api-key'

      $blockLines = New-Object System.Collections.Generic.List[string]
      $blockLines.Add('codex-api-key:')
      $i++
      while ($i -lt $lines.Count) {
        $l2 = $lines[$i]
        $t2 = $l2.TrimStart().TrimStart([char]0xFEFF)

        if ($t2 -ne '' -and -not $t2.StartsWith('#')) {
          $indent2 = $l2.Length - $l2.TrimStart().Length
          if ($indent2 -le $headerIndent) { break }
        }

        $blockLines.Add($l2)
        $i++
      }

      # Normalize indentation: strip the indentation of the codex-api-key header line.
      # This keeps list items properly indented under codex-api-key when we paste into config.yaml.
      $normalized = @('codex-api-key:')
      for ($k = 1; $k -lt $blockLines.Count; $k++) {
        $bl = $blockLines[$k]
        if ($bl.Length -ge $headerIndent) { $normalized += $bl.Substring($headerIndent) } else { $normalized += $bl }
      }

      $out.CodexBlock = ($normalized -join "`n").TrimEnd()
      continue
    }

    $i++
  }

  return $out
}

function Update-RemoteManagementSecretKey {
  param(
    [Parameter(Mandatory = $true)] [string] $ConfigPath,
    [Parameter()] [string] $SecretKey
  )

  if ([string]::IsNullOrWhiteSpace($SecretKey)) {
    return
  }

  $raw = Get-Content -LiteralPath $ConfigPath -Raw
  $raw = $raw -replace "\r?\n$", ''
  $lines = if ([string]::IsNullOrWhiteSpace($raw)) { @() } else { @($raw -split "\r?\n") }

  # Find remote-management block
  $rmRange = Get-TopLevelBlockRange -Lines $lines -KeyName 'remote-management'
  if (-not $rmRange) {
    # No remote-management block; do nothing
    return
  }

  $secretLineIdx = -1
  for ($i = $rmRange.Start + 1; $i -lt $rmRange.End; $i++) {
    $line = $lines[$i]
    # Expect 2-space indent
    if ($line -match '^(?!\s*#)\s{2}secret-key\s*:\s*(.*?)\s*(#.*)?$') {
      $secretLineIdx = $i
      break
    }
  }

  if ($secretLineIdx -ge 0) {
    # Only set if empty
    if ($lines[$secretLineIdx] -match '^(?!\s*#)\s{2}secret-key\s*:\s*""\s*(#.*)?$' -or $lines[$secretLineIdx] -match '^(?!\s*#)\s{2}secret-key\s*:\s*$') {
      Write-Verbose "Setting remote-management.secret-key from patch config"
      $lines[$secretLineIdx] = "  secret-key: `"$SecretKey`""
      Set-Content -LiteralPath $ConfigPath -Value ($lines -join "`r`n") -Encoding UTF8
    } else {
      Write-Verbose "remote-management.secret-key already set; leaving unchanged"
    }
    return
  }

  # If secret-key line missing, insert it just after remote-management: line
  $insertAt = $rmRange.Start + 1
  $newLines = @()
  if ($insertAt -gt 0) { $newLines += $lines[0..($insertAt-1)] }
  $newLines += "  secret-key: `"$SecretKey`""
  if ($insertAt -lt $lines.Count) { $newLines += $lines[$insertAt..($lines.Count-1)] }

  Set-Content -LiteralPath $ConfigPath -Value ($newLines -join "`r`n") -Encoding UTF8
}

function Update-ConfigYaml {
  param(
    [Parameter(Mandatory = $true)] [string] $ConfigPath,
    [Parameter()] [string] $DefaultSecretKey,
    [Parameter()] [string] $ProxyUrl,
    [Parameter()] [string[]] $EnsureApiKeys,
    [Parameter()] [string[]] $CodexBlockLines
  )

  $raw = Get-Content -LiteralPath $ConfigPath -Raw
  $raw = $raw -replace "\r?\n$", ''

  if ([string]::IsNullOrWhiteSpace($raw)) {
    $lines = @()
  } else {
    $lines = @($raw -split "\r?\n")
    if ($lines.Count -eq 1 -and [string]::IsNullOrWhiteSpace($lines[0])) {
      $lines = @()
    }
  }

  # Normalize to string[] (avoid passing an empty string scalar to -Lines)
  if ($null -eq $lines) {
    $lines = @()
  } elseif ($lines -is [string]) {
    if ([string]::IsNullOrWhiteSpace($lines)) {
      $lines = @()
    } else {
      $lines = @($lines)
    }
  }

  # Ensure we always keep $lines as a string[] (avoid scalar string when only 1 line exists)
  $lines = @($lines)

  # secret-key: insert default only if missing (only when patch provides a value)
  if (-not [string]::IsNullOrWhiteSpace($DefaultSecretKey)) {
    $lines = @(Upsert-ScalarTopLevelKey -Lines $lines -KeyName 'secret-key' -Value $DefaultSecretKey)
  }

  # proxy-url: set ONLY when patch provides proxy-url (allow empty string to clear)
  if ($null -ne $ProxyUrl) {
    $escaped = $ProxyUrl.Replace('"','\"')
    $lines = @(Set-ScalarTopLevelKey -Lines $lines -KeyName 'proxy-url' -Value "`"$escaped`"")
  }

  # api-keys: merge with existing if patch provided
  if ($EnsureApiKeys -and $EnsureApiKeys.Count -gt 0) {
    Write-Verbose ("Ensuring api-keys include {0} entries" -f $EnsureApiKeys.Count)
    $lines = @(Upsert-ApiKeys -Lines $lines -EnsureKeys $EnsureApiKeys)
  }

  # codex-api-key: replace only if patch provided
  if ($CodexBlockLines -and $CodexBlockLines.Count -gt 0) {
    Write-Verbose "Replacing/adding codex-api-key block from patch config"
    $lines = @(Replace-CodexApiKeyBlock -Lines $lines -CodexBlockLines $CodexBlockLines)
  }

  Set-Content -LiteralPath $ConfigPath -Value ($lines -join "`r`n") -Encoding UTF8
}

function Patch-ConfigYamlFromPatchFile {
  param(
    [Parameter(Mandatory = $true)] [string] $ConfigPath,
    [Parameter(Mandatory = $true)] [string] $PatchPath
  )

  if (-not (Test-Path -LiteralPath $PatchPath)) {
    Write-Warn "Patch config not found: $PatchPath"
    return $false
  }

  $patch = Parse-PatchConfig -Path $PatchPath
  if (-not $patch) {
    Write-Warn "Patch config is empty or unreadable: $PatchPath"
    return $false
  }

  $codexLines = @()
  if (-not [string]::IsNullOrWhiteSpace($patch.CodexBlock)) {
    $codexLines = @($patch.CodexBlock -split "`n")
  }

  # 1) secret-key from patch -> remote-management.secret-key (only if empty)
  Update-RemoteManagementSecretKey -ConfigPath $ConfigPath -SecretKey $patch.SecretKey

  # 2) Apply top-level fields while preserving existing comments in config.yaml
  #    - proxy-url must be updated in-place (do not move/remove the surrounding comment block from config.example.yaml)
  Update-ConfigYaml -ConfigPath $ConfigPath -DefaultSecretKey $null -ProxyUrl $patch.ProxyUrl -EnsureApiKeys $patch.ApiKeys -CodexBlockLines $codexLines

  return $true
}

function Deploy-PayloadToInstallRoot {
  param(
    [Parameter(Mandatory = $true)] [string] $PayloadRoot,
    [Parameter(Mandatory = $true)] [string] $InstallRoot,
    [Parameter(Mandatory = $true)] [switch] $Force,
    [Parameter(Mandatory = $true)] $PSCmdlet
  )

  Ensure-Directory -Path $InstallRoot

  $items = Get-ChildItem -LiteralPath $PayloadRoot -Force
  foreach ($item in $items) {
    $dest = Join-Path $InstallRoot $item.Name

    if (-not $item.PSIsContainer) {
      if ($item.Name -ieq 'config.yaml' -and (Test-Path -LiteralPath $dest) -and (-not $Force)) {
        Write-Verbose "Skipping existing config.yaml"
        continue
      }
    }

    if ($PSCmdlet.ShouldProcess($dest, "Copy from $($item.FullName)")) {
      if ($item.PSIsContainer) {
        Copy-Item -LiteralPath $item.FullName -Destination $dest -Recurse -Force
      } else {
        Copy-Item -LiteralPath $item.FullName -Destination $dest -Force
      }
    }
  }
}

$installRootFull = Get-FullPath -Path $InstallRoot

$stagingRoot = Join-Path $installRootFull '.staging'
$stagingDir  = Join-Path $stagingRoot ([guid]::NewGuid().ToString('N'))

Write-Info "Install root: $installRootFull"

if ($PSCmdlet.ShouldProcess($installRootFull, "Extract $zipPath")) {
  Ensure-Directory -Path $installRootFull
  Ensure-Directory -Path $stagingRoot

  if (Test-Path -LiteralPath $stagingDir) {
    Remove-Item -LiteralPath $stagingDir -Recurse -Force
  }
  Ensure-Directory -Path $stagingDir

  Assert-ZipIsSafe -ZipPath $zipPath

  # Extract to staging
  Expand-Archive -LiteralPath $zipPath -DestinationPath $stagingDir -Force

  # If staging contains exactly one top-level directory, use it as payload root (flattens one level)
  $children = @(Get-ChildItem -LiteralPath $stagingDir -Force)
  $dirs  = @($children | Where-Object { $_.PSIsContainer })
  $files = @($children | Where-Object { -not $_.PSIsContainer })

  $payloadRoot = $stagingDir
  if ($dirs.Count -eq 1 -and $files.Count -eq 0) {
    $payloadRoot = $dirs[0].FullName
  }

  Deploy-PayloadToInstallRoot -PayloadRoot $payloadRoot -InstallRoot $installRootFull -Force:$Force -PSCmdlet $PSCmdlet

  # Cleanup staging
  Remove-Item -LiteralPath $stagingDir -Recurse -Force
}

# Ensure config.yaml exists (in install root)
$configExample = Join-Path $installRootFull 'config.example.yaml'
$configPath    = Join-Path $installRootFull 'config.yaml'

if (-not (Test-Path -LiteralPath $PatchConfigPath)) {
  Write-Warn "Patch config not found: $PatchConfigPath. No config values will be injected (except creating config.yaml from example if needed)."
} else {
  Write-Verbose "Using patch config: $PatchConfigPath"
}

if (-not (Test-Path -LiteralPath $configPath)) {
  if (Test-Path -LiteralPath $configExample) {
    if ($PSCmdlet.ShouldProcess($configPath, "Create config.yaml from config.example.yaml")) {
      Copy-Item -LiteralPath $configExample -Destination $configPath
      Write-Info "Created config.yaml from config.example.yaml."
    }
  } else {
    Write-Warn "config.example.yaml not found; cannot create config.yaml automatically."
  }
} else {
  Write-Info "config.yaml already exists; will patch required fields in-place (based on patch config)."
}

# Patch config.yaml fields (based on patch config)
if (Test-Path -LiteralPath $configPath) {
  if ($PSCmdlet.ShouldProcess($configPath, 'Patch config.yaml')) {
    $patched = Patch-ConfigYamlFromPatchFile -ConfigPath $configPath -PatchPath $PatchConfigPath
    if ($patched) {
      Write-Info "Patched config.yaml."
    } else {
      Write-Warn "Skipped patching config.yaml."
    }
  }
}

Write-Info "Done. Installed files are under: $installRootFull"
