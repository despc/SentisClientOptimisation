# Windows PowerShell 5.1; transaction covers plugin-owned files, not dependencies.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Begin', 'Commit', 'Rollback')][string]$Action,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [string]$Desktop = [Environment]::GetFolderPath('Desktop')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
function FullPath([string]$path) {
    if ($path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))') { throw 'An absolute path is required.' }
    [IO.Path]::GetFullPath($path).TrimEnd('\')
}
function AssertSafePath([string]$path) {
    $cursor = FullPath $path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point rejected: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function AssertSafeTree([string]$path) {
    AssertSafePath $path
    if ([IO.Directory]::Exists($path)) {
        foreach ($item in @(Get-ChildItem -LiteralPath $path -Force)) {
            AssertSafePath $item.FullName
            if ($item.PSIsContainer) { AssertSafeTree $item.FullName }
        }
    }
}
function OwnedFiles($pulsar, $desktop) {
    $paths = @()
    if ([IO.Directory]::Exists($pulsar)) {
        $paths += @(Get-ChildItem -LiteralPath $pulsar -Force -File | Where-Object {
            $_.Name.StartsWith('Legacy.exe.config', [StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('Interim.runtimeconfig.json', [StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('SentisClientOptimisation', [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object { $_.FullName })
    }
    foreach ($edition in @('Legacy', 'Interim')) {
        foreach ($suffix in @('Local\SentisClientOptimisation.dll', 'Profiles\Current.xml', 'Profiles\Current.xml.bak')) {
            $paths += Join-Path $pulsar "$edition\$suffix"
        }
    }
    $paths += Join-Path $desktop 'Space Engineers (Pulsar).lnk'
    $paths += Join-Path $desktop 'Space Engineers (Pulsar, GC).cmd'
    @($paths | Sort-Object -Unique)
}
function ManagedDirectories($pulsar, $desktop) {
    @($pulsar, $desktop)
    foreach ($edition in @('Legacy', 'Interim')) {
        Join-Path $pulsar $edition
        Join-Path $pulsar "$edition\Local"
        Join-Path $pulsar "$edition\Profiles"
    }
}
try {
    $StatePath = FullPath $StatePath
    AssertSafeTree $StatePath
    $manifestPath = Join-Path $StatePath 'manifest.json'
    if ($Action -eq 'Begin') {
        $pulsar = FullPath (Join-Path $env:APPDATA 'Pulsar')
        $Desktop = FullPath $Desktop
        foreach ($directory in @(ManagedDirectories $pulsar $Desktop)) { AssertSafePath $directory }
        foreach ($path in @(OwnedFiles $pulsar $Desktop)) { AssertSafePath $path }
        foreach ($target in @($pulsar, $Desktop)) {
            if ($StatePath -eq $target -or $StatePath.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($StatePath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'State must be separate from installation targets.' }
        }
        if (Test-Path -LiteralPath $StatePath) {
            if (@(Get-ChildItem -LiteralPath $StatePath -Force).Count -ne 0) { throw 'State directory is not empty.' }
        }
        [IO.Directory]::CreateDirectory((Join-Path $StatePath 'backups')) | Out-Null
        $files = @()
        foreach ($path in @(OwnedFiles $pulsar $Desktop)) {
            $backup = $null
            if ([IO.File]::Exists($path)) {
                $backup = 'backups\' + $files.Count + '.bin'
                [IO.File]::Copy($path, (Join-Path $StatePath $backup), $false)
            }
            $files += [pscustomobject]@{ Path = $path; Backup = $backup }
        }
        $directories = @(ManagedDirectories $pulsar $Desktop | ForEach-Object {
            [pscustomobject]@{ Path = $_; Existed = [IO.Directory]::Exists($_) }
        })
        $manifest = [pscustomobject]@{ Format = 'SentisInstallTransaction1'; Pulsar = $pulsar; Desktop = $Desktop; Files = $files; Directories = $directories }
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($true)))
    } else {
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        if ($manifest.Format -ne 'SentisInstallTransaction1') { throw 'Invalid transaction manifest.' }
        if ($Action -eq 'Rollback') {
            # Validate every source and destination before changing any target.
            foreach ($directory in @(ManagedDirectories $manifest.Pulsar $manifest.Desktop)) { AssertSafePath $directory }
            foreach ($path in @(OwnedFiles $manifest.Pulsar $manifest.Desktop)) { AssertSafePath $path }
            foreach ($file in $manifest.Files) {
                AssertSafePath $file.Path
                if ($null -ne $file.Backup) {
                    $source = Join-Path $StatePath $file.Backup
                    AssertSafePath $source
                    if (-not [IO.File]::Exists($source)) { throw 'A transaction backup is missing.' }
                }
            }
            foreach ($path in @(OwnedFiles $manifest.Pulsar $manifest.Desktop)) {
                if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            }
            foreach ($file in $manifest.Files) {
                if ($null -ne $file.Backup) {
                    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file.Path)) | Out-Null
                    [IO.File]::Copy((Join-Path $StatePath $file.Backup), $file.Path, $true)
                }
            }
            foreach ($dir in @($manifest.Directories | Sort-Object { $_.Path.Length } -Descending)) {
                if (-not $dir.Existed -and [IO.Directory]::Exists($dir.Path) -and @(Get-ChildItem -LiteralPath $dir.Path -Force).Count -eq 0) {
                    [IO.Directory]::Delete($dir.Path)
                }
            }
        }
        Remove-Item -LiteralPath $StatePath -Force -Recurse
    }
    exit 0
} catch {
    [Console]::Error.WriteLine('Install transaction failed: ' + $_.Exception.Message)
    exit 1
}
