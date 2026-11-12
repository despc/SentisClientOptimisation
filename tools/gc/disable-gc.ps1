# Возвращает Legacy.exe.config как было до enable-gc.ps1 и удаляет ярлык запуска.
$ErrorActionPreference = 'Stop'
$config = Join-Path $env:APPDATA 'Pulsar\Legacy.exe.config'
$backup = "$config.bak-before-gc"
if (Get-Process -Name 'Legacy' -ErrorAction SilentlyContinue) { throw 'Игра запущена - закройте её.' }
if (Test-Path $backup) { Copy-Item $backup $config -Force; Remove-Item $backup; Write-Host "Конфиг возвращён: $config" }
else { Write-Host 'Копии нет - GC не включался через enable-gc.ps1.' }
$launcher = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Space Engineers (Pulsar, GC).cmd'
if (Test-Path $launcher) { Remove-Item $launcher; Write-Host "Ярлык удалён: $launcher" }
