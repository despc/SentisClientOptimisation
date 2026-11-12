# Builds the plugin and a per-user EXE installer (Inno Setup 6.5+).
# Used by .github/workflows/release.yml and by hand:
#   powershell -ExecutionPolicy Bypass -File tools\release.ps1 -Version 0.2.1
# -SeBin is the folder with the game's libraries the plugin is built against: the client's Bin64, or the
# DedicatedServer64 of a downloaded server (what the workflow uses; the libraries are not in the repository).
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$SeBin = 'C:\Program Files (x86)\Steam\steamapps\common\SpaceEngineers\Bin64',
    [ValidateSet('SentisClientOptimisation')][string]$Plugin = 'SentisClientOptimisation',
    [string]$Out = 'dist',
    [string]$Iscc = $env:INNO_COMPILER
)
$ErrorActionPreference = 'Stop'

# Tags support both 1.2.3 and v1.2.3.
if ($Version -notmatch '^v?(\d+\.\d+\.\d+)([-.][0-9A-Za-z.-]+)?$') { throw "The version is to look like 1.2.3 or v1.2.3 (got '$Version')" }
$number = $Matches[1]
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Iscc) {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { $Iscc = $command.Source }
    else {
        $Iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
}
if (-not $Iscc -or -not (Test-Path $Iscc)) { throw 'Install Inno Setup 6.5+ or pass -Iscc <path to ISCC.exe>.' }
$outPath = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $repo $Out }
$outPath = [IO.Path]::GetFullPath($outPath)
foreach ($needed in 'Sandbox.Game', 'SpaceEngineers.Game', 'VRage.Library') {
    if (-not (Test-Path "$SeBin\$needed.dll")) { throw "Not found: $SeBin\$needed.dll (SeBin is '$SeBin')" }
}

$bin = Join-Path $outPath "build\$Plugin"
if (Test-Path $bin) { Remove-Item $bin -Recurse -Force }
dotnet build (Join-Path $repo "$Plugin\$Plugin.csproj") -c Release "-p:SeBin=$SeBin" "-p:Version=$number" "-p:AssemblyVersion=$number.0" "-p:FileVersion=$number.0" "-p:OutputPath=$bin" --nologo -v minimal
if ($LASTEXITCODE -ne 0) { throw "The build failed ($LASTEXITCODE)" }
$dll = Join-Path $bin "$Plugin.dll"
if (-not (Test-Path $dll)) { throw "$Plugin.dll is not in the build" }

$stage = Join-Path $outPath $Plugin
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
# the scripts and the README that ship with the plugin (a dll lying in package\ is an earlier build, not this one)
foreach ($file in 'install.ps1', 'uninstall.ps1', 'install-pulsar.ps1', 'install-dotnet.ps1', 'install-transaction.ps1', 'shortcut.ps1', 'SentisClientOptimisation.ico', 'README.txt') {
    Copy-Item (Join-Path $repo "package\$file") -Destination $stage
}
Copy-Item $dll -Destination $stage
# the version of this release on the first line of the README (the file is UTF-8 without a byte order mark)
$readmePath = Join-Path $stage 'README.txt'
$utf8 = New-Object Text.UTF8Encoding $false
$readme = [IO.File]::ReadAllText($readmePath, $utf8)
if ($readme -notmatch "^$Plugin \d+\.\d+\.\d+") { throw "README.txt does not start with $Plugin and a version" }
$readme = $readme -replace "^$Plugin \d+\.\d+\.\d+", "$Plugin $number"
[IO.File]::WriteAllText($readmePath, $readme, $utf8)

$installer = Join-Path $outPath "$Plugin-$number-Setup.exe"
if (Test-Path $installer) { Remove-Item $installer -Force }
& $Iscc "/DAppVersion=$number" "/DPayloadDir=$stage" "/DOutputPath=$outPath" (Join-Path $repo 'installer\SentisClientOptimisation.iss')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $installer)) { throw "Installer build failed ($LASTEXITCODE)" }
Write-Host "Installer: $installer"
Get-FileHash $installer -Algorithm SHA256 | Format-List
if ($env:GITHUB_OUTPUT) { "installer=$installer" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
