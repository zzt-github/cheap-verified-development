[CmdletBinding()]
param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$AgentsHome = (Join-Path $env:USERPROFILE '.agents')
)

$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $AgentsHome '.cheap-verified-development'
$statePath = Join-Path $stateRoot 'install-state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Output 'No Cheap Verified Development install state found; nothing removed.'
    return
}
try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw 'Install state is malformed; refusing to remove files.' }
if ($state.version -ne 1 -or $null -eq $state.files -or $null -eq $state.config) { throw 'Install state has an unsupported or incomplete format; refusing to remove files.' }

$allowed = @{}
foreach ($name in @('worker_luna.toml', 'reviewer_astra.toml', 'reviewer_astra_high.toml')) {
    $allowed[[System.IO.Path]::GetFullPath((Join-Path (Join-Path $CodexHome 'agents') $name))] = $true
}
$skillRoot = Join-Path $AgentsHome 'skills\cheap-verified-development'
foreach ($relative in @('SKILL.md', 'agents\openai.yaml')) {
    $allowed[[System.IO.Path]::GetFullPath((Join-Path $skillRoot $relative))] = $true
}
$backupRoot = [System.IO.Path]::GetFullPath((Join-Path $stateRoot 'backups'))
$configExpected = [System.IO.Path]::GetFullPath((Join-Path $CodexHome 'config.toml'))
foreach ($item in $state.files) {
    $destination = [System.IO.Path]::GetFullPath([string]$item.destination)
    if (-not $allowed.ContainsKey($destination)) { throw "Install state names an unexpected destination; refusing to remove files: $destination" }
    if ($item.backupPath) {
        $backup = [System.IO.Path]::GetFullPath([string]$item.backupPath)
        if (-not $backup.StartsWith($backupRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Install state backup path is outside its state directory; refusing to restore: $backup"
        }
    }
}
if ([System.IO.Path]::GetFullPath([string]$state.config.path) -ine $configExpected) { throw 'Install state config path does not match the selected Codex home; refusing to restore config.' }
if ($state.config.backupPath) {
    $configBackupFull = [System.IO.Path]::GetFullPath([string]$state.config.backupPath)
    if (-not $configBackupFull.StartsWith($backupRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Install state config backup is outside its state directory; refusing to restore config.'
    }
}

$preserved = @()
foreach ($item in $state.files) {
    $destinationExists = Test-Path -LiteralPath $item.destination -PathType Leaf
    $currentHash = if ($destinationExists) { (Get-FileHash -LiteralPath $item.destination -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    if ($item.backupPath) {
        if (-not (Test-Path -LiteralPath $item.backupPath -PathType Leaf)) {
            $preserved += $item.destination
            continue
        }
        $backupHash = (Get-FileHash -LiteralPath $item.backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $item.backupHash -or $backupHash -ne $item.backupHash) {
            $preserved += $item.destination
            continue
        }
        if ($destinationExists -and $currentHash -ne $item.installedHash) {
            $preserved += $item.destination
            continue
        }
        Copy-Item -LiteralPath $item.backupPath -Destination ($item.destination + '.cvd-restore-tmp') -Force
        Move-Item -LiteralPath ($item.destination + '.cvd-restore-tmp') -Destination $item.destination -Force
    } elseif ($destinationExists -and $currentHash -ne $item.installedHash) {
        $preserved += $item.destination
    } elseif ($destinationExists -and -not $item.existedBefore) {
        Remove-Item -LiteralPath $item.destination -Force
    }
}

$config = $state.config
if ($config.changed) {
    $configExists = Test-Path -LiteralPath $config.path -PathType Leaf
    $currentHash = if ($configExists) { (Get-FileHash -LiteralPath $config.path -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    if ($config.existedBefore) {
        $backupValid = $false
        if ($config.backupPath -and (Test-Path -LiteralPath $config.backupPath -PathType Leaf)) {
            $backupHash = (Get-FileHash -LiteralPath $config.backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $backupValid = [bool]($config.backupHash -and $backupHash -eq $config.backupHash -and $backupHash -eq $config.originalHash)
        }
        if (-not $backupValid) {
            $preserved += $config.path
        } elseif ($configExists -and $currentHash -eq $config.installedHash) {
            Copy-Item -LiteralPath $config.backupPath -Destination ($config.path + '.cvd-restore-tmp') -Force
            Move-Item -LiteralPath ($config.path + '.cvd-restore-tmp') -Destination $config.path -Force
        } elseif (-not $configExists) {
            Copy-Item -LiteralPath $config.backupPath -Destination ($config.path + '.cvd-restore-tmp') -Force
            Move-Item -LiteralPath ($config.path + '.cvd-restore-tmp') -Destination $config.path -Force
        } else {
            $preserved += $config.path
        }
    } elseif ($configExists -and $currentHash -eq $config.installedHash) {
        Remove-Item -LiteralPath $config.path -Force
    } elseif ($configExists) {
        $preserved += $config.path
    }
}

if ($preserved.Count -eq 0) {
    Remove-Item -LiteralPath $statePath -Force
    Remove-Item -LiteralPath $stateRoot -Recurse -Force
    Write-Output 'Uninstalled Cheap Verified Development and restored eligible backups.'
} else {
    Write-Output ('Uninstalled eligible files. Preserved modified files and retained backup/state data for review: ' + ($preserved -join ', '))
}
