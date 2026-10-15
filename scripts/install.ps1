[CmdletBinding()]
param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$AgentsHome = (Join-Path $env:USERPROFILE '.agents'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$agentSource = Join-Path $projectRoot 'agents'
$skillSource = Join-Path $projectRoot 'skills\cheap-verified-development'
$codexAgents = Join-Path $CodexHome 'agents'
$skillTarget = Join-Path $AgentsHome 'skills\cheap-verified-development'
$configPath = Join-Path $CodexHome 'config.toml'
$stateRoot = Join-Path $AgentsHome '.cheap-verified-development'
$statePath = Join-Path $stateRoot 'install-state.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TomlVisiblePrefix([string]$Line, [ref]$MultilineState) {
    if ($MultilineState.Value) {
        if ($MultilineState.Value -eq 'literal') {
            if ($Line.Contains("'''")) { $MultilineState.Value = $null }
        } else {
            for ($j = 0; $j -le $Line.Length - 3; $j++) {
                if ($Line.Substring($j, 3) -ne '"""') { continue }
                $slashes = 0
                for ($k = $j - 1; $k -ge 0 -and $Line[$k] -eq '\'; $k--) { $slashes++ }
                if (($slashes % 2) -eq 0) { $MultilineState.Value = $null; break }
            }
        }
        # Ignore the whole physical line when it starts inside a multiline value.
        return $null
    }

    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($ch -eq '#') { return $Line.Substring(0, $i) }
        if ($ch -ne '"' -and $ch -ne "'") { continue }

        $isBasic = $ch -eq '"'
        $isTriple = ($i + 2 -lt $Line.Length -and $Line.Substring($i, 3) -eq $(if ($isBasic) { '"""' } else { "'''" }))
        if ($isTriple) {
            $delimiter = if ($isBasic) { '"""' } else { "'''" }
            $closing = -1
            for ($j = $i + 3; $j -le $Line.Length - 3; $j++) {
                if ($Line.Substring($j, 3) -ne $delimiter) { continue }
                if (-not $isBasic) { $closing = $j; break }
                $slashes = 0
                for ($k = $j - 1; $k -ge 0 -and $Line[$k] -eq '\'; $k--) { $slashes++ }
                if (($slashes % 2) -eq 0) { $closing = $j; break }
            }
            if ($closing -lt 0) { $MultilineState.Value = $(if ($isBasic) { 'basic' } else { 'literal' }) }
            # The remainder is part of the multiline value or its closing line.
            return $Line.Substring(0, $i)
        }

        # Skip a single-line basic or literal string, including escaped quotes in basic strings.
        $i++
        $closed = $false
        while ($i -lt $Line.Length) {
            if ($isBasic -and $Line[$i] -eq '\') { $i += 2; continue }
            if ($Line[$i] -eq $ch) { $closed = $true; break }
            $i++
        }
        if (-not $closed) { throw 'Unterminated TOML string; refusing to edit config.toml.' }
    }
    return $Line
}

function ConvertFrom-TomlBasicKey([string]$Encoded) {
    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Encoded.Length; $i++) {
        if ($Encoded[$i] -ne '\') { [void]$builder.Append($Encoded[$i]); continue }
        $i++
        if ($i -ge $Encoded.Length) { throw 'Malformed escape in quoted TOML key.' }
        switch -CaseSensitive ($Encoded[$i]) {
            '"' { [void]$builder.Append('"') }
            '\' { [void]$builder.Append('\') }
            'b' { [void]$builder.Append([char]8) }
            't' { [void]$builder.Append([char]9) }
            'n' { [void]$builder.Append([char]10) }
            'f' { [void]$builder.Append([char]12) }
            'r' { [void]$builder.Append([char]13) }
            'u' {
                if ($i + 4 -ge $Encoded.Length) { throw 'Malformed Unicode escape in quoted TOML key.' }
                $hex = $Encoded.Substring($i + 1, 4)
                if ($hex -notmatch '^[0-9A-Fa-f]{4}$') { throw 'Malformed Unicode escape in quoted TOML key.' }
                [void]$builder.Append([char][Convert]::ToInt32($hex, 16)); $i += 4
            }
            'U' {
                if ($i + 8 -ge $Encoded.Length) { throw 'Malformed Unicode escape in quoted TOML key.' }
                $hex = $Encoded.Substring($i + 1, 8)
                if ($hex -notmatch '^[0-9A-Fa-f]{8}$') { throw 'Malformed Unicode escape in quoted TOML key.' }
                $scalar = [Convert]::ToInt64($hex, 16)
                if ($scalar -gt 0x10FFFF -or ($scalar -ge 0xD800 -and $scalar -le 0xDFFF)) { throw 'Invalid Unicode scalar in quoted TOML key.' }
                [void]$builder.Append([char]::ConvertFromUtf32([int]$scalar)); $i += 8
            }
            default { throw 'Unsupported escape in quoted TOML key; refusing to edit config.toml.' }
        }
    }
    return $builder.ToString()
}

function Get-TomlKeyValue([string]$Token) {
    $token = $Token.Trim()
    if ($token.Length -ge 2 -and $token[0] -eq '"' -and $token[$token.Length - 1] -eq '"') {
        return ConvertFrom-TomlBasicKey $token.Substring(1, $token.Length - 2)
    }
    if ($token.Length -ge 2 -and $token[0] -eq "'" -and $token[$token.Length - 1] -eq "'") {
        return $token.Substring(1, $token.Length - 2)
    }
    if ($token -cmatch '^[A-Za-z0-9_-]+$') { return $token }
    return $null
}

function Test-MultiAgentConfig([string]$Content) {
    $lines = $Content -split "`r?`n", 0, 'RegexMatch'
    $inFeatures = $false
    $featureSections = 0
    $foundKeys = 0
    $value = $null
    $multilineState = $null
    $assignmentPattern = '^\s*(?<key>"(?:\\.|[^"\\])*"|''[^'']*''|[A-Za-z0-9_-]+)\s*='
    foreach ($rawLine in $lines) {
        $line = Get-TomlVisiblePrefix $rawLine ([ref]$multilineState)
        if ($null -eq $line) { continue }
        $arrayHeader = [regex]::Match($line, '^\s*\[\[(.*)\]\]\s*(?:#.*)?$')
        if ($arrayHeader.Success) {
            $arrayKey = Get-TomlKeyValue $arrayHeader.Groups[1].Value
            if ($arrayKey -ceq 'features') { throw "Ambiguous features array table declaration: $line" }
            $inFeatures = $false
            continue
        }
        $tableHeader = [regex]::Match($line, '^\s*\[(.*)\]\s*(?:#.*)?$')
        if ($tableHeader.Success) {
            $tableText = $tableHeader.Groups[1].Value.Trim()
            $dottedHeader = [regex]::Match($tableText, '^(?<key>"(?:\\.|[^"\\])*"|''[^'']*''|[A-Za-z0-9_-]+)\s*\.')
            if ($dottedHeader.Success -and (Get-TomlKeyValue $dottedHeader.Groups['key'].Value) -ceq 'features') {
                throw "Ambiguous features subtable declaration: $line"
            }
            $tableKey = Get-TomlKeyValue $tableText
            if ($tableKey -ceq 'features') {
                $featureSections++
                $inFeatures = $true
            } else {
                $inFeatures = $false
            }
            continue
        }
        if ($line -match '^\s*\[') {
            throw "Malformed TOML table header: $line"
        }
        $assignment = [regex]::Match($line, $assignmentPattern)
        if ($assignment.Success) {
            $keyValue = Get-TomlKeyValue $assignment.Groups['key'].Value
            if (-not $inFeatures -and $keyValue -ceq 'features') {
                throw 'Ambiguous features setting outside [features]; refusing to edit config.toml.'
            }
            if ($inFeatures -and $keyValue -ceq 'multi_agent') {
                $settingValue = $line.Substring($assignment.Length).Trim()
                if ($settingValue -cnotmatch '^(true|false)$') { throw "Malformed or ambiguous multi_agent setting: $line" }
                $foundKeys++
                $value = $settingValue
            }
        } elseif (-not $inFeatures) {
            $dottedAssignment = [regex]::Match($line, '^\s*(?<key>"(?:\\.|[^"\\])*"|''[^'']*''|[A-Za-z0-9_-]+)\s*\.')
            if ($dottedAssignment.Success -and (Get-TomlKeyValue $dottedAssignment.Groups['key'].Value) -ceq 'features') {
                throw 'Ambiguous root dotted features setting; refusing to edit config.toml.'
            }
        }
    }
    if ($multilineState) { throw 'Unterminated TOML multiline string; refusing to edit config.toml.' }
    if ($featureSections -gt 1) { throw 'Duplicate [features] tables; refusing to edit config.toml.' }
    if ($foundKeys -gt 1) { throw 'Duplicate multi_agent settings; refusing to edit config.toml.' }
    return [pscustomobject]@{ HasSection = ($featureSections -eq 1); HasKey = ($foundKeys -eq 1); Value = $value }
}

function Set-MultiAgentConfig([string]$Content, $Info) {
    $assignmentPattern = '^\s*(?<key>"(?:\\.|[^"\\])*"|''[^'']*''|[A-Za-z0-9_-]+)\s*='
    if (-not $Info.HasSection) {
        $separator = if ($Content.Length -gt 0 -and -not $Content.EndsWith("`n")) { "`r`n" } else { '' }
        return ($Content + $separator + "[features]`r`nmulti_agent = true`r`n")
    }
    if (-not $Info.HasKey) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.AddRange([string[]]($Content -split "`r?`n", 0, 'RegexMatch'))
        $start = -1
        $end = $lines.Count
        $multilineState = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = Get-TomlVisiblePrefix $lines[$i] ([ref]$multilineState)
            if ($null -eq $line) { continue }
            $header = [regex]::Match($line, '^\s*\[(.*)\]\s*(?:#.*)?$')
            if ($header.Success -and (Get-TomlKeyValue $header.Groups[1].Value) -ceq 'features') { $start = $i; continue }
            if ($start -ge 0 -and $header.Success) { $end = $i; break }
        }
        $lines.Insert($end, 'multi_agent = true')
        return ($lines -join "`r`n") + "`r`n"
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($Content -split "`r?`n", 0, 'RegexMatch'))
    $inFeatures = $false
    $multilineState = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = Get-TomlVisiblePrefix $lines[$i] ([ref]$multilineState)
        if ($null -eq $line) { continue }
        $header = [regex]::Match($line, '^\s*\[(.*)\]\s*(?:#.*)?$')
        if ($header.Success -and (Get-TomlKeyValue $header.Groups[1].Value) -ceq 'features') { $inFeatures = $true; continue }
        if ($header.Success) { $inFeatures = $false }
        $assignment = [regex]::Match($line, $assignmentPattern)
        if ($inFeatures -and $assignment.Success -and (Get-TomlKeyValue $assignment.Groups['key'].Value) -ceq 'multi_agent') {
            $afterEquals = $line.Substring($assignment.Length)
            $settingValue = $afterEquals.Trim()
            if ($settingValue -ceq 'false' -and $afterEquals -cmatch '^(\s*)false(?:\s|$)') {
                $spaces = $Matches[1]
                $prefix = $line.Substring(0, $assignment.Length) + $spaces
                $lines[$i] = $prefix + 'true' + $lines[$i].Substring($assignment.Length + $spaces.Length + 5)
            }
            break
        }
    }
    return ($lines -join "`r`n")
}

if (-not (Test-Path -LiteralPath $agentSource -PathType Container) -or -not (Test-Path -LiteralPath $skillSource -PathType Container)) {
    throw 'Project source files are missing; run the installer from a complete project copy.'
}
$installMap = @()
foreach ($name in @('worker_luna.toml', 'reviewer_astra.toml', 'reviewer_astra_high.toml')) {
    $installMap += [pscustomobject]@{ Source = (Join-Path $agentSource $name); Destination = (Join-Path $codexAgents $name) }
}
$installMap += [pscustomobject]@{ Source = (Join-Path $skillSource 'SKILL.md'); Destination = (Join-Path $skillTarget 'SKILL.md') }
$installMap += [pscustomobject]@{ Source = (Join-Path $skillSource 'agents\openai.yaml'); Destination = (Join-Path $skillTarget 'agents\openai.yaml') }

# An existing state file is accepted only for a complete, hash-matching prior install.
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $oldState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw 'Install state is malformed; refusing to overwrite it.' }
    foreach ($item in $oldState.files) {
        if (-not (Test-Path -LiteralPath $item.destination -PathType Leaf) -or (Get-Hash $item.destination) -ne $item.installedHash) {
            throw "Prior installation contains a modified or missing managed file: $($item.destination)"
        }
    }
    if ([System.IO.Path]::GetFullPath([string]$oldState.config.path) -ine [System.IO.Path]::GetFullPath($configPath)) {
        throw 'Prior install state points to a different config.toml; refusing to continue.'
    }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'config.toml is missing since the prior install; refusing to report success.' }
    $check = Test-MultiAgentConfig ([System.IO.File]::ReadAllText($configPath))
    if (-not $check.HasKey -or $check.Value -ne 'true') { throw 'Prior [features].multi_agent setting is missing or disabled; refusing to report success.' }
    Write-Output 'Cheap Verified Development is already installed; no files changed.'
    return
}

# Preflight all target conflicts and config syntax before creating destination files.
$conflicts = @()
foreach ($item in $installMap) {
    if (Test-Path -LiteralPath $item.Destination -PathType Leaf) {
        $sourceHash = Get-Hash $item.Source
        $destinationHash = Get-Hash $item.Destination
        if ($sourceHash -ne $destinationHash) { $conflicts += $item.Destination }
    } elseif (Test-Path -LiteralPath $item.Destination) {
        throw "Destination is not a file: $($item.Destination)"
    }
}
if ($conflicts.Count -gt 0 -and -not $Force) {
    throw "Conflicting destination file(s) exist. Use -Force to back them up before replacement: $($conflicts -join ', ')"
}

$configExisted = Test-Path -LiteralPath $configPath -PathType Leaf
$configInitialHash = if ($configExisted) { Get-Hash $configPath } else { $null }
$configOriginal = if ($configExisted) { [System.IO.File]::ReadAllText($configPath) } else { '' }
$configInfo = Test-MultiAgentConfig $configOriginal
$configUpdated = Set-MultiAgentConfig $configOriginal $configInfo
$configNeedsWrite = -not ($configInfo.HasKey -and $configInfo.Value -eq 'true')
if ($configNeedsWrite -and (Test-Path -LiteralPath $configPath) -and -not $configExisted) { throw 'Config path exists but is not a regular file.' }

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$backupRoot = Join-Path $stateRoot 'backups'
$manifest = [ordered]@{ version = 1; files = @(); config = $null }
$configBackup = $null
$configCommitted = $false
$configIntendedHash = $null
try {
    foreach ($item in $installMap) {
        $sourceHash = Get-Hash $item.Source
        $existed = Test-Path -LiteralPath $item.Destination -PathType Leaf
        $backupPath = $null
        if ($existed -and (Get-Hash $item.Destination) -ne $sourceHash) {
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
            $backupPath = Join-Path $backupRoot ([guid]::NewGuid().ToString('N') + '.bak')
            Copy-Item -LiteralPath $item.Destination -Destination $backupPath
        }
        $backupHash = if ($backupPath) { Get-Hash $backupPath } else { $null }
        if (-not $existed -or (Get-Hash $item.Destination) -ne $sourceHash) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $item.Destination) -Force | Out-Null
            $temp = $item.Destination + '.cvd-tmp'
            Copy-Item -LiteralPath $item.Source -Destination $temp -Force
            Move-Item -LiteralPath $temp -Destination $item.Destination -Force
        }
        $manifest.files += [pscustomobject]@{ destination = $item.Destination; installedHash = $sourceHash; existedBefore = [bool]($existed -and -not $backupPath); backupPath = $backupPath; backupHash = $backupHash }
    }

    if ($configNeedsWrite) {
        if ($configExisted) {
            if (-not (Test-Path -LiteralPath $configPath -PathType Leaf) -or (Get-Hash $configPath) -ne $configInitialHash) {
                throw 'config.toml changed after preflight; refusing to replace it.'
            }
        } elseif (Test-Path -LiteralPath $configPath) {
            throw 'config.toml appeared after preflight; refusing to replace it.'
        }
        if ($configExisted) {
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
            $configBackup = Join-Path $backupRoot 'config-original.toml'
            Copy-Item -LiteralPath $configPath -Destination $configBackup -Force
            if ((Get-Hash $configBackup) -ne $configInitialHash) { throw 'config.toml changed while its backup was being created; refusing to replace it.' }
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
        $configTemp = $configPath + '.cvd-tmp'
        [System.IO.File]::WriteAllText($configTemp, $configUpdated, $utf8NoBom)
        $configIntendedHash = Get-Hash $configTemp
        if ($configExisted) {
            if (-not (Test-Path -LiteralPath $configPath -PathType Leaf) -or (Get-Hash $configPath) -ne $configInitialHash) {
                throw 'config.toml changed before replacement; refusing to replace it.'
            }
        } elseif (Test-Path -LiteralPath $configPath) {
            throw 'config.toml appeared before replacement; refusing to replace it.'
        }
        Move-Item -LiteralPath $configTemp -Destination $configPath -Force
        $configCommitted = $true
        $manifest.config = [pscustomobject]@{ path = $configPath; changed = $true; existedBefore = $configExisted; originalHash = $configInitialHash; installedHash = Get-Hash $configPath; backupPath = $configBackup; backupHash = $(if ($configBackup) { Get-Hash $configBackup } else { $null }) }
    } else {
        $manifest.config = [pscustomobject]@{ path = $configPath; changed = $false; existedBefore = $configExisted; originalHash = $(if ($configExisted) { $configInitialHash } else { $null }); installedHash = $(if ($configExisted) { $configInitialHash } else { $null }); backupPath = $null; backupHash = $null }
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
} catch {
    # Keep any backups for recovery. Remove only project files written in this failed attempt when they still match.
    foreach ($entry in $manifest.files) {
        if ((Test-Path -LiteralPath $entry.destination -PathType Leaf) -and (Get-Hash $entry.destination) -eq $entry.installedHash) {
            if ($entry.backupPath -and (Test-Path -LiteralPath $entry.backupPath -PathType Leaf)) {
                Copy-Item -LiteralPath $entry.backupPath -Destination ($entry.destination + '.cvd-rollback-tmp') -Force
                Move-Item -LiteralPath ($entry.destination + '.cvd-rollback-tmp') -Destination $entry.destination -Force
            } elseif (-not $entry.existedBefore) {
                Remove-Item -LiteralPath $entry.destination -Force
            }
        }
    }
    if ($configCommitted -and $configBackup -and (Test-Path -LiteralPath $configBackup -PathType Leaf) -and (Test-Path -LiteralPath $configPath -PathType Leaf) -and (Get-Hash $configPath) -eq $configIntendedHash) {
        Copy-Item -LiteralPath $configBackup -Destination ($configPath + '.cvd-rollback-tmp') -Force
        Move-Item -LiteralPath ($configPath + '.cvd-rollback-tmp') -Destination $configPath -Force
    } elseif ($configCommitted -and -not $configExisted -and (Test-Path -LiteralPath $configPath -PathType Leaf) -and (Get-Hash $configPath) -eq $configIntendedHash) {
        Remove-Item -LiteralPath $configPath -Force
    }
    throw
}
Write-Output "Installed Cheap Verified Development. State and backups: $stateRoot"
