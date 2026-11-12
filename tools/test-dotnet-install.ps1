[CmdletBinding()]
param(
    [string]$ScratchRoot = (Join-Path $env:LOCALAPPDATA 'hermes/cache/scratch'),
    [switch]$Network
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$installer = Join-Path (Split-Path $PSScriptRoot -Parent) 'package\install-dotnet.ps1'
$ps = Join-Path $PSHOME 'powershell.exe'
$root = Join-Path $ScratchRoot ('dotnet-tests-' + [guid]::NewGuid().ToString('N'))
$names = @('LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP', 'DOTNET_ROOT', 'DOTNET_ROOT_X64')
$saved = @{}
[void][IO.Directory]::CreateDirectory($ScratchRoot)
Start-Transcript -LiteralPath ($root + '.log') | Out-Null
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Invoke-Installer([switch]$Check) {
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $installer)
    if ($Check) { $arguments += '-CheckOnly' }
    $ErrorActionPreference = 'Continue'
    $script:lastOutput = (& $ps @arguments 2>&1 | Out-String)
    $script:lastCode = $LASTEXITCODE
    Write-Host $lastOutput
}
function Snapshot([string]$path) {
    @(Get-ChildItem -LiteralPath $path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { 'D:' + $_.FullName } else { 'F:' + $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash + ':' + $_.LastWriteTimeUtc.Ticks }
    }) -join "`n"
}
try {
    Assert ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSEdition -eq 'Desktop') 'Requires real Windows PowerShell 5.1'
    foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP')) {
        $value = Join-Path $root $name
        [void][IO.Directory]::CreateDirectory($value)
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
    $env:DOTNET_ROOT = ''; $env:DOTNET_ROOT_X64 = ''
    $target = Join-Path $env:LOCALAPPDATA 'SentisClientOptimisation\dotnet'
    $before = Snapshot $root
    Invoke-Installer -Check
    Assert ($lastCode -eq 2) "Missing .NET 10 must return 2, got $lastCode (system must not have both .NET 10 runtimes)"
    Assert ((Snapshot $root) -ceq $before) 'CheckOnly modified sandbox'
    Write-Host 'PASS missing CheckOnly returns 2 without writes'
    [void][IO.Directory]::CreateDirectory($target)
    $sentinel = Join-Path $target 'user-owned.txt'
    [IO.File]::WriteAllText($sentinel, 'do not overwrite')
    $before = Snapshot $root
    Invoke-Installer
    Assert ($lastCode -eq 1) 'Unusable occupied root must fail safely'
    Assert ((Snapshot $root) -ceq $before) 'Occupied root or unrelated files changed'
    Remove-Item -LiteralPath $sentinel
    [IO.Directory]::Delete($target)
    Write-Host 'PASS occupied unknown installation is preserved without writes'
    # Load only helper definitions; never dot-source the installer's exit path.
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
    Assert (@($parseErrors).Count -eq 0) 'Installer must parse in PS 5.1'
    foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
    Assert ([bool](Get-Command Expand-SafeArchive -ErrorAction SilentlyContinue)) 'Missing safe archive extractor'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($entryName in @('../escaped', '..\escaped', '/absolute', 'C:\absolute', 'safe:stream', 'a/CON.txt', 'a/trailing.')) {
        $zipPath = Join-Path $env:TEMP 'attack.zip'
        $archive = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
        try { [void]$archive.CreateEntry($entryName) } finally { $archive.Dispose() }
        $rejected = $false
        try { Expand-SafeArchive $zipPath (Join-Path $env:TEMP 'extracted') } catch { $rejected = $true }
        Assert $rejected "Unsafe archive accepted: $entryName"
        Remove-Item -LiteralPath $zipPath
    }
    Write-Host 'PASS ZipSlip, rooted paths, ADS and Windows path aliases rejected'
    $bad = [pscustomobject]@{ name = 'dotnet-runtime-win-x64.zip'; rid = 'win-x64'; url = 'https://evil.invalid/dotnet/a.zip'; hash = ('a' * 128) }
    $rejected = $false
    try { Assert-Package $bad '10.0.1' 'runtime' } catch { $rejected = $true }
    Assert $rejected 'Foreign download URL accepted'
    $bad.url = 'https://builds.dotnet.microsoft.com/dotnet/Runtime/10.0.1/dotnet-runtime-10.0.1-win-x64.zip'
    Assert-Package $bad '10.0.1' 'runtime'
    foreach ($version in @('10.0.1-preview.1', '9.0.1', '10.0.1/../evil')) {
        $rejected = $false
        try { Assert-Package $bad $version 'runtime' } catch { $rejected = $true }
        Assert $rejected "Invalid version accepted: $version"
    }
    $bad.hash = 'abc'
    $rejected = $false
    try { Assert-Package $bad '10.0.1' 'runtime' } catch { $rejected = $true }
    Assert $rejected 'Malformed SHA512 accepted'
    Write-Host 'PASS URL, stable version and SHA512 metadata validation'
    if ($Network) {
        Invoke-Installer
        Assert ($lastCode -eq 0) "Network installation failed ($lastCode): $lastOutput"
        $listing = (& (Join-Path $target 'dotnet.exe') --list-runtimes | Out-String)
        Assert ($LASTEXITCODE -eq 0) 'Private dotnet.exe failed'
        Assert ($listing -match '(?m)^Microsoft.NETCore.App 10\.0\.[0-9]+ \[') 'Missing actual core runtime 10'
        Assert ($listing -match '(?m)^Microsoft.WindowsDesktop.App 10\.0\.[0-9]+ \[') 'Missing actual desktop runtime 10'
        Write-Host $listing
        [IO.File]::WriteAllText((Join-Path $root 'runtime-list.txt'), $listing)
        Write-Host 'PASS real NETWORK private core + desktop installation'
        $before = Snapshot $root
        Invoke-Installer -Check
        Assert ($lastCode -eq 0) 'Installed CheckOnly must return 0'
        Assert ((Snapshot $root) -ceq $before) 'Installed CheckOnly modified sandbox'
        Invoke-Installer
        Assert ($lastCode -eq 0) 'Second install failed'
        Assert ((Snapshot $root) -ceq $before) 'Idempotent install changed files or timestamps'
        Write-Host 'PASS installed CheckOnly and repeat installation are no-ops'
        $environmentRoot = Join-Path $env:LOCALAPPDATA 'environment-dotnet'
        [IO.Directory]::Move($target, $environmentRoot)
        $env:DOTNET_ROOT_X64 = $environmentRoot
        $before = Snapshot $root
        Invoke-Installer -Check
        Assert ($lastCode -eq 0) 'Signed DOTNET_ROOT_X64 runtime was not detected'
        Assert ((Snapshot $root) -ceq $before) 'Environment-root CheckOnly modified files'
        [void][IO.Directory]::CreateDirectory((Join-Path $target 'shared'))
        $desktopFrom = Join-Path $environmentRoot 'shared\Microsoft.WindowsDesktop.App'
        $desktopTo = Join-Path $target 'shared\Microsoft.WindowsDesktop.App'
        [IO.Directory]::Move($desktopFrom, $desktopTo)
        $before = Snapshot $root
        Invoke-Installer -Check
        Assert ($lastCode -eq 2) 'Core and desktop split between roots must not count as usable'
        Assert ((Snapshot $root) -ceq $before) 'Split-root CheckOnly modified files'
        [IO.Directory]::Move($desktopTo, $desktopFrom)
        [IO.Directory]::Delete((Join-Path $target 'shared'))
        [IO.Directory]::Delete($target)
        [IO.Directory]::Move($environmentRoot, $target)
        $env:DOTNET_ROOT_X64 = ''
        Write-Host 'PASS signed environment-root detection and same-root requirement'
    }
    Write-Host "Sandbox and retained results: $root"
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    Stop-Transcript | Out-Null
}
