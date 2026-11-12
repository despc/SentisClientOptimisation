# Убирает SentisClientOptimisation и всё, что поставил install: плагин, его строку в профиле Pulsar, настройку GC
# (конфиг Legacy.exe возвращается из копии) и ярлык запуска. Игра должна быть закрыта.
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
    if (Get-Process -Name 'Legacy', 'SpaceEngineers' -ErrorAction SilentlyContinue) { throw 'Игра запущена - закройте её и запустите удаление снова.' }
    $target = Join-Path $pulsar "Local\$name"
    if (Test-Path $target) {
        Remove-Item $target
        Write-Host "Плагин удалён: $target"
    }
    $profile = Join-Path $pulsar 'Profiles\Current.xml'
    if (Test-Path $profile) {
        [xml]$xml = Get-Content $profile -Raw -Encoding UTF8
        $nodes = @($xml.SelectNodes('//Local/string') | Where-Object { $_.InnerText -eq $name })
        if ($nodes.Count -gt 0) {
            foreach ($n in $nodes) { [void]$n.ParentNode.RemoveChild($n) }
            $xml.Save($profile)
            Write-Host 'Убран из профиля Pulsar.'
        }
    }
    if (Test-Path $backup) {
        Copy-Item $backup $config -Force
        Remove-Item $backup
        Write-Host "Настройка GC снята: $config"
    }
    foreach ($f in @($launcher, $shortcut, $oldLauncher)) {
        if (Test-Path $f) {
            Remove-Item $f
            Write-Host "Удалён: $f"
        }
    }
    Write-Host ''
    Write-Host 'Готово. Игру снова можно запускать как обычно через Pulsar.'
} catch {
    Write-Host ''
    Write-Host ('Не удалено: ' + $_.Exception.Message) -ForegroundColor Red
}
Write-Host ''
if (-not $env:SCO_NO_PAUSE) { Read-Host 'Нажмите Enter, чтобы закрыть' }
