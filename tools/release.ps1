# Builds the plugin in Release and packs it the way it is handed out: a zip with the dll and the install/uninstall
# scripts. Used by the release workflow (.github/workflows/release.yml) and by hand:
#   powershell -ExecutionPolicy Bypass -File tools\release.ps1 -Version 0.2.1
# -SeBin is the folder with the game's libraries the plugin is built against: the client's Bin64, or the
# DedicatedServer64 of a downloaded server (what the workflow uses; the libraries are not in the repository).
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$SeBin = 'C:\Program Files (x86)\Steam\steamapps\common\SpaceEngineers\Bin64',
    [string]$Plugin = 'SentisClientOptimisation',
    [string]$Out = 'dist'
)
$ErrorActionPreference = 'Stop'

# (tags come in both forms: 1.2.3 and v1.2.3; the zip and the assembly take the number)
if ($Version -notmatch '^v?(\d+\.\d+\.\d+)([-.][0-9A-Za-z.-]+)?$') { throw "The version is to look like 1.2.3 or v1.2.3 (got '$Version')" }
$number = $Matches[1]
$repo = Split-Path -Parent $PSScriptRoot
foreach ($needed in 'Sandbox.Game', 'SpaceEngineers.Game', 'VRage.Library') {
    if (-not (Test-Path "$SeBin\$needed.dll")) { throw "Not found: $SeBin\$needed.dll (SeBin is '$SeBin')" }
}

$bin = Join-Path $repo "$Plugin\bin\Release"
if (Test-Path $bin) { Remove-Item $bin -Recurse -Force }
dotnet build (Join-Path $repo "$Plugin\$Plugin.csproj") -c Release "-p:SeBin=$SeBin" "-p:Version=$number" "-p:AssemblyVersion=$number.0" "-p:FileVersion=$number.0" --nologo -v minimal
if ($LASTEXITCODE -ne 0) { throw "The build failed ($LASTEXITCODE)" }
$dll = Join-Path $bin "$Plugin.dll"
if (-not (Test-Path $dll)) { throw "$Plugin.dll is not in the build" }

$stage = Join-Path $repo "$Out\$Plugin"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
# the scripts and the README that ship with the plugin (a dll lying in package\ is an earlier build, not this one)
Get-ChildItem (Join-Path $repo 'package') -File | Where-Object { $_.Name -ne "$Plugin.dll" } | Copy-Item -Destination $stage
Copy-Item $dll -Destination $stage
# the version of this release on the first line of the README (the file is UTF-8 without a byte order mark)
$readmePath = Join-Path $stage 'README.txt'
$utf8 = New-Object Text.UTF8Encoding $false
$readme = [IO.File]::ReadAllText($readmePath, $utf8)
if ($readme -notmatch "^$Plugin \d+\.\d+\.\d+") { throw "README.txt does not start with $Plugin and a version" }
$readme = $readme -replace "^$Plugin \d+\.\d+\.\d+", "$Plugin $number"
[IO.File]::WriteAllText($readmePath, $readme, $utf8)

$zip = Join-Path $repo "$Out\$Plugin-$number.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Write-Host "Packed: $zip"
Get-ChildItem $stage | ForEach-Object { Write-Host ("  {0,10}  {1}" -f $_.Length, $_.Name) }
if ($env:GITHUB_OUTPUT) { "zip=$zip" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
