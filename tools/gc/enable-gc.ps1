# Включает для игры через Pulsar (Legacy.exe) серверный GC на 4 кучи и создаёт на рабочем столе ярлык запуска
# с бюджетом gen0 32 МБ (как на тестовом сервере: короткие частые сборки мусора вместо длинных).
# Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File enable-gc.ps1   (игра должна быть закрыта)
$ErrorActionPreference = 'Stop'
$pulsar = Join-Path $env:APPDATA 'Pulsar'
$exe = Join-Path $pulsar 'Legacy.exe'
$config = "$exe.config"
if (-not (Test-Path $config)) { throw "Не найден $config" }
if (Get-Process -Name 'Legacy' -ErrorAction SilentlyContinue) { throw 'Игра запущена - закройте её.' }
$backup = "$config.bak-before-gc"
if (-not (Test-Path $backup)) { Copy-Item $config $backup }
[xml]$xml = Get-Content $config -Raw -Encoding UTF8
$runtime = $xml.SelectSingleNode('/configuration/runtime')
foreach ($pair in @(@('gcServer', 'true'), @('gcConcurrent', 'true'), @('GCHeapCount', '4'), @('GCNoAffinitize', 'true'))) {
    $node = $runtime.SelectSingleNode($pair[0])
    if ($node -eq $null) {
        $node = $xml.CreateElement($pair[0])
        [void]$runtime.PrependChild($node)
    }
    $node.SetAttribute('enabled', $pair[1])
}
$xml.Save($config)
Write-Host "Серверный GC на 4 кучи включён в $config (копия: $backup)"
$launcher = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Space Engineers (Pulsar, GC).cmd'
Set-Content $launcher -Encoding ASCII -Value @(
    '@echo off',
    'rem Space Engineers through Pulsar with the gen0 budget of 32 MB (COMPlus_GCgen0MaxBudget, hex)',
    'set COMPlus_GCgen0MaxBudget=2000000',
    "start """" /D ""$pulsar"" ""$exe"""
)
Write-Host "Ярлык запуска с бюджетом gen0: $launcher"
