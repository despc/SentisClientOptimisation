[CmdletBinding()]
param(
    [string]$ArchivePath,
    [string]$ScratchRoot = (Join-Path $env:LOCALAPPDATA 'hermes/cache/scratch'),
    [switch]$Network,
    [switch]$HelpersOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
$repo = Split-Path $PSScriptRoot -Parent
foreach ($name in @('pulsar', 'dotnet')) {
    & {
        $path = Join-Path $repo "package/install-$name.ps1"
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        Assert (@($errors).Count -eq 0) "$name parse failed"
        Assert (@($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ReportProgress' }).Count -eq 1) "$name missing -ReportProgress switch"
        $helper = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Report-InstallProgress' }, $true)
        Assert ($null -ne $helper) "$name missing protocol helper"
        . ([scriptblock]::Create($helper.Extent.Text))
        $writer = New-Object IO.StringWriter
        $oldOut = [Console]::Out
        $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Console]::SetOut($writer)
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('ar-SA')
            Report-InstallProgress 'download-runtime' 0 0 -Force
            Assert ($writer.ToString().Length -eq 0) 'Undefined ReportProgress must be quiet under StrictMode'
            $ReportProgress = $false
            Report-InstallProgress 'download-runtime' 0 0 -Force
            Assert ($writer.ToString().Length -eq 0) 'Default mode emitted progress'
            $ReportProgress = $true
            Report-InstallProgress 'download-runtime' 0 0
            Report-InstallProgress 'download-runtime' 1 0
            Report-InstallProgress 'download-runtime' 2 0
            Start-Sleep -Milliseconds 260
            Report-InstallProgress 'download-runtime' 12345678901 0
            Report-InstallProgress 'download-runtime' 12345678902 0 -Force
            Report-InstallProgress 'verify-runtime' 0 0
            $lines = @($writer.ToString().TrimEnd() -split '\r?\n')
            Assert ($lines.Count -eq 4) "Throttle/start/final failed: $($writer.ToString())"
            Assert ($lines[0] -ceq 'SCO_PROGRESS|download-runtime|0|0') 'Wrong start protocol'
            Assert ($lines[1] -ceq 'SCO_PROGRESS|download-runtime|12345678901|0') 'Counts must be invariant Int64 decimal'
            Assert ($lines[2] -ceq 'SCO_PROGRESS|download-runtime|12345678902|0') 'Forced final missing'
            Assert ($lines[3] -ceq 'SCO_PROGRESS|verify-runtime|0|0') 'Phase change must bypass throttle'
        } finally {
            [Console]::SetOut($oldOut)
            [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture
            $writer.Dispose()
        }
        Write-Host "PASS $name AST-only helper: undefined/default quiet, invariant Int64, throttle, phase start and forced final"
    }
}
if ($HelpersOnly) { return }
$root = Join-Path $ScratchRoot ('progress-tests-' + [guid]::NewGuid().ToString('N'))
$names = @('APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP', 'DOTNET_ROOT', 'DOTNET_ROOT_X64')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$ps = Join-Path $PSHOME 'powershell.exe'
function Reset-Sandbox {
    $caseRoot = Join-Path $root ([guid]::NewGuid().ToString('N'))
    foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP')) {
        $value = Join-Path $caseRoot $name
        [void][IO.Directory]::CreateDirectory($value)
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
    $env:DOTNET_ROOT = ''; $env:DOTNET_ROOT_X64 = ''
}
function Invoke-Bootstrap([string]$Name, [string[]]$Arguments) {
    $script:events = New-Object 'Collections.Generic.List[object]'
    $script:output = New-Object 'Collections.Generic.List[string]'
    $ErrorActionPreference = 'Continue'
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repo "package/install-$Name.ps1") @Arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        $output.Add($line)
        if ($line.StartsWith('SCO_PROGRESS|')) {
            if ($line -cnotmatch '^SCO_PROGRESS\|([a-z-]+)\|([0-9]+)\|([0-9]+)$') { throw "Malformed protocol: $line" }
            $events.Add([pscustomobject]@{ Phase = $Matches[1]; Current = [long]$Matches[2]; Total = [long]$Matches[3] })
        }
    }
    $script:code = $LASTEXITCODE
}
function Assert-Phase([string]$Phase, [long]$ExpectedTotal) {
    $items = @($events | Where-Object { $_.Phase -ceq $Phase })
    Assert ($items.Count -ge 2) "$Phase missing start/final: $($output -join '; ')"
    Assert ($items[0].Current -eq 0) "$Phase did not start at zero"
    Assert ($items[-1].Current -eq $ExpectedTotal -and $items[-1].Total -eq $ExpectedTotal) "$Phase wrong final actual count"
    $previous = [long]0
    foreach ($item in $items) {
        Assert ($item.Current -ge $previous -and $item.Current -le $item.Total) "$Phase not monotonic/bounded"
        $previous = $item.Current
    }
}
try {
    Assert ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5) 'Run in Windows PowerShell 5.1'
    Assert ([IO.File]::Exists($ArchivePath)) "Missing actual archive: $ArchivePath"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try { $entryCount = $zip.Entries.Count } finally { $zip.Dispose() }
    Reset-Sandbox
    Invoke-Bootstrap 'pulsar' @('-ArchivePath', $ArchivePath, '-ReportProgress')
    Assert ($code -eq 0) "Offline bootstrap failed: $($output -join '; ')"
    Assert ($events.Count -gt 0) 'Offline bootstrap emitted no progress events'
    Assert (($events.Phase | Select-Object -Unique) -join ',' -ceq 'verify-pulsar,extract-pulsar,copy-pulsar,done') 'Offline phase order is incorrect'
    Assert (@($events | Where-Object { $_.Phase -eq 'verify-pulsar' -and $_.Current -eq 0 -and $_.Total -eq 0 }).Count -eq 1) 'Verification must be indeterminate'
    Assert-Phase 'extract-pulsar' $entryCount
    $fileCount = @(Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'Pulsar') -File -Recurse).Count
    Assert-Phase 'copy-pulsar' $fileCount
    Assert ($events[-1].Phase -eq 'done') 'Success missing done'
    Write-Host "PASS real offline archive: verify/extract $entryCount entries/copy $fileCount files/done"
    Invoke-Bootstrap 'pulsar' @('-ArchivePath', $ArchivePath, '-ReportProgress')
    Assert ($code -eq 0 -and $events.Count -eq 1 -and $events[0].Phase -eq 'done') 'No-op must emit only done'
    Invoke-Bootstrap 'pulsar' @('-ArchivePath', $ArchivePath)
    Assert ($code -eq 0 -and $events.Count -eq 0) 'Default no-op emitted protocol'
    Write-Host 'PASS Pulsar no-op and default quiet protocol'
    Reset-Sandbox
    Invoke-Bootstrap 'dotnet' @('-CheckOnly', '-ReportProgress')
    Assert ($code -in @(0, 2)) "Runtime detection failed: $($output -join '; ')"
    Assert ($events.Count -ge 1 -and $events[0].Phase -eq 'detect-dotnet') 'Missing runtime detection start'
    if ($code -eq 0) { Assert ($events[-1].Phase -eq 'done') 'Detected runtime missing done' }
    Invoke-Bootstrap 'dotnet' @('-CheckOnly')
    Assert ($events.Count -eq 0) 'Default runtime detection emitted protocol'
    Write-Host 'PASS actual .NET detection and default quiet protocol'
    # Exercise the real safe extractor including directory and duplicate-file branches.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'package/install-dotnet.ps1'), [ref]$tokens, [ref]$errors)
    foreach ($function in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($function.Extent.Text)) }
    $tinyZip = Join-Path $env:TEMP 'entries.zip'
    $zip = [IO.Compression.ZipFile]::Open($tinyZip, 'Create')
    try {
        [void]$zip.CreateEntry('directory/')
        $writer = New-Object IO.StreamWriter (($zip.CreateEntry('directory/file.txt')).Open())
        try { $writer.Write('real entry') } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    $ReportProgress = $true
    $writer = New-Object IO.StringWriter; $oldOut = [Console]::Out
    try {
        [Console]::SetOut($writer)
        Expand-SafeArchive $tinyZip (Join-Path $env:TEMP 'extract') -Phase 'extract-runtime'
        Expand-SafeArchive $tinyZip (Join-Path $env:TEMP 'extract') -Phase 'extract-windowsdesktop'
    } finally { [Console]::SetOut($oldOut) }
    $lines = $writer.ToString(); $writer.Dispose()
    foreach ($phase in @('extract-runtime', 'extract-windowsdesktop')) {
        Assert ($lines.Contains("SCO_PROGRESS|$phase|0|2") -and $lines.Contains("SCO_PROGRESS|$phase|2|2")) "Missing real directory/duplicate entry progress: $lines"
    }
    Write-Host 'PASS .NET safe extraction reports directories and identical duplicate entries'
    if ($Network) {
        Reset-Sandbox
        Invoke-Bootstrap 'pulsar' @('-ReportProgress')
        Assert ($code -eq 0) "Real GitHub bootstrap failed: $($output -join '; ')"
        Assert (($events.Phase | Select-Object -Unique) -join ',' -ceq 'metadata-pulsar,download-pulsar,verify-pulsar,extract-pulsar,copy-pulsar,done') 'Network phase order incorrect'
        $download = @($events | Where-Object { $_.Phase -eq 'download-pulsar' })
        Assert ($download.Count -ge 2 -and $download[-1].Current -gt 0) 'Missing real download byte counts'
        $actualBytes = $download[-1].Current
        if ($download[-1].Total -gt 0) { Assert-Phase 'download-pulsar' $actualBytes }
        else { Assert (@($download | Where-Object { $_.Total -ne 0 }).Count -eq 0) 'Unknown length must remain zero' }
        Write-Host "PASS real GitHub latest network bootstrap: $actualBytes bytes; $($download.Count) download events; total $($download[-1].Total)"
    }
    Write-Host 'All streaming progress tests passed.'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
