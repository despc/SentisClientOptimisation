# Ставит SentisClientOptimisation: плагин в локальные плагины Pulsar (с разблокировкой и включением в профиле),
# серверный GC для игры и ярлык запуска на рабочем столе. Запуск: двойной щелчок по install.cmd, игра закрыта.
param([string]$Desktop, [switch]$NonInteractive, [switch]$ValidateOnly,
    [ValidateSet('Legacy', 'Interim')][string]$Runtime = 'Legacy')
$exitCode = 0
$ErrorActionPreference = 'Stop'
$name = 'SentisClientOptimisation.dll'
$pulsarRoot = Join-Path $env:APPDATA 'Pulsar'
$pulsar = Join-Path $pulsarRoot 'Legacy'
if ($Runtime -eq 'Interim' -and (Test-Path -LiteralPath (Join-Path $pulsarRoot 'Interim') -PathType Container)) {
    $pulsar = Join-Path $pulsarRoot 'Interim'
}
$exe = Join-Path $pulsarRoot ($Runtime + '.exe')
$config = "$exe.config"
if ($Runtime -eq 'Interim') { $config = Join-Path $pulsarRoot 'Interim.runtimeconfig.json' }
$backup = "$config.bak-before-gc"
$launcher = Join-Path $pulsarRoot 'SentisClientOptimisation-launch.cmd'
if (-not $Desktop) { $Desktop = [Environment]::GetFolderPath('Desktop') }
$shortcut = Join-Path $Desktop 'Space Engineers (Pulsar).lnk'
$oldLauncher = Join-Path $Desktop 'Space Engineers (Pulsar, GC).cmd'

try {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    $source = Join-Path $here $name
    $iconSource = Join-Path $here 'SentisClientOptimisation.ico'
    $icon = Join-Path $pulsarRoot 'SentisClientOptimisation.ico'
    $profile = Join-Path $pulsar 'Profiles\Current.xml'
    # Все проверки до изменений. GUI Pulsar: Interface.exe (Interface.csproj).
    if (Get-Process -Name 'Legacy', 'Interim', 'SpaceEngineers', 'Pulsar', 'Interface' -ErrorAction SilentlyContinue) { throw 'Игра или Pulsar запущены. Закройте Legacy, Interim, SpaceEngineers и Pulsar (Interface).' }
    $shortcutHelper = Join-Path $here 'shortcut.ps1'
    foreach ($file in @($source, $iconSource, $shortcutHelper)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "В установочном пакете отсутствует файл: $file" }
    }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Не найден Pulsar ($exe). Установите Pulsar и запустите игру через него для создания профиля." }
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw "Не найден конфиг Pulsar: $config" }
    if ($Runtime -eq 'Legacy') {
        [xml]$cfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8
        if ($null -eq $cfg.DocumentElement -or $cfg.DocumentElement.Name -ne 'configuration') { throw "Некорректный конфиг: ожидается /configuration в $config" }
    } else {
        $cfg = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg -isnot [pscustomobject] -or $cfg.runtimeOptions -isnot [pscustomobject]) { throw "Некорректный конфиг: ожидается объект runtimeOptions в $config" }
        if ($null -eq $cfg.runtimeOptions.PSObject.Properties['configProperties']) {
            $cfg.runtimeOptions | Add-Member -NotePropertyName configProperties -NotePropertyValue ([pscustomobject]@{})
        }
        if ($cfg.runtimeOptions.configProperties -isnot [pscustomobject]) { throw "Некорректный configProperties в $config" }
    }
    if (-not (Test-Path -LiteralPath $profile -PathType Leaf)) { throw "Не найден текущий профиль Pulsar: $profile. Сначала создайте профиль запуском игры через Pulsar." }
    [xml]$xml = Get-Content -LiteralPath $profile -Raw -Encoding UTF8
    if ($null -eq $xml.DocumentElement) { throw "Профиль Pulsar не содержит корневого XML-элемента: $profile" }
    if (-not (Test-Path -LiteralPath $Desktop -PathType Container)) { throw "Не найден рабочий стол: $Desktop" }
    . $shortcutHelper
    if ($ValidateOnly) { Write-Host 'Проверка установки выполнена. Изменений нет.'; exit 0 }

    # 1. плагин
    $local = Join-Path $pulsar 'Local'
    [void][IO.Directory]::CreateDirectory($local)
    $target = Join-Path $local $name
    Copy-Item -LiteralPath $source $target -Force
    Copy-Item -LiteralPath $iconSource -Destination $icon -Force
    Unblock-File -LiteralPath $target
    Write-Host "1. Плагин: $target"

    # 2. включён в профиле Pulsar
    $list = $xml.DocumentElement.SelectSingleNode('Local')
    if ($null -eq $list) {
        $list = $xml.CreateElement('Local')
        [void]$xml.DocumentElement.AppendChild($list)
    }
    if (@($list.ChildNodes | Where-Object { $_.InnerText -eq $name }).Count -eq 0) {
        if (-not (Test-Path -LiteralPath ($profile + '.bak'))) { Copy-Item -LiteralPath $profile ($profile + '.bak') }
        $node = $xml.CreateElement('string')
        $node.InnerText = $name
        [void]$list.AppendChild($node)
        $xml.Save($profile)
    }
    Write-Host '2. Плагин включён в профиле Pulsar.'

    # 3. GC выбранного runtime. Другой runtime не меняем: при смене режима
    # вызывающий installer делает uninstall -ValidateOnly, uninstall, затем install.
    $hashPath = $config + '.sentis-gc.sha256'
    $mergePath = $config + '.sentis-gc.merge'
    if (Test-Path -LiteralPath $backup) {
        # A repeat install must not make an already stale backup authoritative again.
        if (-not (Test-Path -LiteralPath $hashPath) -or
            (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -ne (Get-Content -LiteralPath $hashPath -Raw).Trim()) {
            Set-Content -LiteralPath $mergePath -Value 'Preserve unrelated current configuration' -Encoding ASCII
        }
    } else { Copy-Item -LiteralPath $config -Destination $backup }

    if ($Runtime -eq 'Legacy') {
        $runtimeNode = $cfg.SelectSingleNode('/configuration/runtime')
        if ($runtimeNode -eq $null) {
            $runtimeNode = $cfg.CreateElement('runtime')
            [void]$cfg.DocumentElement.AppendChild($runtimeNode)
        }
        foreach ($pair in @(@('gcServer', 'true'), @('gcConcurrent', 'true'), @('GCHeapCount', '4'), @('GCNoAffinitize', 'true'))) {
            $node = $runtimeNode.SelectSingleNode($pair[0])
            if ($node -eq $null) {
                $node = $cfg.CreateElement($pair[0])
                [void]$runtimeNode.PrependChild($node)
            }
            $node.SetAttribute('enabled', $pair[1])
        }
        $cfg.Save($config)
    } else {
        foreach ($pair in @(@('System.GC.Server', $true), @('System.GC.Concurrent', $true), @('System.GC.HeapCount', 4), @('System.GC.NoAffinitize', $true))) {
            $cfg.runtimeOptions.configProperties | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
        }
        $cfg | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $config -Encoding UTF8
    }
    Set-Content -LiteralPath $hashPath -Value (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -Encoding ASCII
    Write-Host "3. Серверный GC включён (копия прежнего конфига: $backup)"

    # 4. запуск с бюджетом gen0 32 МБ и ярлык на рабочем столе
    $launchLines = @(
        '@echo off',
        'rem Space Engineers through Pulsar, the GC gen0 budget 32 MB (SentisClientOptimisation)',
        'set COMPlus_GCgen0MaxBudget=2000000'
    )
    if ($Runtime -eq 'Interim') {
        # Absent private runtime: leave an existing environment/registry runtime selection intact.
        $launchLines += 'if exist "%LOCALAPPDATA%\SentisClientOptimisation\dotnet\dotnet.exe" set "DOTNET_ROOT_X64=%LOCALAPPDATA%\SentisClientOptimisation\dotnet"'
    }
    $launchLines += ('start "" /D "%~dp0" "%~dp0' + $Runtime + '.exe"')
    Set-Content -LiteralPath $launcher -Encoding ASCII -Value $launchLines
    if (Test-Path -LiteralPath $oldLauncher) { Remove-Item -LiteralPath $oldLauncher }
    [Sentis.Installer.UnicodeShortcut]::Create($shortcut, $launcher, $pulsarRoot, $icon,
        'Space Engineers через Pulsar с SentisClientOptimisation')
    Write-Host "4. Ярлык запуска: $shortcut"
    Write-Host ''
    Write-Host 'Готово. Запускайте игру ярлыком "Space Engineers (Pulsar)" на рабочем столе.'
} catch {
    $exitCode = 1
    Write-Host ''
    Write-Host ('Не установлено: ' + $_.Exception.Message) -ForegroundColor Red
}
Write-Host ''
if (-not $NonInteractive -and -not $ValidateOnly -and -not $env:SCO_NO_PAUSE) { [void](Read-Host 'Нажмите Enter, чтобы закрыть') }
exit $exitCode
