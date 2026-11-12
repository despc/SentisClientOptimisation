# Убирает только SentisClientOptimisation из обоих runtime и возвращает оба GC-config из копий.
# Существующие профили не заменяются резервными: удаляется только строка нашего плагина.
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
$launcher = Join-Path $pulsarRoot 'SentisClientOptimisation-launch.cmd'
if (-not $Desktop) { $Desktop = [Environment]::GetFolderPath('Desktop') }
$shortcut = Join-Path $Desktop 'Space Engineers (Pulsar).lnk'
$oldLauncher = Join-Path $Desktop 'Space Engineers (Pulsar, GC).cmd'

# Only our four GC values belong to us. Unknown config state belongs to Pulsar/user.
function Restore-GcConfiguration([string]$path, [string]$backup) {
    $hashPath = $path + '.sentis-gc.sha256'
    $mergePath = $path + '.sentis-gc.merge'
    # A recovered backup may already be the exact current config with no GC
    # metadata yet. Do not reserialize a configuration that needs no undo.
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash) { return }
    if ((Test-Path -LiteralPath $hashPath) -and -not (Test-Path -LiteralPath $mergePath) -and
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq (Get-Content -LiteralPath $hashPath -Raw).Trim()) {
        Copy-Item -LiteralPath $backup -Destination $path -Force
        return
    }
    if ($path.EndsWith('.json')) {
        $current = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $original = Get-Content -LiteralPath $backup -Raw -Encoding UTF8 | ConvertFrom-Json
        $properties = $current.runtimeOptions.configProperties
        if ($null -ne $properties) {
            foreach ($pair in @(@('System.GC.Server', $true), @('System.GC.Concurrent', $true), @('System.GC.HeapCount', 4), @('System.GC.NoAffinitize', $true))) {
                $key = $pair[0]
                $property = $properties.PSObject.Properties[$key]
                # Missing or user-modified GC values must be left alone as well.
                if ($null -eq $property -or ($property.Value | ConvertTo-Json -Compress -Depth 100) -cne ($pair[1] | ConvertTo-Json -Compress)) { continue }
                $old = $null
                if ($null -ne $original.runtimeOptions.configProperties) { $old = $original.runtimeOptions.configProperties.PSObject.Properties[$key] }
                if ($null -ne $old) { $properties | Add-Member -NotePropertyName $key -NotePropertyValue $old.Value -Force }
                else { $properties.PSObject.Properties.Remove($key) }
            }
            if ($null -eq $original.runtimeOptions.PSObject.Properties['configProperties'] -and @($properties.PSObject.Properties).Count -eq 0) {
                $current.runtimeOptions.PSObject.Properties.Remove('configProperties')
            }
        }
        $current | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding UTF8
    } else {
        [xml]$current = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        [xml]$original = Get-Content -LiteralPath $backup -Raw -Encoding UTF8
        $runtimeNode = $current.SelectSingleNode('/configuration/runtime')
        if ($null -ne $runtimeNode) {
            foreach ($pair in @(@('gcServer', 'true'), @('gcConcurrent', 'true'), @('GCHeapCount', '4'), @('GCNoAffinitize', 'true'))) {
                $node = $runtimeNode.SelectSingleNode($pair[0])
                if ($null -eq $node -or $node.GetAttribute('enabled') -cne $pair[1]) { continue }
                $old = $original.SelectSingleNode('/configuration/runtime/' + $pair[0])
                if ($null -ne $old -and $old.HasAttribute('enabled')) { $node.SetAttribute('enabled', $old.GetAttribute('enabled')) }
                else {
                    $node.RemoveAttribute('enabled')
                    if ($null -eq $old -and $node.Attributes.Count -eq 0 -and -not $node.HasChildNodes) { [void]$runtimeNode.RemoveChild($node) }
                }
            }
            if ($null -eq $original.SelectSingleNode('/configuration/runtime') -and $runtimeNode.Attributes.Count -eq 0 -and -not $runtimeNode.HasChildNodes) {
                [void]$runtimeNode.ParentNode.RemoveChild($runtimeNode)
            }
        }
        $current.Save($path)
    }
}

try {
    # Preflight до удаления любого файла, включая проверку резервного config.
    if (Get-Process -Name 'Legacy', 'Interim', 'SpaceEngineers', 'Pulsar', 'Interface' -ErrorAction SilentlyContinue) { throw 'Игра или Pulsar запущены. Закройте Legacy, Interim, SpaceEngineers и Pulsar (Interface).' }
    $profile = Join-Path $pulsar 'Profiles\Current.xml'
    foreach ($file in @($exe, $config, $profile)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Не найден файл Pulsar: $file. Восстановите Pulsar и его текущий профиль перед удалением." }
    }
    # Проверяем ВСЕ затрагиваемые профили/config/backup до первой мутации.
    $profiles = @()
    foreach ($folder in @('Legacy', 'Interim')) {
        $path = Join-Path $pulsarRoot ($folder + '\Profiles\Current.xml')
        if (Test-Path -LiteralPath $path) {
            [xml]$xml = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            if ($null -eq $xml.DocumentElement) { throw "Профиль Pulsar не содержит корневого XML-элемента: $path" }
            $profiles += [pscustomobject]@{ Path = $path; Xml = $xml }
        }
    }
    $configs = @((Join-Path $pulsarRoot 'Legacy.exe.config'), (Join-Path $pulsarRoot 'Interim.runtimeconfig.json'))
    foreach ($path in $configs) {
        foreach ($file in @($path, ($path + '.bak-before-gc'))) {
            if (-not (Test-Path -LiteralPath $file)) { continue }
            if ($path.EndsWith('.json')) {
                $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($json -isnot [pscustomobject] -or $json.runtimeOptions -isnot [pscustomobject]) { throw "Некорректный конфиг runtimeOptions: $file" }
                if ($null -ne $json.runtimeOptions.PSObject.Properties['configProperties'] -and $json.runtimeOptions.configProperties -isnot [pscustomobject]) { throw "Некорректный configProperties: $file" }
            } else {
                [xml]$cfg = Get-Content -LiteralPath $file -Raw -Encoding UTF8
                if ($null -eq $cfg.DocumentElement -or $cfg.DocumentElement.Name -ne 'configuration') { throw "Некорректный конфиг /configuration: $file" }
            }
        }
    }
    if ($ValidateOnly) { Write-Host 'Проверка удаления выполнена. Изменений нет.'; exit 0 }
    foreach ($folder in @('Legacy', 'Interim')) {
        $target = Join-Path $pulsarRoot ($folder + '\Local\' + $name)
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target
            Write-Host "Плагин удалён: $target"
        }
    }
    foreach ($entry in $profiles) {
        $xml = $entry.Xml
        $nodes = @($xml.DocumentElement.SelectNodes('Local/string') | Where-Object { $_.InnerText -eq $name })
        if ($nodes.Count -gt 0) {
            foreach ($n in $nodes) { [void]$n.ParentNode.RemoveChild($n) }
            $xml.Save($entry.Path)
            Write-Host 'Убран из профиля Pulsar.'
        }
    }
    foreach ($path in $configs) {
        $backup = $path + '.bak-before-gc'
        if (Test-Path -LiteralPath $backup) {
            Restore-GcConfiguration $path $backup
            Remove-Item -LiteralPath $backup
            Write-Host "Настройка GC снята: $path"
        }
        foreach ($metadata in @(($path + '.sentis-gc.sha256'), ($path + '.sentis-gc.merge'))) {
            if (Test-Path -LiteralPath $metadata) { Remove-Item -LiteralPath $metadata }
        }
    }
    foreach ($f in @($launcher, $shortcut, $oldLauncher, (Join-Path $pulsarRoot 'SentisClientOptimisation.ico'))) {
        if (Test-Path -LiteralPath $f) {
            Remove-Item -LiteralPath $f
            Write-Host "Удалён: $f"
        }
    }
    Write-Host ''
    Write-Host 'Готово. Игру снова можно запускать как обычно через Pulsar.'
} catch {
    $exitCode = 1
    Write-Host ''
    Write-Host ('Не удалено: ' + $_.Exception.Message) -ForegroundColor Red
}
Write-Host ''
if (-not $NonInteractive -and -not $ValidateOnly -and -not $env:SCO_NO_PAUSE) { [void](Read-Host 'Нажмите Enter, чтобы закрыть') }
exit $exitCode
