# Offline prerequisite repair. Never overwrite an existing configuration.
# Template is byte-identical to Pulsar v2.4.3 win-x64's Interim.runtimeconfig.json.
# Source: official Pulsar-v2.4.3-win-x64.zip, root entry Interim.runtimeconfig.json.
# Archive SHA256: 14b4eec93ee4d2c223a712944646f657d372c16beca4406843e4198f2e93ff8b
# Entry SHA256 is pinned below; no network request or runtime discovery is needed.
[CmdletBinding()]
param([switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
function Assert-SafeFile([string]$path) {
    $cursor = [IO.Path]::GetFullPath($path)
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point rejected: $cursor" }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    if (Test-Path -LiteralPath $path -PathType Container) { throw "Expected a file, not a directory: $path" }
}
function Read-Configuration([string]$path, [bool]$recovery) {
    Assert-SafeFile $path
    $json = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($json -isnot [pscustomobject] -or $json.runtimeOptions -isnot [pscustomobject]) { throw "Invalid runtimeOptions: $path" }
    $options = $json.runtimeOptions
    if ($null -ne $options.PSObject.Properties['configProperties'] -and $options.configProperties -isnot [pscustomobject]) { throw "Invalid configProperties: $path" }
    if ($recovery) {
        if ($options.tfm -ne 'net10.0') { throw "Recovery requires net10.0: $path" }
        foreach ($name in @('Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App')) {
            $framework = @($options.frameworks | Where-Object { $_.name -eq $name -and $_.version -match '^10\.\d+\.\d+$' })
            if ($framework.Count -ne 1) { throw "Recovery requires $name 10.x: $path" }
        }
    }
}
try {
    $root = Join-Path $env:APPDATA 'Pulsar'
    $target = Join-Path $root 'Interim.runtimeconfig.json'
    Assert-SafeFile $target
    if ([IO.File]::Exists($target)) {
        Read-Configuration $target $false
        Write-Host 'Existing Interim runtime configuration preserved.'
        exit 0
    }
    $exe = Join-Path $root 'Interim.exe'
    Assert-SafeFile $exe
    if (-not [IO.File]::Exists($exe)) { throw "Pulsar Interim executable is missing: $exe" }
    $source = $target + '.bak-before-gc'
    Assert-SafeFile $source
    if (-not [IO.File]::Exists($source)) {
        $source = Join-Path $PSScriptRoot 'Interim.runtimeconfig.json'
        Assert-SafeFile $source
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne '6CB93054C26DB0BA765A32D10F3DA067DF256D75E23ECCCE68C29B2CBA839BBB') { throw 'Packaged Interim template integrity check failed.' }
    }
    Read-Configuration $source $true
    if ($ValidateOnly) { Write-Host 'Missing Interim configuration can be recovered; no changes made.'; exit 0 }
    # File.Copy(overwrite:false) is create-only, including a concurrent file creation.
    [IO.File]::Copy($source, $target, $false)
    Write-Host "Recovered missing Interim runtime configuration from $source"
    exit 0
} catch {
    [Console]::Error.WriteLine('Interim configuration repair failed: ' + $_.Exception.Message)
    exit 1
}
