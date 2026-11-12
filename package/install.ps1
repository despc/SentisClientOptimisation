# Ставит SentisClientOptimisation: плагин в локальные плагины Pulsar (с разблокировкой и включением в профиле),
# серверный GC для игры и ярлык запуска на рабочем столе. Запуск: двойной щелчок по install.cmd, игра закрыта.
param([string]$Desktop)
$ErrorActionPreference = 'Stop'
$name = 'SentisClientOptimisation.dll'
$pulsarRoot = Join-Path $env:APPDATA 'Pulsar'
$pulsar = Join-Path $pulsarRoot 'Legacy'
$exe = Join-Path $pulsarRoot 'Legacy.exe'
$config = "$exe.config"
$backup = "$config.bak-before-gc"
$launcher = Join-Path $pulsarRoot 'SentisClientOptimisation-launch.cmd'
if (-not $Desktop) { $Desktop = [Environment]::GetFolderPath('Desktop') }
$shortcut = Join-Path $Desktop 'Space Engineers (Pulsar).lnk'
$oldLauncher = Join-Path $Desktop 'Space Engineers (Pulsar, GC).cmd'

try {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    $source = Join-Path $here $name
    if (-not (Test-Path $source)) { throw "Рядом со скриптом нет $name - распакуйте архив целиком." }
    if (-not (Test-Path $exe)) { throw "Не найден Pulsar ($exe). Установите Pulsar и хотя бы раз запустите через него игру." }
    if (Get-Process -Name 'Legacy', 'SpaceEngineers' -ErrorAction SilentlyContinue) { throw 'Игра запущена - закройте её и запустите установку снова.' }

    # 1. плагин
    $local = Join-Path $pulsar 'Local'
    New-Item -ItemType Directory -Force $local | Out-Null
    $target = Join-Path $local $name
    Copy-Item $source $target -Force
    Unblock-File $target
    Write-Host "1. Плагин: $target"

    # 2. включён в профиле Pulsar
    $profile = Join-Path $pulsar 'Profiles\Current.xml'
    if (Test-Path $profile) {
        [xml]$xml = Get-Content $profile -Raw -Encoding UTF8
        $list = $xml.SelectSingleNode('//Local')
        if ($list -eq $null) {
            Write-Host '2. В профиле Pulsar нет раздела Local: включите плагин вручную (список плагинов Pulsar -> Local).'
        } elseif ($list.ChildNodes | Where-Object { $_.InnerText -eq $name }) {
            Write-Host '2. Плагин уже включён в профиле Pulsar.'
        } else {
            Copy-Item $profile ($profile + '.bak') -Force
            $node = $xml.CreateElement('string')
            $node.InnerText = $name
            [void]$list.AppendChild($node)
            $xml.Save($profile)
            Write-Host '2. Плагин включён в профиле Pulsar.'
        }
    } else {
        Write-Host '2. Профиль Pulsar не найден: включите плагин вручную (список плагинов Pulsar -> Local).'
    }

    # 3. серверный GC на 4 кучи для Legacy.exe
    if (-not (Test-Path $backup)) { Copy-Item $config $backup }
    [xml]$cfg = Get-Content $config -Raw -Encoding UTF8
    $runtime = $cfg.SelectSingleNode('/configuration/runtime')
    if ($runtime -eq $null) {
        $runtime = $cfg.CreateElement('runtime')
        [void]$cfg.DocumentElement.AppendChild($runtime)
    }
    foreach ($pair in @(@('gcServer', 'true'), @('gcConcurrent', 'true'), @('GCHeapCount', '4'), @('GCNoAffinitize', 'true'))) {
        $node = $runtime.SelectSingleNode($pair[0])
        if ($node -eq $null) {
            $node = $cfg.CreateElement($pair[0])
            [void]$runtime.PrependChild($node)
        }
        $node.SetAttribute('enabled', $pair[1])
    }
    $cfg.Save($config)
    Write-Host "3. Серверный GC включён (копия прежнего конфига: $backup)"

    # 4. запуск с бюджетом gen0 32 МБ и ярлык на рабочем столе
    Set-Content $launcher -Encoding ASCII -Value @(
        '@echo off',
        'rem Space Engineers through Pulsar, the GC gen0 budget 32 MB (SentisClientOptimisation)',
        'set COMPlus_GCgen0MaxBudget=2000000',
        ('start "" /D "' + $pulsarRoot + '" "' + $exe + '"')
    )
    if (Test-Path $oldLauncher) { Remove-Item $oldLauncher }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = $launcher
    $link.WorkingDirectory = $pulsarRoot
    $link.IconLocation = "$exe,0"
    $link.WindowStyle = 7
    $link.Description = 'Space Engineers через Pulsar с SentisClientOptimisation'
    $link.Save()
    Write-Host "4. Ярлык запуска: $shortcut"
    Write-Host ''
    Write-Host 'Готово. Запускайте игру ярлыком "Space Engineers (Pulsar)" на рабочем столе.'
} catch {
    Write-Host ''
    Write-Host ('Не установлено: ' + $_.Exception.Message) -ForegroundColor Red
}
Write-Host ''
if (-not $env:SCO_NO_PAUSE) { Read-Host 'Нажмите Enter, чтобы закрыть' }
