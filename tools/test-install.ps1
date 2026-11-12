# Integration tests: Windows PowerShell 5.1, isolated files and real shortcut COM.
param([string]$PackagePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\SentisClientOptimisation'))
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA ('hermes\cache\scratch\sco-install-[тест-日本語]-' + [Guid]::NewGuid().ToString('N'))
$originalAppData = $env:APPDATA
$originalLocalAppData = $env:LOCALAPPDATA
$originalTemp = $env:TEMP
$originalTmp = $env:TMP
$tempRoot = Join-Path (Split-Path $root -Parent) ('sco-install-temp-' + [Guid]::NewGuid().ToString('N'))
$originalPause = $env:SCO_NO_PAUSE
$script:checks = 0
function Assert($condition, [string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:checks++
}
function Snapshot([string]$path) {
    $items = @(Get-ChildItem -LiteralPath $path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($path.Length)
        if ($_.PSIsContainer) { 'D:' + $relative } else { 'F:' + $relative + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    return ($items -join "`n")
}
function Run-Script([string]$scriptName, [int]$expected = 0, [switch]$ValidateOnly, [switch]$WithoutScriptNonInteractive, [string]$Runtime) {
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:package $scriptName), '-Desktop', $script:desktop)
    if (-not $WithoutScriptNonInteractive) { $arguments += '-NonInteractive' }
    if ($ValidateOnly) { $arguments += '-ValidateOnly' }
    if ($Runtime) { $arguments += @('-Runtime', $Runtime) }
    $output = & "$PSHOME\powershell.exe" @arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    Assert ($code -eq $expected) "$scriptName exit $code (expected $expected): $output"
    if ($expected -ne 0) { Assert (-not $output.Contains('Готово')) 'failed operation never reports success' }
    return $output
}
function New-Fixture([string]$id, [bool]$withLocal = $true) {
    $script:fixture = Join-Path $root $id
    $script:package = Join-Path $fixture 'package'
    $env:APPDATA = Join-Path $fixture 'AppData'
    $env:LOCALAPPDATA = Join-Path $fixture 'LocalAppData'
    # .NET Framework csc cannot emit Add-Type output under a Unicode TEMP path.
    # Keep TEMP isolated in scratch, but exercise Unicode in the actual targets.
    $env:TEMP = Join-Path $tempRoot $id
    $env:TMP = $env:TEMP
    foreach ($directory in @($env:LOCALAPPDATA, $env:TEMP)) { [void][IO.Directory]::CreateDirectory($directory) }
    $script:desktop = Join-Path $fixture 'Desktop'
    $script:pulsar = Join-Path $env:APPDATA 'Pulsar'
    $script:profile = Join-Path $pulsar 'Legacy\Profiles\Current.xml'
    $script:config = Join-Path $pulsar 'Legacy.exe.config'
    foreach ($directory in @($package, $desktop, (Split-Path $profile -Parent))) { [void][IO.Directory]::CreateDirectory($directory) }
    foreach ($scriptFile in @(Get-ChildItem -LiteralPath $PackagePath -Filter '*.ps1')) { Copy-Item -LiteralPath $scriptFile.FullName -Destination $package }
    Copy-Item -LiteralPath (Join-Path $PackagePath 'Interim.runtimeconfig.json') -Destination $package
    Copy-Item -LiteralPath $script:dll (Join-Path $package 'SentisClientOptimisation.dll')
    Copy-Item -LiteralPath $script:interimDll (Join-Path $package 'SentisClientOptimisation.Interim.dll')
    if (Test-Path -LiteralPath (Join-Path $PackagePath 'SentisClientOptimisation.ico')) { Copy-Item -LiteralPath (Join-Path $PackagePath 'SentisClientOptimisation.ico') $package }
    Set-Content -LiteralPath (Join-Path $pulsar 'Legacy.exe') 'not launched by tests' -Encoding ASCII
    Set-Content -LiteralPath $config '<configuration><startup useLegacyV2RuntimeActivationPolicy="true"/><runtime><gcServer enabled="false"/><unrelated value="keep"/></runtime></configuration>' -Encoding UTF8
    $localXml = ''
    if ($withLocal) { $localXml = '<Local><string>Other.dll</string></Local>' }
    Set-Content -LiteralPath $profile ('<Profile><Unrelated value="keep"/>' + $localXml + '<Nested><Local><string>Nested.dll</string></Local></Nested></Profile>') -Encoding UTF8
}
try {
    $PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
    $script:dll = Join-Path $PackagePath 'SentisClientOptimisation.dll'
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        throw 'Run tools/release.ps1 or supply a staged dual-runtime package containing SentisClientOptimisation.dll.'
    }
    Assert ([Reflection.AssemblyName]::GetAssemblyName($dll).Name -eq 'SentisClientOptimisation') 'test DLL is the real managed plugin assembly'
    $script:interimDll = Join-Path $PackagePath 'SentisClientOptimisation.Interim.dll'
    if (-not (Test-Path -LiteralPath $interimDll -PathType Leaf)) { throw 'Supply a staged dual-runtime package containing SentisClientOptimisation.Interim.dll.' }
    Assert ([Reflection.AssemblyName]::GetAssemblyName($interimDll).Name -eq 'SentisClientOptimisation') 'Interim test DLL is the real managed plugin assembly'
    Assert ((Get-FileHash -LiteralPath $dll).Hash -ne (Get-FileHash -LiteralPath $interimDll).Hash) 'Legacy and Interim payloads are distinct'
    [void][IO.Directory]::CreateDirectory($root)
    $env:SCO_NO_PAUSE = $null
    foreach ($scriptPath in @((Join-Path $PackagePath 'install.ps1'), (Join-Path $PackagePath 'uninstall.ps1'), $MyInvocation.MyCommand.Path)) {
        $bytes = [IO.File]::ReadAllBytes($scriptPath)
        Assert ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('UTF8 BOM: ' + $scriptPath)
    }
    . (Join-Path $PackagePath 'shortcut.ps1')
    New-Fixture 'lifecycle'
    $initialHash = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $before = Snapshot $fixture
    Run-Script 'install.ps1' -ValidateOnly -WithoutScriptNonInteractive | Out-Null
    Assert ((Snapshot $fixture) -ceq $before) 'install ValidateOnly has no mutations'
    Run-Script 'install.ps1' | Out-Null
    Assert (Test-Path -LiteralPath (Join-Path $pulsar 'SentisClientOptimisation.ico') -PathType Leaf) 'icon installed'
    Run-Script 'install.ps1' | Out-Null
    [xml]$xml = Get-Content -LiteralPath $profile -Raw
    Assert (@($xml.SelectNodes('/Profile/Local/string') | Where-Object InnerText -eq 'SentisClientOptimisation.dll').Count -eq 1) 'repeat install does not duplicate profile entry'
    Assert ($null -ne $xml.SelectSingleNode('/Profile/Local/string[text()="Other.dll"]')) 'unrelated plugin preserved'
    Assert ($null -ne $xml.SelectSingleNode('/Profile/Nested/Local/string[text()="Nested.dll"]')) 'nested Local preserved'
    Assert ($xml.Profile.Unrelated.value -eq 'keep') 'unrelated profile nodes preserved'
    [xml]$cfg = Get-Content -LiteralPath $config -Raw
    foreach ($pair in @(@('gcServer','true'), @('gcConcurrent','true'), @('GCHeapCount','4'), @('GCNoAffinitize','true'))) {
        Assert ($cfg.SelectSingleNode('/configuration/runtime/' + $pair[0]).GetAttribute('enabled') -eq $pair[1]) ('GC setting ' + $pair[0])
    }
    Assert ($cfg.configuration.runtime.unrelated.value -eq 'keep') 'unrelated config preserved'
    Assert ($cfg.configuration.startup.useLegacyV2RuntimeActivationPolicy -eq 'true') 'startup config preserved'
    $launcher = Join-Path $pulsar 'SentisClientOptimisation-launch.cmd'
    $launchText = Get-Content -LiteralPath $launcher -Raw
    Assert ($launchText.Contains('set COMPlus_GCgen0MaxBudget=2000000')) '32MB gen0 budget preserved'
    Assert ($launchText.Contains('start "" /D "%~dp0" "%~dp0Legacy.exe"')) 'launcher starts Legacy relative to itself (Unicode-safe)'
    $link = [Sentis.Installer.UnicodeShortcut]::Read((Join-Path $desktop 'Space Engineers (Pulsar).lnk'))
    Assert ($link.TargetPath -eq $launcher) 'COM shortcut target'
    Assert ($link.WorkingDirectory -eq $pulsar) 'COM shortcut working directory'
    Assert ($link.IconLocation -eq ((Join-Path $pulsar 'SentisClientOptimisation.ico') + ',0')) 'COM shortcut icon'
    Assert ($link.WindowStyle -eq 7) 'Unicode shortcut minimized window style'
    Assert ($link.Description -eq 'Space Engineers через Pulsar с SentisClientOptimisation') 'Unicode shortcut description'
    Assert ((Get-FileHash -LiteralPath (Join-Path $pulsar 'Legacy\Local\SentisClientOptimisation.dll')).Hash -eq (Get-FileHash -LiteralPath $dll).Hash) 'real DLL copied intact'
    Assert ((Get-FileHash -LiteralPath (Join-Path $pulsar 'SentisClientOptimisation.ico')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $PackagePath 'SentisClientOptimisation.ico')).Hash) 'real icon copied intact'
    $before = Snapshot $fixture
    Run-Script 'uninstall.ps1' -ValidateOnly -WithoutScriptNonInteractive | Out-Null
    Assert ((Snapshot $fixture) -ceq $before) 'uninstall ValidateOnly has no mutations'
    Run-Script 'uninstall.ps1' | Out-Null
    Assert ((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -eq $initialHash) 'uninstall restores original config byte for byte'
    [xml]$xml = Get-Content -LiteralPath $profile -Raw
    Assert ($null -eq $xml.SelectSingleNode('/Profile/Local/string[text()="SentisClientOptimisation.dll"]')) 'profile entry removed'
    Assert ($null -ne $xml.SelectSingleNode('/Profile/Local/string[text()="Other.dll"]')) 'uninstall preserves unrelated plugin'
    Assert ($xml.Profile.Unrelated.value -eq 'keep') 'uninstall preserves unrelated XML'
    foreach ($file in @('SentisClientOptimisation.ico','SentisClientOptimisation-launch.cmd','Legacy\Local\SentisClientOptimisation.dll','Legacy.exe.config.bak-before-gc')) {
        Assert (-not (Test-Path -LiteralPath (Join-Path $pulsar $file))) ('removed ' + $file)
    }
    Assert (-not (Test-Path -LiteralPath (Join-Path $desktop 'Space Engineers (Pulsar).lnk'))) 'shortcut removed'
    Run-Script 'uninstall.ps1' | Out-Null
    New-Fixture 'missing-local' $false
    Run-Script 'install.ps1' | Out-Null
    [xml]$xml = Get-Content -LiteralPath $profile -Raw
    Assert ($null -ne $xml.SelectSingleNode('/Profile/Local/string[text()="SentisClientOptimisation.dll"]')) 'missing Local created at profile root, not nested'
    Assert ($null -ne $xml.SelectSingleNode('/Profile/Nested/Local/string[text()="Nested.dll"]')) 'nested Local remains unchanged'
    foreach ($case in @('dll','icon','helper','exe','config','config-malformed','config-root','profile','profile-malformed','profile-root')) {
        New-Fixture ('preflight-' + $case)
        switch ($case) {
            'dll' { Remove-Item -LiteralPath (Join-Path $package 'SentisClientOptimisation.dll') }
            'helper' { Remove-Item -LiteralPath (Join-Path $package 'shortcut.ps1') }
            'icon' { Remove-Item -LiteralPath (Join-Path $package 'SentisClientOptimisation.ico') -ErrorAction SilentlyContinue }
            'exe' { Remove-Item -LiteralPath (Join-Path $pulsar 'Legacy.exe') }
            'config' { Remove-Item -LiteralPath $config }
            'config-malformed' { Set-Content -LiteralPath $config '<configuration>' }
            'config-root' { Set-Content -LiteralPath $config '<wrong/>' }
            'profile' { Remove-Item -LiteralPath $profile }
            'profile-malformed' { Set-Content -LiteralPath $profile '<Profile>' }
            'profile-root' { Set-Content -LiteralPath $profile '<!-- no root -->' }
        }
        $before = Snapshot $fixture
        Run-Script 'install.ps1' 1 | Out-Null
        Assert ((Snapshot $fixture) -ceq $before) ('failed install has no mutations: ' + $case)
        Run-Script 'install.ps1' 1 -ValidateOnly | Out-Null
        Assert ((Snapshot $fixture) -ceq $before) ('failed install ValidateOnly has no mutations: ' + $case)
    }
    foreach ($case in @('exe', 'config', 'config-malformed', 'config-root', 'profile', 'profile-malformed', 'profile-root', 'backup-malformed', 'backup-root')) {
        New-Fixture ('uninstall-preflight-' + $case)
        Run-Script 'install.ps1' | Out-Null
        switch ($case) {
            'exe' { Remove-Item -LiteralPath (Join-Path $pulsar 'Legacy.exe') }
            'config' { Remove-Item -LiteralPath $config }
            'config-malformed' { Set-Content -LiteralPath $config '<configuration>' }
            'config-root' { Set-Content -LiteralPath $config '<wrong/>' }
            'profile' { Remove-Item -LiteralPath $profile }
            'profile-malformed' { Set-Content -LiteralPath $profile '<Profile>' }
            'profile-root' { Set-Content -LiteralPath $profile '<!-- no root -->' }
            'backup-malformed' { Set-Content -LiteralPath ($config + '.bak-before-gc') '<configuration>' }
            'backup-root' { Set-Content -LiteralPath ($config + '.bak-before-gc') '<wrong/>' }
        }
        $before = Snapshot $fixture
        Run-Script 'uninstall.ps1' 1 | Out-Null
        Assert ((Snapshot $fixture) -ceq $before) ('failed uninstall has no mutations: ' + $case)
        Run-Script 'uninstall.ps1' 1 -ValidateOnly | Out-Null
        Assert ((Snapshot $fixture) -ceq $before) ('failed uninstall ValidateOnly has no mutations: ' + $case)
    }
    # Only renamed Windows ping helpers are launched, never the game or Pulsar.
    foreach ($processName in @('Legacy', 'Interim', 'SpaceEngineers', 'Pulsar', 'Interface')) {
        New-Fixture ('running-' + $processName)
        $helperPath = Join-Path $fixture ($processName + '.exe')
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') $helperPath
        $helper = Start-Process -FilePath $helperPath -ArgumentList '-t', '127.0.0.1' -WindowStyle Hidden -PassThru
        try {
            Assert ((Get-Process -Id $helper.Id).ProcessName -eq $processName) ('real process guard fixture ' + $processName)
            $before = Snapshot $fixture
            foreach ($scriptName in @('install.ps1','uninstall.ps1')) {
                Run-Script $scriptName 1 | Out-Null
                Assert ((Snapshot $fixture) -ceq $before) ('running process prevents mutations: ' + $scriptName + ' ' + $processName)
                Run-Script $scriptName 1 -ValidateOnly | Out-Null
                Assert ((Snapshot $fixture) -ceq $before) ('running process prevents validation: ' + $scriptName + ' ' + $processName)
            }
        } finally {
            Stop-Process -Id $helper.Id -Force -ErrorAction SilentlyContinue
            $helper.WaitForExit()
            $helper.Dispose()
        }
    }
    # Interim uses Legacy data only when the Interim directory does not exist.
    foreach ($ownData in @($false, $true)) {
        New-Fixture ('interim-install-' + $ownData)
        $legacyConfigHash = (Get-FileHash -LiteralPath $config).Hash
        $legacyProfileHash = (Get-FileHash -LiteralPath $profile).Hash
        if ($ownData) {
            $profile = Join-Path $pulsar 'Interim\Profiles\Current.xml'
            [void][IO.Directory]::CreateDirectory((Split-Path $profile -Parent))
            Set-Content -LiteralPath $profile '<Profile><Local><string>Other.dll</string></Local></Profile>' -Encoding UTF8
        }
        $dataFolder = Split-Path (Split-Path $profile -Parent) -Parent
        $config = Join-Path $pulsar 'Interim.runtimeconfig.json'
        Set-Content -LiteralPath (Join-Path $pulsar 'Interim.exe') 'not launched by tests' -Encoding ASCII
        Set-Content -LiteralPath $config '{"runtimeOptions":{"tfm":"net10.0","frameworks":[{"name":"Microsoft.WindowsDesktop.App","version":"10.0.0"}],"configProperties":{"System.GC.Server":false,"Custom.Keep":"сохранить","Nested":{"value":23}}},"unrelated":{"keep":true}}' -Encoding UTF8
        # Both data layouts must reject a missing Interim payload despite a valid root net48 DLL.
        $interimPayload = Join-Path $package 'SentisClientOptimisation.Interim.dll'
        Remove-Item -LiteralPath $interimPayload
        $before = Snapshot $fixture
        foreach ($validate in @($false, $true)) {
            $failure = Run-Script 'install.ps1' 1 -Runtime Interim -ValidateOnly:$validate
            Assert ($failure.Contains('SentisClientOptimisation.Interim.dll')) 'missing Interim reports the selected payload'
            Assert ((Snapshot $fixture) -ceq $before) 'missing Interim preflight has no mutations and no Legacy fallback'
        }
        Copy-Item -LiteralPath $script:interimDll -Destination $interimPayload
        $initialHash = (Get-FileHash -LiteralPath $config).Hash
        $before = Snapshot $fixture
        Run-Script 'install.ps1' -Runtime Interim -ValidateOnly -WithoutScriptNonInteractive | Out-Null
        Assert ((Snapshot $fixture) -ceq $before) 'Interim ValidateOnly has no mutations'
        Run-Script 'install.ps1' -Runtime Interim | Out-Null
        Run-Script 'install.ps1' -Runtime Interim | Out-Null
        Assert ((Get-FileHash -LiteralPath ($config + '.bak-before-gc')).Hash -eq $initialHash) 'Interim repeat install preserves original backup bytes'
        $jsonCfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @('System.GC.Server','System.GC.Concurrent','System.GC.NoAffinitize')) {
            Assert ($jsonCfg.runtimeOptions.configProperties.$key -is [bool] -and $jsonCfg.runtimeOptions.configProperties.$key) ('Interim typed boolean ' + $key)
        }
        Assert ($jsonCfg.runtimeOptions.configProperties.'System.GC.HeapCount' -eq 4) 'Interim heap count'
        Assert ($jsonCfg.runtimeOptions.configProperties.'System.GC.HeapCount' -is [ValueType]) 'Interim heap count is JSON number'
        Assert ($jsonCfg.runtimeOptions.configProperties.'Custom.Keep' -ceq 'сохранить') 'Interim Unicode property preserved'
        Assert ($jsonCfg.runtimeOptions.configProperties.Nested.value -eq 23) 'Interim nested property preserved'
        Assert ($jsonCfg.runtimeOptions.frameworks[0].name -eq 'Microsoft.WindowsDesktop.App') 'Interim framework preserved'
        Assert ($jsonCfg.unrelated.keep) 'Interim unrelated root preserved'
        Assert ((Get-FileHash -LiteralPath (Join-Path $pulsar 'Legacy.exe.config')).Hash -eq $legacyConfigHash) 'install touches only selected config'
        if ($ownData) { Assert ((Get-FileHash -LiteralPath (Join-Path $pulsar 'Legacy\Profiles\Current.xml')).Hash -eq $legacyProfileHash) 'separate Interim profile leaves Legacy untouched' }
        Assert ((Get-FileHash -LiteralPath (Join-Path $dataFolder 'Local\SentisClientOptimisation.dll')).Hash -eq (Get-FileHash -LiteralPath $interimDll).Hash) 'Interim DLL in selected data folder (never the root net48 payload)'
        [xml]$xml = Get-Content -LiteralPath $profile -Raw
        Assert (@($xml.SelectNodes('/Profile/Local/string') | Where-Object InnerText -eq 'SentisClientOptimisation.dll').Count -eq 1) 'Interim repeat profile enable is idempotent'
        $launchText = Get-Content -LiteralPath (Join-Path $pulsar 'SentisClientOptimisation-launch.cmd') -Raw
        Assert ($launchText.Contains('start "" /D "%~dp0" "%~dp0Interim.exe"')) 'Interim relative Unicode-safe launcher'
        Assert ($launchText.Contains('if exist "%LOCALAPPDATA%\SentisClientOptimisation\dotnet\dotnet.exe" set "DOTNET_ROOT_X64=%LOCALAPPDATA%\SentisClientOptimisation\dotnet"')) 'Interim conditional private runtime root'
        Assert (-not $launchText.Contains('Microsoft\dotnet')) 'launcher never uses unrelated Microsoft dotnet root'
        $link = [Sentis.Installer.UnicodeShortcut]::Read((Join-Path $desktop 'Space Engineers (Pulsar).lnk'))
        Assert ($link.TargetPath -eq (Join-Path $pulsar 'SentisClientOptimisation-launch.cmd')) 'Interim real COM shortcut target'
        Assert ($link.WorkingDirectory -eq $pulsar) 'Interim real COM working directory'
        Assert ($link.IconLocation -eq ((Join-Path $pulsar 'SentisClientOptimisation.ico') + ',0')) 'Interim real COM icon'
        # Simulate a previous Legacy install: uninstall must clean BOTH, regardless of selected runtime.
        Run-Script 'install.ps1' -Runtime Legacy | Out-Null
        foreach ($folder in @('Legacy', 'Interim')) {
            if (Test-Path -LiteralPath (Join-Path $pulsar $folder) -PathType Container) {
                [void][IO.Directory]::CreateDirectory((Join-Path $pulsar ($folder + '\Local')))
                Set-Content -LiteralPath (Join-Path $pulsar ($folder + '\Local\Other.dll')) 'unrelated plugin' -Encoding ASCII
            }
        }
        $before = Snapshot $fixture
        Run-Script 'uninstall.ps1' -Runtime Interim -ValidateOnly -WithoutScriptNonInteractive | Out-Null
        Assert ((Snapshot $fixture) -ceq $before) 'Interim uninstall ValidateOnly has no mutations'
        Run-Script 'uninstall.ps1' -Runtime Interim | Out-Null
        Assert ((Get-FileHash -LiteralPath $config).Hash -eq $initialHash) 'Interim uninstall restores JSON bytes exactly'
        Assert ((Get-FileHash -LiteralPath (Join-Path $pulsar 'Legacy.exe.config')).Hash -eq $legacyConfigHash) 'Interim uninstall restores Legacy config too'
        foreach ($folder in @('Legacy', 'Interim')) {
            Assert (-not (Test-Path -LiteralPath (Join-Path $pulsar ($folder + '\Local\SentisClientOptimisation.dll')))) ('uninstall cleans DLL: ' + $folder)
            $folderProfile = Join-Path $pulsar ($folder + '\Profiles\Current.xml')
            if (Test-Path -LiteralPath $folderProfile) {
                [xml]$xml = Get-Content -LiteralPath $folderProfile -Raw
                Assert (@($xml.SelectNodes('/Profile/Local/string') | Where-Object InnerText -eq 'SentisClientOptimisation.dll').Count -eq 0) ('uninstall disables profile: ' + $folder)
                Assert ($null -ne $xml.SelectSingleNode('/Profile/Local/string[text()="Other.dll"]')) ('uninstall keeps other profile plugin: ' + $folder)
                Assert ((Get-Content -LiteralPath (Join-Path $pulsar ($folder + '\Local\Other.dll')) -Raw).Contains('unrelated plugin')) ('uninstall keeps other DLL: ' + $folder)
            }
        }
        Assert (-not (Test-Path -LiteralPath ($config + '.bak-before-gc'))) 'Interim backup consumed'
        Assert (-not (Test-Path -LiteralPath (Join-Path $pulsar 'Legacy.exe.config.bak-before-gc'))) 'Legacy backup consumed by Interim uninstall'
        Assert (-not (Test-Path -LiteralPath (Join-Path $desktop 'Space Engineers (Pulsar).lnk'))) 'Interim shortcut removed'
        $before = Snapshot $fixture
        Run-Script 'uninstall.ps1' -Runtime Interim | Out-Null
        Assert ((Snapshot $fixture) -ceq $before) 'repeat Interim uninstall is byte-idempotent'
    }
    # External updates must never be replaced wholesale with a stale GC backup.
    foreach ($runtimeName in @('Legacy', 'Interim')) {
        foreach ($scenario in @('external', 'repeat', 'no-hash', 'absent', 'user-gc')) {
            Remove-Variable current -ErrorAction SilentlyContinue
            New-Fixture ('merge-' + $runtimeName + '-' + $scenario)
            if ($runtimeName -eq 'Interim') {
                Set-Content -LiteralPath (Join-Path $pulsar 'Interim.exe') 'not launched' -Encoding ASCII
                $config = Join-Path $pulsar 'Interim.runtimeconfig.json'
                $text = '{"runtimeOptions":{"configProperties":{"System.GC.Server":false,"Custom.Keep":"original"}},"unknown":{"value":1}}'
                if ($scenario -eq 'absent') { $text = '{"runtimeOptions":{"tfm":"net10.0"},"unknown":{"value":1}}' }
                Set-Content -LiteralPath $config $text -Encoding UTF8
            } elseif ($scenario -eq 'absent') {
                Set-Content -LiteralPath $config '<configuration><startup/></configuration>' -Encoding UTF8
            }
            Run-Script 'install.ps1' -Runtime $runtimeName | Out-Null
            $baselineHash = (Get-FileHash -LiteralPath ($config + '.bak-before-gc')).Hash
            if ($runtimeName -eq 'Interim') {
                $current = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
                $current | Add-Member -NotePropertyName Added -NotePropertyValue ([pscustomobject]@{ nested = 'новое' })
                $current.runtimeOptions | Add-Member -NotePropertyName newRuntimeProperty -NotePropertyValue 42
                if ($scenario -ne 'absent') { $current.runtimeOptions.configProperties.'Custom.Keep' = 'updated' }
                if ($scenario -eq 'user-gc') { $current.runtimeOptions.configProperties.'System.GC.HeapCount' = 7 }
                $current | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $config -Encoding UTF8
            } else {
                [xml]$current = Get-Content -LiteralPath $config -Raw -Encoding UTF8
                $added = $current.CreateElement('Added'); $added.SetAttribute('value', 'новое'); [void]$current.DocumentElement.AppendChild($added)
                $current.SelectSingleNode('/configuration/runtime').SetAttribute('updated', '42')
                if ($scenario -ne 'absent') { $current.SelectSingleNode('/configuration/runtime/unrelated').SetAttribute('value', 'updated') }
                if ($scenario -eq 'user-gc') { $current.SelectSingleNode('/configuration/runtime/GCHeapCount').SetAttribute('enabled', '7') }
                $current.Save($config)
            }
            if ($scenario -eq 'no-hash') { Remove-Item -LiteralPath ($config + '.sentis-gc.sha256') -ErrorAction SilentlyContinue }
            if ($scenario -eq 'repeat') {
                Run-Script 'install.ps1' -Runtime $runtimeName | Out-Null
                Assert ((Get-FileHash -LiteralPath ($config + '.bak-before-gc')).Hash -eq $baselineHash) 'repeat install keeps original GC baseline'
            }
            Run-Script 'uninstall.ps1' -Runtime $runtimeName | Out-Null
            if ($runtimeName -eq 'Interim') {
                $current = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
                Assert ($current.Added.nested -ceq 'новое' -and $current.runtimeOptions.newRuntimeProperty -eq 42) 'Interim external unrelated nodes survive uninstall'
                $properties = $current.runtimeOptions.configProperties
                if ($scenario -eq 'absent') { Assert ($null -eq $current.runtimeOptions.PSObject.Properties['configProperties']) 'remove originally absent empty configProperties' }
                else {
                    Assert ($properties.'Custom.Keep' -eq 'updated') 'Interim changed unrelated config property survives'
                    Assert ($properties.'System.GC.Server' -eq $false) 'Interim original GC restored'
                    Assert ($null -eq $properties.PSObject.Properties['System.GC.Concurrent']) 'Interim originally absent GC removed'
                    if ($scenario -eq 'user-gc') { Assert ($properties.'System.GC.HeapCount' -eq 7) 'Interim user GC edit survives' }
                }
            } else {
                [xml]$current = Get-Content -LiteralPath $config -Raw -Encoding UTF8
                Assert ($current.configuration.Added.value -ceq 'новое') 'Legacy external unrelated nodes survive uninstall'
                Assert ($current.SelectSingleNode('/configuration/runtime').GetAttribute('updated') -eq '42') 'Legacy runtime attributes survive'
                if ($scenario -ne 'absent') {
                    Assert ($current.configuration.runtime.unrelated.value -eq 'updated') 'Legacy changed unrelated config node survives'
                    Assert ($current.configuration.runtime.gcServer.enabled -eq 'false') 'Legacy original GC restored'
                }
                Assert ($null -eq $current.SelectSingleNode('/configuration/runtime/gcConcurrent')) 'Legacy originally absent GC removed'
                if ($scenario -eq 'user-gc') { Assert ($current.configuration.runtime.GCHeapCount.enabled -eq '7') 'Legacy user GC edit survives' }
            }
            Assert (-not (Test-Path -LiteralPath ($config + '.sentis-gc.sha256'))) 'installed hash consumed'
        }
    }
    # Missing Interim config is a dependency repair, never a GC-owned deletion.
    foreach ($recovery in @('template', 'backup')) {
        New-Fixture ('interim-repair-' + $recovery)
        Set-Content -LiteralPath (Join-Path $pulsar 'Interim.exe') 'never launched' -Encoding ASCII
        $config = Join-Path $pulsar 'Interim.runtimeconfig.json'
        $baseline = Join-Path $package 'Interim.runtimeconfig.json'
        if ($recovery -eq 'backup') {
            $baseline = $config + '.bak-before-gc'
            $json = Get-Content -LiteralPath (Join-Path $package 'Interim.runtimeconfig.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $json | Add-Member -NotePropertyName CustomRecovery -NotePropertyValue 'keep'
            $json | ConvertTo-Json -Depth 100 -Compress | Set-Content -LiteralPath $baseline -Encoding UTF8
        }
        $baselineHash = (Get-FileHash -LiteralPath $baseline).Hash
        $before = Snapshot $fixture
        Run-Script 'install.ps1' 1 -Runtime Interim -ValidateOnly | Out-Null
        Assert ((Snapshot $fixture) -ceq $before) 'missing Interim ValidateOnly never repairs'
        Run-Script 'install.ps1' -Runtime Interim | Out-Null
        Assert ((Get-FileHash -LiteralPath ($config + '.bak-before-gc')).Hash -eq $baselineHash) 'recovery keeps selected source bytes as GC baseline'
        Run-Script 'install.ps1' -Runtime Interim | Out-Null
        Run-Script 'uninstall.ps1' -Runtime Interim | Out-Null
        Assert ((Get-FileHash -LiteralPath $config).Hash -eq $baselineHash) 'repaired Interim survives repeat install and uninstall byte-exactly'
    }
    Write-Host "PASS: $script:checks assertions. Isolated fixture: $root"
} finally {
    $env:APPDATA = $originalAppData
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
    $env:SCO_NO_PAUSE = $originalPause
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
