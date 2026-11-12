[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [string]$ScratchRoot = (Join-Path $env:LOCALAPPDATA 'hermes/cache/scratch'),
    [switch]$Network
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$installer = Join-Path (Split-Path $PSScriptRoot -Parent) 'package\install-pulsar.ps1'
$ps = Join-Path $PSHOME 'powershell.exe'
$root = Join-Path $ScratchRoot ('pulsar-tests-' + [guid]::NewGuid().ToString('N'))
$oldAppData = $env:APPDATA; $oldTemp = $env:TEMP; $oldTmp = $env:TMP
$passed = 0
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Reset-Sandbox {
    $script:caseRoot = Join-Path $root ([guid]::NewGuid().ToString('N'))
    $env:APPDATA = Join-Path $script:caseRoot 'appdata'
    $env:TEMP = Join-Path $script:caseRoot 'temp'; $env:TMP = $env:TEMP
    [void][IO.Directory]::CreateDirectory($env:APPDATA)
    [void][IO.Directory]::CreateDirectory($env:TEMP)
    $script:target = Join-Path $env:APPDATA 'Pulsar'
}
function Invoke-Install([string]$archive, [string]$runtime = 'Legacy') {
    $argsList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $installer)
    if ($archive) { $argsList += @('-ArchivePath', $archive) }
    if ($runtime -ne 'Legacy') { $argsList += @('-Runtime', $runtime) }
    $ErrorActionPreference = 'Continue'
    $script:lastOutput = (& $ps @argsList 2>&1 | Out-String)
    return $LASTEXITCODE
}
function Pass([string]$name) { $script:passed++; Write-Host "PASS $name" }
function New-Zip([string]$path, [string]$entryName, [string]$content, [int]$attributes = 0) {
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry($entryName)
        $entry.ExternalAttributes = $attributes
        $writer = New-Object IO.StreamWriter ($entry.Open())
        try { $writer.Write($content) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
}
function Assert-Rejected([string]$archive, [string]$reason) {
    $sentinel = Join-Path $env:APPDATA 'keep.txt'
    [IO.File]::WriteAllText($sentinel, 'user-owned')
    Assert ((Invoke-Install $archive) -eq 1) "Expected exit 1: $lastOutput"
    Assert ($lastOutput -match $reason) "Wrong rejection reason (expected $reason): $lastOutput"
    Assert (-not (Test-Path -LiteralPath $target)) 'Rejected archive mutated installation target'
    Assert ([IO.File]::ReadAllText($sentinel) -ceq 'user-owned') 'User file changed'
    Assert (@(Get-ChildItem -LiteralPath $env:TEMP -Force).Count -eq 0) 'Staging was not cleaned'
}
try {
    Assert ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5) 'Run with Windows PowerShell 5.1'
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Reset-Sandbox
    [void][IO.Directory]::CreateDirectory($target)
    $exe = Join-Path $target 'Legacy.exe'
    [IO.File]::WriteAllText($exe, 'existing-user-install')
    $before = (Get-FileHash -LiteralPath $exe).Hash
    Assert ((Invoke-Install (Join-Path $root 'does-not-exist.zip')) -eq 0) "Existing Legacy.exe must return success without opening the archive: $lastOutput"
    Assert ((Get-FileHash -LiteralPath $exe).Hash -eq $before) 'Existing Legacy.exe changed'
    Assert (@(Get-ChildItem -LiteralPath $target -Recurse -Force).Count -eq 1) 'No-op added files'
    Pass 'existing Legacy.exe is a true no-op'
    Assert ([IO.File]::Exists($ArchivePath)) "Real release archive not found: $ArchivePath"
    Reset-Sandbox
    Assert ((Invoke-Install $ArchivePath) -eq 0) "Real release install failed: $lastOutput"
    foreach ($relative in @('Legacy.exe', 'Legacy.exe.config', 'Libraries\Legacy\0Harmony.dll', 'Libraries\Legacy\Pulsar.Shared.dll', 'Libraries\Legacy\Pulsar.Protocol.dll', 'Libraries\Legacy\Newtonsoft.Json.dll', 'Libraries\Compiler\Compiler.exe', 'Libraries\Interface\Interface.exe', 'Legacy\Profiles\Current.xml')) {
        Assert ([IO.File]::Exists((Join-Path $target $relative))) "Missing installed file $relative"
    }
    [xml]$config = Get-Content -LiteralPath (Join-Path $target 'Legacy.exe.config') -Raw
    Assert ($config.DocumentElement.Name -eq 'configuration') 'Invalid configuration root'
    $profilePath = Join-Path $target 'Legacy\Profiles\Current.xml'
    [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $target 'Libraries\Legacy\Pulsar.Protocol.dll')))
    $shared = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $target 'Libraries\Legacy\Pulsar.Shared.dll')))
    $serializer = New-Object Xml.Serialization.XmlSerializer ($shared.GetType('Pulsar.Shared.Data.Profile', $true))
    $reader = [IO.File]::OpenRead($profilePath)
    try { $profile = $serializer.Deserialize($reader) } finally { $reader.Dispose() }
    Assert ($profile.Name -eq 'Current' -and $profile.Validate()) 'Real Pulsar XmlSerializer rejected generated profile'
    foreach ($property in @('GitHub', 'DevFolder', 'Local', 'Mods')) { Assert ($profile.$property.Count -eq 0) "Profile $property is not empty" }
    Pass 'real portable archive and real Pulsar XmlSerializer'
    $beforeHashes = @(Get-ChildItem -LiteralPath $target -File -Recurse | Get-FileHash | ForEach-Object { $_.Path + ':' + $_.Hash })
    Assert ((Invoke-Install $ArchivePath) -eq 0) "Second install failed: $lastOutput"
    $afterHashes = @(Get-ChildItem -LiteralPath $target -File -Recurse | Get-FileHash | ForEach-Object { $_.Path + ':' + $_.Hash })
    Assert (($beforeHashes -join "`n") -eq ($afterHashes -join "`n")) 'Idempotent install changed files'
    Pass 'second install preserves every installed byte'
    Reset-Sandbox
    [void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'Legacy.exe'), 'existing-user-legacy')
    Assert ((Invoke-Install $ArchivePath 'Interim') -eq 0) "Interim install failed: $lastOutput"
    Assert ([IO.File]::Exists((Join-Path $target 'Interim.exe'))) 'Interim executable missing'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'Legacy.exe')) -eq 'existing-user-legacy') 'Existing Legacy was overwritten'
    $reader = [IO.File]::OpenRead((Join-Path $target 'Interim/Profiles/Current.xml'))
    try { $profile = $serializer.Deserialize($reader) } finally { $reader.Dispose() }
    Assert ($profile.Validate()) 'Interim profile schema is invalid'
    Pass 'Interim installation beside existing Legacy and valid profile'
    foreach ($attack in @(
        @{ Name = '../escaped.txt'; Reason = 'Unsafe archive path'; Attributes = 0 },
        @{ Name = '..\escaped.txt'; Reason = 'Unsafe archive path'; Attributes = 0 },
        @{ Name = '/absolute.txt'; Reason = 'Absolute/empty archive path'; Attributes = 0 },
        @{ Name = 'C:\absolute.txt'; Reason = 'Absolute/empty archive path'; Attributes = 0 },
        @{ Name = 'safe.txt:stream'; Reason = 'Unsafe archive path'; Attributes = 0 },
        @{ Name = 'NUL.txt'; Reason = 'Unsafe archive path'; Attributes = 0 },
        @{ Name = 'link'; Reason = 'Link/special archive entry'; Attributes = -1610612736 },
        @{ Name = 'reparse'; Reason = 'Link/special archive entry'; Attributes = 1024 }
    )) {
        Reset-Sandbox
        $bad = Join-Path $caseRoot 'attack.zip'
        New-Zip $bad $attack.Name 'bad' $attack.Attributes
        Assert-Rejected $bad $attack.Reason
        Assert (-not [IO.File]::Exists((Join-Path $env:TEMP 'escaped.txt'))) 'ZipSlip escaped staging'
        Pass ('reject archive path/type: ' + $attack.Name)
    }
    Reset-Sandbox
    $bad = Join-Path $caseRoot 'invalid.zip'
    [IO.File]::WriteAllText($bad, 'not a zip')
    Assert-Rejected $bad 'central directory|End of Central|bootstrap failed'
    Pass 'invalid archive leaves no mutation'
    Reset-Sandbox
    $bad = Join-Path $caseRoot 'missing.zip'
    New-Zip $bad 'README.md' 'not a Pulsar payload'
    Assert-Rejected $bad 'Missing/empty release payload: Legacy.exe'
    Pass 'missing payload fails before target creation'
    foreach ($removed in @('Libraries/Legacy/0Harmony.dll', 'Libraries/Legacy/Pulsar.Shared.dll')) {
        Reset-Sandbox
        $bad = Join-Path $caseRoot 'missing-dependency.zip'
        [IO.File]::Copy($ArchivePath, $bad)
        $zip = [IO.Compression.ZipFile]::Open($bad, [IO.Compression.ZipArchiveMode]::Update)
        try { $zip.GetEntry($removed).Delete() } finally { $zip.Dispose() }
        Assert-Rejected $bad 'Missing/empty release payload'
        Pass ('missing dependency: ' + $removed)
    }
    Reset-Sandbox
    $bad = Join-Path $caseRoot 'invalid-config.zip'
    [IO.File]::Copy($ArchivePath, $bad)
    $zip = [IO.Compression.ZipFile]::Open($bad, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $zip.GetEntry('Legacy.exe.config').Delete()
        $entry = $zip.CreateEntry('Legacy.exe.config')
        $writer = New-Object IO.StreamWriter ($entry.Open())
        try { $writer.Write('<notConfiguration/>') } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    Assert-Rejected $bad 'root must be configuration'
    Pass 'invalid config root rejected before copy'
    Reset-Sandbox
    [void][IO.Directory]::CreateDirectory((Join-Path $target 'Legacy\Profiles'))
    $current = Join-Path $target 'Legacy\Profiles\Current.xml'
    $other = Join-Path $target 'Legacy\Profiles\Custom.xml'
    [IO.File]::WriteAllText($current, 'user-current-profile')
    [IO.File]::WriteAllText($other, 'user-custom-profile')
    [IO.File]::WriteAllText((Join-Path $target 'README.md'), 'user-readme')
    Assert ((Invoke-Install $ArchivePath) -eq 0) "Install with existing profiles failed: $lastOutput"
    Assert ([IO.File]::ReadAllText($current) -ceq 'user-current-profile') 'Existing current profile changed'
    Assert ([IO.File]::ReadAllText($other) -ceq 'user-custom-profile') 'Existing custom profile changed'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'README.md')) -ceq 'user-readme') 'Existing unrelated file changed'
    Pass 'preexisting profiles and files are preserved without Legacy.exe'
    Reset-Sandbox
    [void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'Libraries'), 'user-file-blocks-copy')
    [IO.File]::WriteAllText((Join-Path $target 'README.md'), 'user-file')
    Assert ((Invoke-Install $ArchivePath) -eq 1) 'Expected partial copy to fail'
    Assert ($lastOutput -match 'blocks directory') "Unexpected copy failure: $lastOutput"
    Assert (@(Get-ChildItem -LiteralPath $target -Force).Count -eq 2) 'Rollback left newly created payload files'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'Libraries')) -ceq 'user-file-blocks-copy') 'Rollback deleted blocking existing file'
    Assert ([IO.File]::ReadAllText((Join-Path $target 'README.md')) -ceq 'user-file') 'Rollback changed existing file'
    Assert (@(Get-ChildItem -LiteralPath $env:TEMP -Force).Count -eq 0) 'Rollback left staging'
    Pass 'partial copy rollback removes only newly created files'
    # Import only the pure release-selection helper, never execute bootstrap in this process.
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
    $selector = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Select-PulsarAsset' }, $true)
    Assert ($null -ne $selector) 'Missing release selection helper'
    . ([scriptblock]::Create($selector.Extent.Text))
    $goodAsset = [pscustomobject]@{ name = 'Pulsar-v2.4.3-win-x64.zip'; browser_download_url = 'https://github.com/SpaceGT/Pulsar/releases/download/v2.4.3/Pulsar-v2.4.3-win-x64.zip'; size = 31380992; digest = ('sha256:' + ('a' * 64)) }
    $release = [pscustomobject]@{ draft = $false; prerelease = $false; assets = @($goodAsset) }
    Assert ((Select-PulsarAsset $release).name -ceq $goodAsset.name) 'Valid x64 ZIP asset rejected'
    foreach ($change in @(
        @{ Field = 'name'; Value = 'Updater-v1.exe' },
        @{ Field = 'name'; Value = 'Pulsar-v2.4.3-win-arm64.zip' },
        @{ Field = 'name'; Value = 'Pulsar-v2.4.3-win-x64.zip.exe' },
        @{ Field = 'browser_download_url'; Value = 'http://github.com/SpaceGT/Pulsar/releases/download/v2/x.zip' },
        @{ Field = 'browser_download_url'; Value = 'https://github.com.evil.test/SpaceGT/Pulsar/releases/download/v2/x.zip' },
        @{ Field = 'browser_download_url'; Value = 'https://github.com/other/Pulsar/releases/download/v2/x.zip' },
        @{ Field = 'browser_download_url'; Value = 'https://github.com/SpaceGT/Pulsar/releases/download/v2/Pulsar-v2.4.3-win-x64.zip?bad=1' },
        @{ Field = 'digest'; Value = 'sha256:invalid' }
    )) {
        $copy = [pscustomobject]@{ name = $goodAsset.name; browser_download_url = $goodAsset.browser_download_url; size = $goodAsset.size; digest = $goodAsset.digest }
        $copy.($change.Field) = $change.Value
        $release.assets = @($copy)
        $rejected = $false
        try { [void](Select-PulsarAsset $release) } catch { $rejected = $true }
        Assert $rejected ('Unsafe asset metadata accepted: ' + $change.Value)
    }
    $release.assets = @($goodAsset, $goodAsset)
    $rejected = $false; try { [void](Select-PulsarAsset $release) } catch { $rejected = $true }
    Assert $rejected 'Ambiguous asset selection accepted'
    $release.assets = @($goodAsset); $release.prerelease = $true
    $rejected = $false; try { [void](Select-PulsarAsset $release) } catch { $rejected = $true }
    Assert $rejected 'Prerelease accepted'
    $release.assets = @($goodAsset); $release.prerelease = $false
    $withoutDigest = [pscustomobject]@{ name = $goodAsset.name; browser_download_url = $goodAsset.browser_download_url; size = $goodAsset.size }
    $release.assets = @($withoutDigest)
    Assert ((Select-PulsarAsset $release).name -ceq $goodAsset.name) 'Missing optional GitHub digest was rejected'
    $integrity = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-AssetIntegrity' }, $true)
    Assert ($null -ne $integrity) 'Missing asset integrity helper'
    . ([scriptblock]::Create($integrity.Extent.Text))
    $assetWithHash = [pscustomobject]@{ size = (Get-Item -LiteralPath $ArchivePath).Length; digest = ('sha256:' + (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()) }
    Assert-AssetIntegrity $assetWithHash $ArchivePath
    $assetWithHash.digest = 'sha256:' + ('0' * 64)
    $rejected = $false; try { Assert-AssetIntegrity $assetWithHash $ArchivePath } catch { $rejected = $_.Exception.Message -match 'digest mismatch' }
    Assert $rejected 'Mismatched SHA256 was accepted'
    $assetWithHash.digest = $null; $assetWithHash.size++
    $rejected = $false; try { Assert-AssetIntegrity $assetWithHash $ArchivePath } catch { $rejected = $_.Exception.Message -match 'size' }
    Assert $rejected 'Mismatched downloaded size was accepted'
    Pass 'strict release asset name, stable status, HTTPS URL and digest validation'
    if ($Network) {
        Reset-Sandbox
        Assert ((Invoke-Install '') -eq 0) "Real network bootstrap failed: $lastOutput"
        Assert ([IO.File]::Exists((Join-Path $target 'Legacy.exe'))) 'Network bootstrap missing Legacy.exe'
        Assert ([IO.File]::Exists((Join-Path $target 'Legacy\Profiles\Current.xml'))) 'Network bootstrap missing profile'
        Pass 'real GitHub latest stable network bootstrap (no game execution)'
    }
    Write-Host "All $passed Pulsar bootstrap tests passed (Windows PowerShell $($PSVersionTable.PSVersion))."
}
finally {
    $env:APPDATA = $oldAppData; $env:TEMP = $oldTemp; $env:TMP = $oldTmp
    if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
