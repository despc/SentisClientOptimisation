<#
Non-interactive portable bootstrap; consent is handled by the calling EXE installer.
Never launches Legacy.exe or the game. Exit codes: 0 success/no-op, 1 failure.
-ArchivePath bypasses GitHub only for a trusted local/offline archive.
#>
[CmdletBinding()]
param([string]$ArchivePath, [ValidateSet('Legacy', 'Interim')][string]$Runtime = 'Legacy', [switch]$ReportProgress)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$ProgressPreference = 'SilentlyContinue'
$work = $null
$createdFiles = New-Object 'System.Collections.Generic.List[string]'
$createdDirs = New-Object 'System.Collections.Generic.List[string]'
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
function Assert-NoReparse([string]$path) {
    $cursor = [IO.Path]::GetFullPath($path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point is not allowed: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Ensure-TargetDirectory([string]$path) {
    Assert-NoReparse $path
    if ([IO.Directory]::Exists($path)) { return }
    if ([IO.File]::Exists($path)) { throw "A file blocks directory: $path" }
    $parent = [IO.Path]::GetDirectoryName($path)
    if ($parent) { Ensure-TargetDirectory $parent }
    [void][IO.Directory]::CreateDirectory($path)
    $createdDirs.Add($path)
}
function Copy-NewFile([string]$source, [string]$destination) {
    Assert-NoReparse $destination
    if ([IO.File]::Exists($destination)) { return }
    Ensure-TargetDirectory ([IO.Path]::GetDirectoryName($destination))
    $output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $createdFiles.Add($destination)
    try {
        $input = [IO.File]::OpenRead($source)
        try { $input.CopyTo($output) } finally { $input.Dispose() }
    } finally { $output.Dispose() }
}
function Select-PulsarAsset($release) {
    if ($release.draft -ne $false -or $release.prerelease -ne $false) { throw 'Latest release is not stable.' }
    $matches = @($release.assets | Where-Object { $_.name -cmatch '^Pulsar[^/\\:]*-win-x64\.zip$' })
    if ($matches.Count -ne 1) { throw 'Expected exactly one Pulsar*-win-x64.zip release asset.' }
    $asset = $matches[0]
    $url = [string]$asset.browser_download_url
    $uri = $null
    if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.Host -ine 'github.com' -or $uri.Port -ne 443 -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $url -cnotmatch '^https://github\.com/SpaceGT/Pulsar/releases/download/[^/\\?#]+/Pulsar[^/\\?#]*-win-x64\.zip$' -or
        [Uri]::UnescapeDataString(($uri.AbsolutePath.Split('/')[-1])) -cne $asset.name -or
        $url -match '(?i)%2f|%5c|%2e') { throw 'Unsafe Pulsar asset download URL.' }
    if ([long]$asset.size -le 0 -or [long]$asset.size -gt 134217728) { throw 'Invalid release asset size.' }
    if ($asset.PSObject.Properties['digest'] -and $asset.digest -and $asset.digest -cnotmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Invalid GitHub SHA256 digest.' }
    return $asset
}
function Assert-AssetIntegrity($asset, [string]$path) {
    if ((Get-Item -LiteralPath $path).Length -ne [long]$asset.size) { throw 'Downloaded asset size does not match GitHub metadata.' }
    if ($asset.PSObject.Properties['digest'] -and $asset.digest) {
        if ($asset.digest -cnotmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Invalid GitHub SHA256 digest.' }
        $expectedHash = ([string]$asset.digest).Substring(7)
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actualHash -ine $expectedHash) { throw 'GitHub asset SHA256 digest mismatch.' }
    }
}
function Receive-HttpsFile([string]$url, [string]$path, [long]$limit, [switch]$Api) {
    $phase = 'download-pulsar'
    if ($Api) { $phase = 'metadata-pulsar' }
    Report-InstallProgress $phase 0 0 -Force
    $uri = [Uri]$url
    for ($redirect = 0; $redirect -le 5; $redirect++) {
        if ($uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
            ($Api -and $uri.AbsoluteUri -cne 'https://api.github.com/repos/SpaceGT/Pulsar/releases/latest') -or
            (-not $Api -and $uri.Host -notin @('github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'))) { throw 'Unsafe HTTPS redirect.' }
        $request = [Net.HttpWebRequest]::Create($uri)
        $request.UserAgent = 'SentisClientOptimisation-Installer/1.0'
        $request.Timeout = 120000
        $request.ReadWriteTimeout = 120000
        $request.AllowAutoRedirect = $false
        if ($Api) { $request.Accept = 'application/vnd.github+json'; $request.Headers.Add('X-GitHub-Api-Version', '2022-11-28') }
        $response = $request.GetResponse()
        try {
            $status = [int]$response.StatusCode
            if ($status -in @(301, 302, 303, 307, 308)) {
                if ($redirect -eq 5) { throw 'Too many HTTPS redirects.' }
                $location = $response.Headers['Location']
                if (-not $location) { throw 'Missing redirect location.' }
                $uri = New-Object Uri ($uri, $location)
                continue
            }
            if ($status -ne 200) { throw "Unexpected HTTP status: $status" }
            if ($response.ContentLength -gt $limit) { throw 'Download exceeds size limit.' }
            $downloadTotal = [long]0
            if ($response.ContentLength -ge 0) { $downloadTotal = $response.ContentLength }
            Report-InstallProgress $phase 0 $downloadTotal -Force
            $input = $response.GetResponseStream()
            try {
                $output = [IO.File]::Open($path, [IO.FileMode]::CreateNew)
                try {
                    $buffer = New-Object byte[] 65536
                    $received = [long]0
                    $clock = [Diagnostics.Stopwatch]::StartNew()
                    while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $received += $read
                        if ($received -gt $limit -or $clock.Elapsed.TotalSeconds -gt 180) { throw 'Download exceeds size/time limit.' }
                        $output.Write($buffer, 0, $read)
                        Report-InstallProgress $phase $received $downloadTotal
                    }
                    if ($response.ContentLength -ge 0 -and $received -ne $response.ContentLength) { throw 'Truncated HTTP download.' }
                    Report-InstallProgress $phase $received $downloadTotal -Force
                } finally { $output.Dispose() }
            } finally { $input.Dispose() }
            return
        } finally { $response.Dispose() }
    }
    throw 'Download did not complete.'
}
function Assert-Configuration([string]$path) {
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($path, $settings)
    try {
        $doc = New-Object Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($reader)
        if ($doc.DocumentElement.Name -cne 'configuration') { throw 'Legacy.exe.config root must be configuration.' }
    } finally { $reader.Dispose() }
}
try {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) { throw 'APPDATA is not set.' }
    if (-not [IO.Path]::IsPathRooted($env:APPDATA)) { throw 'APPDATA must be an absolute path.' }
    $target = [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'Pulsar'))
    Assert-NoReparse $target
    $selectedExe = $Runtime + '.exe'
    Assert-NoReparse (Join-Path $target $selectedExe)
    if ([IO.File]::Exists((Join-Path $target $selectedExe))) { Report-InstallProgress 'done' 0 0 -Force; exit 0 }
    $tempRoot = [IO.Path]::GetTempPath()
    Assert-NoReparse $tempRoot
    $work = Join-Path $tempRoot ('pulsar-bootstrap-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($work)
    $stage = Join-Path $work 'staging'
    [void][IO.Directory]::CreateDirectory($stage)
    $asset = $null
    if (-not $ArchivePath) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $metadataPath = Join-Path $work 'release.json'
        Receive-HttpsFile 'https://api.github.com/repos/SpaceGT/Pulsar/releases/latest' $metadataPath 4194304 -Api
        $release = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
        $asset = Select-PulsarAsset $release
        $ArchivePath = Join-Path $work 'Pulsar-win-x64.zip'
        Receive-HttpsFile $asset.browser_download_url $ArchivePath 134217728
    }
    Report-InstallProgress 'verify-pulsar' 0 0 -Force
    $ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
    Assert-NoReparse $ArchivePath
    if (-not [IO.File]::Exists($ArchivePath)) { throw 'Archive does not exist.' }
    if ((Get-Item -LiteralPath $ArchivePath).Length -gt 134217728) { throw 'Archive exceeds 128 MiB.' }
    if ($asset) {
        Assert-AssetIntegrity $asset $ArchivePath
        Write-Output ('Downloaded release asset: ' + $asset.name)
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($zip.Entries.Count -gt 10000) { throw 'Too many archive entries.' }
        $extracted = [long]0
        $entryCount = [long]$zip.Entries.Count
        Report-InstallProgress 'extract-pulsar' 0 $entryCount -Force
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $total = [long]0
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or [IO.Path]::IsPathRooted($name)) { throw "Absolute/empty archive path: $name" }
            $parts = $name.TrimEnd('/').Split('/')
            foreach ($part in $parts) {
                if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part -match '[\x00-\x1f:<>"|?*]' -or $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw "Unsafe archive path: $name" }
            }
            if (-not $seen.Add(($parts -join '/'))) { throw "Duplicate archive path: $name" }
            $attributes = [long]$entry.ExternalAttributes -band 0xffffffffL
            $unixType = ($attributes -shr 16) -band 0xf000
            if (($attributes -band 0x400) -ne 0 -or $unixType -notin @(0, 0x8000, 0x4000)) { throw "Link/special archive entry: $name" }
            $total += $entry.Length
            if ($entry.Length -gt 134217728 -or $total -gt 536870912) { throw 'Expanded archive exceeds limits.' }
            $destination = [IO.Path]::GetFullPath((Join-Path $stage ($parts -join '\')))
            if (-not $destination.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive path escaped staging.' }
            if ($name.EndsWith('/')) {
                [void][IO.Directory]::CreateDirectory($destination)
                $extracted++
                Report-InstallProgress 'extract-pulsar' $extracted $entryCount
                continue
            }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            $source = $entry.Open()
            try {
                $output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew)
                try {
                    $buffer = New-Object byte[] 65536
                    $written = [long]0
                    while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $written += $read
                        if ($written -gt $entry.Length) { throw 'Archive entry exceeds declared size.' }
                        $output.Write($buffer, 0, $read)
                    }
                    if ($written -ne $entry.Length) { throw 'Truncated archive entry.' }
                } finally { $output.Dispose() }
            } finally { $source.Dispose() }
            $extracted++
            Report-InstallProgress 'extract-pulsar' $extracted $entryCount
        }
        Report-InstallProgress 'extract-pulsar' $extracted $entryCount -Force
    } finally { $zip.Dispose() }
    $required = @('Legacy.exe', 'Legacy.exe.config', 'Interim.exe', 'Interim.dll', 'Interim.runtimeconfig.json', 'Libraries/Interim/0Harmony.dll', 'Libraries\Compiler\Compiler.exe', 'Libraries\Compiler\Compiler.exe.config', 'Libraries\Interface\Interface.exe', 'Libraries\Interface\Interface.exe.config')
    # Actual non-framework dependencies shipped in the win-x64 Legacy distribution.
    $legacyDependencies = @('0Harmony', 'DiscordRPC', 'FuzzySharp', 'Gameloop.Vdf', 'McMaster.Extensions.CommandLineUtils', 'Microsoft.Bcl.AsyncInterfaces', 'Microsoft.Extensions.FileProviders.Abstractions', 'Microsoft.Extensions.FileSystemGlobbing', 'Microsoft.Extensions.Primitives', 'Microsoft.Win32.Registry', 'Mono.Cecil', 'Newtonsoft.Json', 'NLog', 'NuGet.Commands', 'NuGet.Common', 'NuGet.Configuration', 'NuGet.DependencyResolver.Core', 'NuGet.Frameworks', 'NuGet.LibraryModel', 'NuGet.Packaging', 'NuGet.ProjectModel', 'NuGet.Protocol', 'NuGet.Versioning', 'protobuf-net', 'Pulsar.Protocol', 'Pulsar.Shared', 'SharpCompress', 'steam_api64', 'Steamworks.NET', 'System.Buffers', 'System.Memory', 'System.Numerics.Vectors', 'System.Runtime.CompilerServices.Unsafe', 'System.Threading.Tasks.Extensions')
    foreach ($name in $legacyDependencies) { $required += 'Libraries\Legacy\' + $name + '.dll' }
    foreach ($relative in $required) {
        $payload = Join-Path $stage $relative
        if (-not [IO.File]::Exists($payload) -or (Get-Item -LiteralPath $payload).Length -eq 0) { throw "Missing/empty release payload: $relative" }
    }
    Assert-Configuration (Join-Path $stage 'Legacy.exe.config')
    if ([IO.File]::Exists((Join-Path $target 'Legacy.exe.config'))) {
        Assert-NoReparse (Join-Path $target 'Legacy.exe.config')
        Assert-Configuration (Join-Path $target 'Legacy.exe.config')
    }
    $profileStage = Join-Path $stage ($Runtime + '/Profiles/Current.xml')
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($profileStage))
    [IO.File]::WriteAllText($profileStage, '<?xml version="1.0" encoding="utf-8"?><Profile><Name>Current</Name><GitHub/><DevFolder/><Local/><Mods/></Profile>', (New-Object Text.UTF8Encoding($false)))
    # Preflight all destinations before writes. Copy Legacy.exe last as completion marker.
    $files = @(Get-ChildItem -LiteralPath $stage -File -Recurse)
    foreach ($file in $files) {
        $destination = Join-Path $target $file.FullName.Substring($stage.Length + 1)
        Assert-NoReparse $destination
        if ([IO.Directory]::Exists($destination)) { throw "Directory blocks payload: $destination" }
    }
    $copied = [long]0
    $fileCount = [long]$files.Count
    Report-InstallProgress 'copy-pulsar' 0 $fileCount -Force
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($stage.Length + 1)
        if ($relative -ieq $selectedExe) { continue }
        Copy-NewFile $file.FullName (Join-Path $target $relative)
        $copied++
        Report-InstallProgress 'copy-pulsar' $copied $fileCount
    }
    Copy-NewFile (Join-Path $stage $selectedExe) (Join-Path $target $selectedExe)
    $copied++
    Report-InstallProgress 'copy-pulsar' $copied $fileCount -Force
    Report-InstallProgress 'done' 0 0 -Force
    Write-Output "Pulsar installed into $target"
}
catch {
    $failure = $_.Exception.Message
    for ($i = $createdFiles.Count - 1; $i -ge 0; $i--) {
        try { Assert-NoReparse $createdFiles[$i]; [IO.File]::Delete($createdFiles[$i]) } catch { [Console]::Error.WriteLine('Rollback file failed: ' + $_.Exception.Message) }
    }
    for ($i = $createdDirs.Count - 1; $i -ge 0; $i--) {
        try { Assert-NoReparse $createdDirs[$i]; [IO.Directory]::Delete($createdDirs[$i], $false) } catch { [Console]::Error.WriteLine('Rollback directory retained: ' + $_.Exception.Message) }
    }
    [Console]::Error.WriteLine('Pulsar bootstrap failed: ' + $failure)
    exit 1
}
finally {
    if ($work -and [IO.Directory]::Exists($work)) {
        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop } catch { [Console]::Error.WriteLine('Temporary cleanup failed: ' + $_.Exception.Message) }
    }
}
exit 0
