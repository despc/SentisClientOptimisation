param()
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\package\install-transaction.ps1'
$root = Join-Path 'C:\Users\user\AppData\Local\hermes\cache\scratch' ('install-transaction-test-[' + [guid]::NewGuid().ToString('N') + ']')
$oldAppData = $env:APPDATA
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Put($path, $value) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    [IO.File]::WriteAllBytes($path, [byte[]]$value)
}
function Hash($path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
function Run($action, $state, $expected = 0) {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptPath -Action $action -StatePath $state -Desktop $desktop
    Assert ($LASTEXITCODE -eq $expected) "$action returned $LASTEXITCODE; expected $expected"
}
try {
    $env:APPDATA = Join-Path $root 'AppData'
    $desktop = Join-Path $root 'Desktop [custom]'
    $pulsar = Join-Path $env:APPDATA 'Pulsar'
    $state = Join-Path $root 'state [rollback]'
    [IO.Directory]::CreateDirectory($desktop) | Out-Null
    $original = @{}
    foreach ($relative in @('Legacy.exe.config', 'Legacy.exe.config.bak', 'Legacy.exe.config.meta', 'Interim.runtimeconfig.json', 'Interim.runtimeconfig.json.bak', 'SentisClientOptimisation.ico', 'SentisClientOptimisation.ico.meta', 'Legacy\Local\SentisClientOptimisation.dll', 'Legacy\Profiles\Current.xml', 'Legacy\Profiles\Current.xml.bak', 'Interim\Profiles\Current.xml', 'Interim\Profiles\Current.xml.bak')) {
        $path = Join-Path $pulsar $relative
        Put $path @(0, 255, 13, 10, 128, 42)
        $original[$path] = Hash $path
    }
    $shortcut = Join-Path $desktop 'Space Engineers (Pulsar).lnk'
    Put $shortcut @(255, 0, 12)
    $original[$shortcut] = Hash $shortcut
    $unrelated = @{}
    foreach ($relative in @('other.txt', 'Legacy.exe.other', 'Interim.runtimeconfig.other', 'Legacy\Local\Other.dll', 'Legacy\Profiles\Other.xml', 'Pulsar.exe', 'dotnet\runtime.bin')) {
        $path = Join-Path $pulsar $relative
        Put $path @(8, 9, 10)
        $unrelated[$path] = Hash $path
    }
    Run Begin $state
    Assert (Test-Path -LiteralPath (Join-Path $state 'manifest.json')) 'Begin must persist manifest'
    foreach ($path in @($original.Keys)) { Put $path @(1, 2, 3) }
    [IO.File]::Delete((Join-Path $pulsar 'Legacy.exe.config.bak'))
    [IO.File]::Delete((Join-Path $pulsar 'Legacy\Profiles\Current.xml'))
    $new = @('Legacy.exe.config.newmeta', 'Interim.runtimeconfig.json.newmeta', 'SentisClientOptimisation.new.meta', 'Interim\Local\SentisClientOptimisation.dll') | ForEach-Object { Join-Path $pulsar $_ }
    $new += Join-Path $desktop 'Space Engineers (Pulsar, GC).cmd'
    foreach ($path in $new) { Put $path @(4, 5, 6) }
    $lateOther = Join-Path $pulsar 'new-unrelated.txt'
    Put $lateOther @(99)
    Run Rollback $state
    foreach ($path in $original.Keys) { Assert ((Hash $path) -eq $original[$path]) "Not restored: $path" }
    foreach ($path in $unrelated.Keys) { Assert ((Hash $path) -eq $unrelated[$path]) "Unrelated changed: $path" }
    foreach ($path in $new) { Assert (-not (Test-Path -LiteralPath $path)) "New owned file survived: $path" }
    Assert (Test-Path -LiteralPath $lateOther) 'New unrelated file removed'
    Assert (-not (Test-Path -LiteralPath (Join-Path $pulsar 'Interim\Local'))) 'New empty Local survived'
    Write-Output 'PASS rollback exact bytes, absence, metadata, unrelated files, literal brackets, empty directories'
    $state = Join-Path $root 'state [commit]'
    Run Begin $state
    Put $shortcut @(77, 66)
    $committedHash = Hash $shortcut
    Run Commit $state
    Assert (-not (Test-Path -LiteralPath $state)) 'Commit must delete its state'
    Assert ((Hash $shortcut) -eq $committedHash) 'Commit undid installation'
    Write-Output 'PASS Commit deletes state without undoing installation'
    $state = Join-Path $root 'state [reparse]'
    $outside = Join-Path $root 'outside'
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    $local = Join-Path $pulsar 'Interim\Local'
    & cmd.exe /d /c "mklink /J `"$local`" `"$outside`"" | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Junction fixture creation failed'
    try {
        Run Begin $state 1
        Assert (-not (Test-Path -LiteralPath (Join-Path $state 'manifest.json'))) 'Unsafe Begin wrote manifest'
    } finally { [IO.Directory]::Delete($local) }
    Write-Output 'PASS reparse-point rejection'
    $state = Join-Path $root 'state [retry]'
    Run Begin $state
    Put $shortcut @(33)
    $partialHash = Hash $shortcut
    & cmd.exe /d /c "mklink /J `"$local`" `"$outside`"" | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Junction fixture creation failed'
    try {
        Run Rollback $state 1
        Assert ((Hash $shortcut) -eq $partialHash) 'Unsafe rollback made partial changes'
        Assert (Test-Path -LiteralPath (Join-Path $state 'manifest.json')) 'Failed rollback lost recovery state'
    } finally { [IO.Directory]::Delete($local) }
    Run Rollback $state
    Assert ((Hash $shortcut) -eq $committedHash) 'Retry did not restore snapshot'
    Write-Output 'PASS rollback rejects injected reparse before writes; recovery retry succeeds'
    $env:APPDATA = Join-Path $root 'Initially absent AppData'
    $pulsar = Join-Path $env:APPDATA 'Pulsar'
    $desktop = Join-Path $root 'Initially absent Desktop'
    $state = Join-Path $root 'state [absent]'
    [IO.Directory]::CreateDirectory($state) | Out-Null
    Run Begin $state
    foreach ($relative in @('Legacy.exe.config', 'Interim.runtimeconfig.json', 'Legacy\Local\SentisClientOptimisation.dll', 'Legacy\Profiles\Current.xml.bak', 'Interim\Local\SentisClientOptimisation.dll', 'Interim\Profiles\Current.xml')) {
        Put (Join-Path $pulsar $relative) @(22)
    }
    $retained = Join-Path $pulsar 'Legacy\Local\unrelated.dll'
    Put $retained @(11)
    Put (Join-Path $desktop 'Space Engineers (Pulsar, GC).cmd') @(44)
    Run Rollback $state
    Assert (Test-Path -LiteralPath $retained) 'Nonempty newly-created Local must survive'
    Assert (-not (Test-Path -LiteralPath (Join-Path $pulsar 'Interim'))) 'Empty new edition directory survived'
    Assert (-not (Test-Path -LiteralPath $desktop)) 'Empty new Desktop survived'
    Assert (-not (Test-Path -LiteralPath (Join-Path $pulsar 'Legacy.exe.config'))) 'Absent config was not restored to absence'
    Assert (-not (Test-Path -LiteralPath (Join-Path $pulsar 'Interim.runtimeconfig.json'))) 'Absent runtime config survived'
    Write-Output 'PASS initially absent targets; preserve new nonempty directory and unrelated contents'
    Run Begin ($root.Substring(2) + '\drive-relative') 1
    Write-Output 'PASS drive-relative StatePath rejected'
} finally {
    $env:APPDATA = $oldAppData
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
