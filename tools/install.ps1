# Builds SentisClientOptimisation and puts it into Pulsar's local plugins (%APPDATA%\Pulsar\Legacy\Local).
# Then in the game: Pulsar's plugin list > Local > SentisClientOptimisation on, restart the game.
# Usage (PowerShell): powershell -NoProfile -ExecutionPolicy Bypass -File tools\install.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
# the SDK installed for the user (~\.dotnet) when there is none on PATH
$dotnet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
if (-not (Test-Path $dotnet)) { $dotnet = 'dotnet' } else { $env:DOTNET_ROOT = Split-Path $dotnet }
& $dotnet build "$root\SentisClientOptimisation\SentisClientOptimisation.csproj" -c Release | Out-Host
if ($LASTEXITCODE -ne 0) { throw "build failed" }
$local = Join-Path $env:APPDATA 'Pulsar\Legacy\Local'
New-Item -ItemType Directory -Force $local | Out-Null
Copy-Item "$root\SentisClientOptimisation\bin\Release\SentisClientOptimisation.dll" $local -Force
"installed into $local"
# switched on in Pulsar's current profile (Local), so the game loads it at the next start
$profile = Join-Path $env:APPDATA 'Pulsar\Legacy\Profiles\Current.xml'
if (Test-Path $profile) {
    [xml]$xml = Get-Content $profile -Raw -Encoding UTF8
    $local = $xml.SelectSingleNode('//Local')
    if ($local -ne $null -and -not ($local.ChildNodes | Where-Object { $_.InnerText -eq 'SentisClientOptimisation.dll' })) {
        $node = $xml.CreateElement('string')
        $node.InnerText = 'SentisClientOptimisation.dll'
        [void]$local.AppendChild($node)
        $xml.Save($profile)
        "switched on in $profile"
    }
}
