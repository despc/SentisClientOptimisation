#requires -Version 5.1
[CmdletBinding()]
param([switch]$CheckOnly, [switch]$ReportProgress)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
function Report-InstallProgress {
    param(
        [ValidateSet('metadata-pulsar', 'download-pulsar', 'verify-pulsar', 'extract-pulsar', 'copy-pulsar', 'detect-dotnet', 'metadata-dotnet', 'download-runtime', 'verify-runtime', 'extract-runtime', 'download-windowsdesktop', 'verify-windowsdesktop', 'extract-windowsdesktop', 'done')]
        [string]$Phase,
        [long]$Current = 0,
        [long]$Total = 0,
        [switch]$Force
    )
    # Helpers are also imported alone by security tests, with StrictMode enabled.
    $enabled = Get-Variable -Name ReportProgress -ErrorAction SilentlyContinue
    if (-not $enabled -or -not $enabled.Value) { return }
    $state = Get-Variable -Name InstallProgressState -Scope Script -ErrorAction SilentlyContinue
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    if (-not $Force -and $state -and $state.Value.Phase -ceq $Phase -and
        (($now - $state.Value.Tick) / [double][Diagnostics.Stopwatch]::Frequency) -lt 0.2) { return }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    [Console]::Out.WriteLine('SCO_PROGRESS|' + $Phase + '|' + $Current.ToString($culture) + '|' + $Total.ToString($culture))
    [Console]::Out.Flush()
    $script:InstallProgressState = [pscustomobject]@{ Phase = $Phase; Tick = $now }
}
function Test-MicrosoftBinary([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $false }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    return ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match '(^|,\s*)O=Microsoft Corporation(,|$)')
}
function Test-Runtime([string]$Root) {
    if (-not $Root -or -not [IO.Directory]::Exists($Root)) { return $false }
    $exe = Join-Path $Root 'dotnet.exe'
    if (-not (Test-MicrosoftBinary $exe)) { return $false }
    # The signed host loads native libraries before answering --list-runtimes.
    foreach ($pattern in @('host\fxr\*\hostfxr.dll', 'shared\Microsoft.NETCore.App\*\hostpolicy.dll', 'shared\Microsoft.NETCore.App\*\coreclr.dll')) {
        foreach ($file in @(Get-ChildItem -Path (Join-Path $Root $pattern) -File -ErrorAction SilentlyContinue)) {
            if (-not (Test-MicrosoftBinary $file.FullName)) { return $false }
        }
    }
    $lines = @(& $exe --list-runtimes 2>$null)
    if ($LASTEXITCODE -ne 0) { return $false }
    $core = $false; $desktop = $false
    foreach ($line in $lines) {
        if ($line -match '^Microsoft\.(NETCore|WindowsDesktop)\.App 10\.0\.[0-9]+ \[(.+)\]$') {
            $expected = Join-Path $Root ('shared\Microsoft.' + $Matches[1] + '.App')
            if ([IO.Path]::GetFullPath($Matches[2]).TrimEnd('\') -ieq [IO.Path]::GetFullPath($expected).TrimEnd('\')) {
                if ($Matches[1] -eq 'NETCore') { $core = $true } else { $desktop = $true }
            }
        }
    }
    return ($core -and $desktop)
}
function Assert-OfficialUrl([string]$Url) {
    if ($Url -cnotmatch '^https://builds\.dotnet\.microsoft\.com/dotnet/[A-Za-z0-9._/-]+$' -or
        $Url -match '(^|/)\.\.?(/|$)') { throw "Untrusted download URL: $Url" }
}
function Assert-Package($File, [string]$Version, [string]$Kind) {
    if ($Version -cnotmatch '^10\.0\.(0|[1-9][0-9]*)$') { throw 'Not a stable numeric .NET 10 version.' }
    $name = 'dotnet-runtime-win-x64.zip'; $folder = 'Runtime'; $prefix = 'dotnet-runtime'
    if ($Kind -eq 'windowsdesktop') { $name = 'windowsdesktop-runtime-win-x64.zip'; $folder = 'WindowsDesktop'; $prefix = 'windowsdesktop-runtime' }
    elseif ($Kind -ne 'runtime') { throw 'Invalid package kind.' }
    if ($File.name -cne $name -or $File.rid -cne 'win-x64' -or $File.hash -notmatch '^[a-fA-F0-9]{128}$') { throw 'Invalid x64 ZIP metadata or SHA512.' }
    Assert-OfficialUrl $File.url
    $expected = "https://builds.dotnet.microsoft.com/dotnet/$folder/$Version/$prefix-$Version-win-x64.zip"
    if ($File.url -cne $expected) { throw 'Package URL does not match runtime version.' }
}
function Receive-OfficialFile([string]$Url, [string]$Path, [string]$Phase = 'metadata-dotnet') {
    Report-InstallProgress $Phase 0 0 -Force
    Assert-OfficialUrl $Url
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.AllowAutoRedirect = $false
    $request.Timeout = 60000; $request.ReadWriteTimeout = 300000
    $response = $null; $inputStream = $null; $outputStream = $null
    try {
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200) { throw "Unexpected HTTP status: $($response.StatusCode)" }
        $downloadTotal = [long]0
        if ($response.ContentLength -ge 0) { $downloadTotal = $response.ContentLength }
        Report-InstallProgress $Phase 0 $downloadTotal -Force
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
        $buffer = New-Object byte[] 65536
        $received = [long]0
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $received += $read
            Report-InstallProgress $Phase $received $downloadTotal
        }
        if ($response.ContentLength -ge 0 -and $received -ne $response.ContentLength) { throw 'Truncated HTTP download.' }
        Report-InstallProgress $Phase $received $downloadTotal -Force
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point refused: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Expand-SafeArchive([string]$ZipPath, [string]$Destination, [string]$Phase = 'extract-runtime') {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $base = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    Assert-NoReparse $Destination
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $extracted = [long]0
        $entryCount = [long]$zip.Entries.Count
        Report-InstallProgress $Phase 0 $entryCount -Force
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if (-not $name -or [IO.Path]::IsPathRooted($name)) { throw 'Unsafe archive path.' }
            $parts = $name.TrimEnd('\').Split('\')
            foreach ($part in $parts) {
                if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part -match '[<>:"|?*\x00-\x1f]' -or
                    $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw 'Unsafe archive path.' }
            }
            $unixType = ($entry.ExternalAttributes -shr 16) -band 61440
            if (($unixType -ne 0 -and $unixType -ne 32768 -and $unixType -ne 16384) -or ($entry.ExternalAttributes -band 1024)) { throw 'Link/special archive entry refused.' }
            $path = [IO.Path]::GetFullPath((Join-Path $Destination $name))
            if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive path escaped staging.' }
            Assert-NoReparse $path
            if ($name.EndsWith('\')) {
                [void][IO.Directory]::CreateDirectory($path)
                $extracted++
                Report-InstallProgress $Phase $extracted $entryCount
                continue
            }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            # Both official archives can include identical top-level license files.
            if ([IO.File]::Exists($path)) {
                $stream = $entry.Open(); $sha = [Security.Cryptography.SHA512]::Create()
                try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') } finally { $sha.Dispose(); $stream.Dispose() }
                if ($hash -ne (Get-FileHash -LiteralPath $path -Algorithm SHA512).Hash) { throw "Conflicting archive file: $name" }
                $extracted++
                Report-InstallProgress $Phase $extracted $entryCount
                continue
            }
            $source = $entry.Open(); $output = $null
            try { $output = [IO.File]::Open($path, [IO.FileMode]::CreateNew); $source.CopyTo($output) }
            finally { if ($output) { $output.Dispose() }; $source.Dispose() }
            $extracted++
            Report-InstallProgress $Phase $extracted $entryCount
        }
        Report-InstallProgress $Phase $extracted $entryCount -Force
    } finally { $zip.Dispose() }
}
$work = $null
$published = $false
$createdDirectories = New-Object 'Collections.Generic.List[string]'
try {
    Report-InstallProgress 'detect-dotnet' 0 0 -Force
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is missing.' }
    $target = Join-Path $env:LOCALAPPDATA 'SentisClientOptimisation\dotnet'
    $roots = @($target, $env:DOTNET_ROOT_X64, $env:DOTNET_ROOT)
    if ($env:ProgramW6432) { $roots += Join-Path $env:ProgramW6432 'dotnet' }
    if ($env:ProgramFiles) { $roots += Join-Path $env:ProgramFiles 'dotnet' }
    foreach ($root in @($roots | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Runtime $root) { Write-Output "Usable .NET 10 core and desktop: $root"; Report-InstallProgress 'done' 0 0 -Force; exit 0 }
    }
    if ($CheckOnly) { exit 2 }
    # Never merge into or overwrite a pre-existing, unusable installation.
    Assert-NoReparse $target
    if (Test-Path -LiteralPath $target) { throw "Private runtime path already exists but is unusable; left unchanged: $target" }
    $parent = Split-Path $target -Parent
    $missing = New-Object 'Collections.Generic.List[string]'
    $cursor = $parent
    while (-not (Test-Path -LiteralPath $cursor)) { $missing.Add($cursor); $cursor = Split-Path $cursor -Parent }
    for ($i = $missing.Count - 1; $i -ge 0; $i--) {
        [void][IO.Directory]::CreateDirectory($missing[$i]); $createdDirectories.Add($missing[$i])
    }
    # Same-volume staging permits atomic publication and never touches global .NET.
    $work = Join-Path $parent ('.dotnet-stage-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($work)
    $stage = Join-Path $work 'runtime'
    [void][IO.Directory]::CreateDirectory($stage)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $metadataPath = Join-Path $work 'releases.json'
    Receive-OfficialFile 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json' $metadataPath
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if ($metadata.'channel-version' -cne '10.0') { throw 'Unexpected release channel.' }
    $releases = @($metadata.releases | Where-Object {
        $_.'release-version' -cmatch '^10\.0\.(0|[1-9][0-9]*)$' -and
        $_.runtime.version -cmatch '^10\.0\.(0|[1-9][0-9]*)$' -and
        $_.windowsdesktop.version -cmatch '^10\.0\.(0|[1-9][0-9]*)$'
    } | Sort-Object { [version]$_.runtime.version } -Descending)
    if ($releases.Count -eq 0) { throw 'No stable .NET 10 release found.' }
    $release = $releases[0]
    foreach ($kind in @('runtime', 'windowsdesktop')) {
        $component = $release.$kind
        $packageName = 'dotnet-runtime-win-x64.zip'
        if ($kind -eq 'windowsdesktop') { $packageName = 'windowsdesktop-runtime-win-x64.zip' }
        $files = @($component.files | Where-Object { $_.name -ceq $packageName -and $_.rid -ceq 'win-x64' })
        if ($files.Count -ne 1) { throw "Expected exactly one $packageName." }
        $file = $files[0]
        Assert-Package $file $component.version $kind
        $archivePath = Join-Path $work $packageName
        Write-Output "Downloading $kind $($component.version) (win-x64)."
        Receive-OfficialFile $file.url $archivePath -Phase ('download-' + $kind)
        Report-InstallProgress ('verify-' + $kind) 0 0 -Force
        if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA512).Hash -ine $file.hash) { throw "SHA512 mismatch: $packageName" }
        Write-Output "SHA512 verified: $packageName"
        Expand-SafeArchive $archivePath $stage -Phase ('extract-' + $kind)
    }
    if (-not (Test-Runtime $stage)) { throw 'Staged .NET 10 core + desktop verification failed.' }
    Assert-NoReparse $target
    [IO.Directory]::Move($stage, $target)
    $published = $true
    if (-not (Test-Runtime $target)) { throw 'Published runtime verification failed.' }
    Write-Output "Installed private .NET 10 core and desktop: $target"
    Report-InstallProgress 'done' 0 0 -Force
} catch {
    if ($published) {
        # Only this invocation's atomically published tree is eligible for rollback.
        try { Assert-NoReparse $target; Remove-Item -LiteralPath $target -Recurse -Force } catch { Write-Warning "Rollback failed: $_" }
    }
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
} finally {
    if ($work -and (Test-Path -LiteralPath $work)) {
        try { Assert-NoReparse $work; Remove-Item -LiteralPath $work -Recurse -Force } catch { Write-Warning "Staging cleanup failed: $_" }
    }
    for ($i = $createdDirectories.Count - 1; $i -ge 0; $i--) {
        try { [IO.Directory]::Delete($createdDirectories[$i], $false) } catch { } # Never delete other files.
    }
}
exit 0
