"""Exercise the actual Inno EXE in an isolated APPDATA/Desktop (Windows).
Requires a built installer; never launches the game. Uses a temporary per-user
uninstall registration, refuses to run if this application is already registered.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import uuid
import winreg
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
KEY = r'Software\Microsoft\Windows\CurrentVersion\Uninstall\{58234B10-6052-47CC-A295-6B04B8389684}_is1'
parser = argparse.ArgumentParser()
parser.add_argument('--installer', type=Path, default=ROOT / 'dist/SentisClientOptimisation-0.2.1-Setup.exe')
parser.add_argument('--app-id', default='58234B10-6052-47CC-A295-6B04B8389684', help='Must match AppGuid used when compiling the tested EXE')
parser.add_argument('--archive', type=Path, required=True, help='Official Pulsar Windows archive for the existing-Pulsar test')
parser.add_argument('--download', action='store_true', help='Also exercise consented real network installation')
parser.add_argument('--runtime', choices=['Legacy', 'Interim'], default='Legacy')
parser.add_argument('--auto-detect', action='store_true', help='Keep only selected executable and test automatic detection')
parser.add_argument('--gui-consent', action='store_true', help='Exercise the real Yes/No prompt using Win32 buttons')
parser.add_argument('--check-progress', action='store_true', help='Observe real download labels and wizard responsiveness (requires --download --gui-consent)')
args = parser.parse_args()
uuid.UUID(args.app_id)
KEY = KEY.replace('58234B10-6052-47CC-A295-6B04B8389684', args.app_id)
if args.check_progress and not (args.download and args.gui_consent):
    parser.error('--check-progress requires --download --gui-consent')
assert args.installer.is_file(), 'Build the installer first'
try:
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, KEY):
        raise RuntimeError('Application already registered; do not replace a real installation during tests')
except FileNotFoundError:
    pass
scratch = Path.home() / 'AppData/Local/hermes/cache/scratch' / ('sco-exe-' + uuid.uuid4().hex)
scratch.mkdir(parents=True)
env = os.environ.copy()
env['APPDATA'] = str(scratch / 'Roaming')
env['LOCALAPPDATA'] = str(scratch / 'Local')
Path(env['LOCALAPPDATA']).mkdir()
env.pop('DOTNET_ROOT', None)
env.pop('DOTNET_ROOT_X64', None)
env['TEMP'] = env['TMP'] = str(scratch / 'temp')
Path(env['TEMP']).mkdir()
app = scratch / 'Installed'
desktop = scratch / 'Desktop'
desktop.mkdir()
pulsar = Path(env['APPDATA']) / 'Pulsar'
profile = pulsar / args.runtime / 'Profiles/Current.xml'
config = pulsar / ('Legacy.exe.config' if args.runtime == 'Legacy' else 'Interim.runtimeconfig.json')
link = desktop / 'Space Engineers (Pulsar).lnk'
dll = pulsar / args.runtime / 'Local/SentisClientOptimisation.dll'
icon = pulsar / 'SentisClientOptimisation.ico'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def setup(expected=0, consent=False):
    command = [str(args.installer), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
               '/RUNTIME=' + args.runtime, '/DIR=' + str(app), '/DESKTOP=' + str(desktop), '/LOG=' + str(scratch / ('install-' + uuid.uuid4().hex + '.log'))]
    if consent:
        command.append('/INSTALLPULSAR=1')
    elif args.auto_detect:
        command.remove('/RUNTIME=' + args.runtime)
    if args.gui_consent and (consent or not args.check_progress) and not (pulsar / (args.runtime + '.exe')).exists():
        import ctypes
        from ctypes import wintypes
        import time
        command.remove('/VERYSILENT')
        command.extend(['/SP-', '/LANG=russian'])
        process = subprocess.Popen(command, env=env)
        user32 = ctypes.windll.user32
        user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
        user32.GetDlgItem.argtypes = [wintypes.HWND, ctypes.c_int]
        user32.IsWindowVisible.argtypes = [wintypes.HWND]
        user32.IsWindowEnabled.argtypes = [wintypes.HWND]
        user32.GetDlgItem.restype = wintypes.HWND
        user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
        callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        def text(hwnd):
            buffer = ctypes.create_unicode_buffer(8192)
            user32.GetWindowTextW(hwnd, buffer, len(buffer))
            return buffer.value
        deadline = time.monotonic() + 240
        import psutil
        user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        clicked = False
        progress_samples = []
        user32.SendMessageTimeoutW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM, wintypes.UINT, wintypes.UINT, ctypes.POINTER(ctypes.c_size_t)]
        user32.SendMessageTimeoutW.restype = wintypes.LPARAM
        while time.monotonic() < deadline and process.poll() is None:
            windows = []
            family = {process.pid}
            try:
                family.update(p.pid for p in psutil.Process(process.pid).children(recursive=True))
            except psutil.NoSuchProcess:
                pass
            buttons = []
            main_windows = []
            @callback_type
            def collect(hwnd, param):
                pid = wintypes.DWORD()
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                if pid.value not in family:
                    return True
                main_windows.append(hwnd)
                children = []
                visible_text = []
                @callback_type
                def child(ch, data):
                    children.append(text(ch))
                    if user32.IsWindowVisible(ch):
                        visible_text.append(text(ch))
                    if user32.IsWindowVisible(ch) and user32.IsWindowEnabled(ch):
                        label = text(ch).replace('&', '').strip()
                        if label in ('Далее', 'Далее >', 'Next', 'Next >', 'Установить', 'Install', 'Завершить', 'Finish'):
                            buttons.append(ch)
                    return True
                user32.EnumChildWindows(hwnd, child, 0)
                if args.check_progress and 'Загрузка Pulsar' in visible_text:
                    for label in visible_text:
                        if 'МБ' in label:
                            result = ctypes.c_size_t()
                            responsive = bool(user32.SendMessageTimeoutW(hwnd, 0, 0, 0, 0x0002, 500, ctypes.byref(result)))
                            progress_samples.append({'detail': label, 'enabled': bool(user32.IsWindowEnabled(hwnd)), 'responsive': responsive})
                if any('Pulsar ' in value and 'не найден.' in value for value in children):
                    windows.append((hwnd, children))
                return True
            user32.EnumWindows(collect, 0)
            if windows and not clicked:
                hwnd, children = windows[0]
                choice = 'yes' if consent else 'no'
                (scratch / ('consent-' + choice + '.json')).write_text(json.dumps(children, ensure_ascii=False), encoding='utf-8')
                button = user32.GetDlgItem(hwnd, 6 if consent else 7)
                assert button, 'Yes/No button is missing'
                user32.PostMessageW(button, 0x00F5, 0, 0)  # BM_CLICK
                clicked = True
            elif clicked and not consent:
                for hwnd in main_windows:
                    user32.PostMessageW(hwnd, 0x0010, 0, 0)  # WM_CLOSE after refusal
            elif buttons:
                user32.PostMessageW(buttons[0], 0x00F5, 0, 0)
            time.sleep(0.2)
        if not clicked:
            process.terminate()
            raise AssertionError('Real Pulsar consent dialog was not observed')
        code = process.wait(timeout=240)
        if args.check_progress and consent and code == 0:
            (scratch / 'progress-ui.json').write_text(json.dumps(progress_samples, ensure_ascii=False, indent=2), encoding='utf-8')
            details = {sample['detail'] for sample in progress_samples}
            assert len(details) >= 2, f'Download UI did not show changing byte counts: {progress_samples}'
            assert all(sample['enabled'] and sample['responsive'] for sample in progress_samples), progress_samples
            import re
            percentages = {int(match.group(1)) for detail in details if (match := re.search(r'\((\d+)%\)', detail))}
            assert len(percentages) >= 2 and any(0 < value < 100 for value in percentages), details
            print('PASS live download UI: changing MB/percent, enabled responsive wizard;', len(details), 'distinct samples', flush=True)
        assert (code == 0) == (expected == 0), f'setup exit {code}; logs: {scratch}'
        return code
    result = subprocess.run(command, env=env, timeout=240)
    assert (result.returncode == 0) == (expected == 0), f'setup exit {result.returncode}; logs: {scratch}'
    return result.returncode

def uninstall():
    exe = app / 'unins000.exe'
    result = subprocess.run([str(exe), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
                             '/DESKTOP=' + str(desktop), '/LOG=' + str(scratch / ('uninstall-' + uuid.uuid4().hex + '.log'))], env=env, timeout=90)
    assert result.returncode == 0, f'uninstall exit {result.returncode}'
    assert not dll.exists() and not icon.exists() and not link.exists()
    # Inno removes its own executable via a short-lived helper after exit.
    import time
    deadline = time.monotonic() + 15
    while (app / 'unins000.exe').exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    assert not (app / 'unins000.exe').exists()
    assert (pulsar / (args.runtime + '.exe')).exists(), 'Uninstall must preserve Pulsar'
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, KEY):
            raise AssertionError('Uninstall registration remains')
    except FileNotFoundError:
        pass

def verify():
    payload = 'SentisClientOptimisation.Interim.dll' if args.runtime == 'Interim' else 'SentisClientOptimisation.dll'
    assert digest(dll) == digest(app / payload), f'{args.runtime} installed the wrong runtime payload'
    assert digest(app / 'SentisClientOptimisation.dll') != digest(app / 'SentisClientOptimisation.Interim.dll'), 'Runtime payloads must differ'
    assert digest(icon) == digest(ROOT / 'package/SentisClientOptimisation.ico')
    xml = ET.parse(profile)
    assert [n.text for n in xml.findall('./Local/string')].count('SentisClientOptimisation.dll') == 1
    if args.runtime == 'Legacy':
        runtime = ET.parse(config).find('./runtime')
        for name, value in [('gcServer', 'true'), ('gcConcurrent', 'true'), ('GCHeapCount', '4'), ('GCNoAffinitize', 'true')]:
            assert runtime.find(name).get('enabled') == value
    else:
        props = json.loads(config.read_text(encoding='utf-8-sig'))['runtimeOptions']['configProperties']
        for key, value in [('System.GC.Server', True), ('System.GC.Concurrent', True), ('System.GC.HeapCount', 4), ('System.GC.NoAffinitize', True)]:
            assert props[key] == value
    launcher = (pulsar / 'SentisClientOptimisation-launch.cmd').read_text()
    assert 'COMPlus_GCgen0MaxBudget=2000000' in launcher
    assert args.runtime + '.exe' in launcher
    quote = lambda s: "'" + str(s).replace("'", "''") + "'"
    ps = "$s=(New-Object -ComObject WScript.Shell).CreateShortcut(" + quote(link) + "); @{Target=$s.TargetPath;Icon=$s.IconLocation;Working=$s.WorkingDirectory}|ConvertTo-Json -Compress"
    result = subprocess.run(['powershell', '-NoProfile', '-Command', ps], env=env, capture_output=True, timeout=30)
    assert result.returncode == 0, result.stderr
    shortcut = json.loads(result.stdout.decode('utf-8-sig'))
    assert shortcut['Icon'].lower() == (str(icon) + ',0').lower(), shortcut
    assert shortcut['Target'].lower() == str(pulsar / 'SentisClientOptimisation-launch.cmd').lower()
    assert shortcut['Working'].lower() == str(pulsar).lower()

# No automatic network download without explicit consent.
code = setup(expected=1)
assert not pulsar.exists() and not app.exists() and not link.exists()
print('PASS missing Pulsar without consent:', code, flush=True)

# Existing Pulsar; test actual EXE installation, upgrade/repeat and uninstaller.
with zipfile.ZipFile(args.archive) as archive:
    archive.extractall(pulsar)
if args.auto_detect:
    other = 'Interim' if args.runtime == 'Legacy' else 'Legacy'
    (pulsar / (other + '.exe')).unlink()
profile.parent.mkdir(parents=True, exist_ok=True)
profile.write_text('<Profile><Name>Current</Name><GitHub/><DevFolder/><Local><string>Other.dll</string></Local><Mods/></Profile>', encoding='utf-8')
original = digest(config)
try:
    # A directory in place of the .lnk makes COM shortcut saving fail only
    # after DLL/profile/GC writes, exercising the EXE's external rollback.
    before_profile = digest(profile)
    link.mkdir()
    setup(expected=1)
    assert link.is_dir(), 'Preexisting blocker was modified'
    assert digest(config) == original and digest(profile) == before_profile
    assert not dll.exists() and not icon.exists()
    assert not (pulsar / 'SentisClientOptimisation-launch.cmd').exists()
    assert not (app / 'unins000.exe').exists()
    link.rmdir()
    print('PASS EXE post-mutation failure restores DLL/profile/GC/shortcut state', flush=True)
    setup()
    verify()
    setup()
    verify()
    assert ET.parse(profile).find('./Local/string').text == 'Other.dll'
    uninstall()
    assert digest(config) == original
    assert ET.parse(profile).find('./Local/string').text == 'Other.dll'
    print('PASS EXE install/reinstall/uninstall with existing Pulsar', flush=True)
finally:
    if (app / 'unins000.exe').exists():
        uninstall()

if args.download:
    # Fresh sandbox: download and install latest official Pulsar without launching it.
    import shutil
    shutil.rmtree(pulsar)
    try:
        setup(consent=True)
        # Pulsar falls back to Legacy data unless an Interim data directory exists.
        if args.runtime == 'Interim' and not (pulsar / 'Interim').exists():
            profile = pulsar / 'Legacy/Profiles/Current.xml'
            dll = pulsar / 'Legacy/Local/SentisClientOptimisation.dll'
        verify()
        assert (pulsar / 'Libraries/Legacy/0Harmony.dll').is_file()
        uninstall()
        print('PASS EXE consented network Pulsar install + plugin + uninstall', flush=True)
    finally:
        if (app / 'unins000.exe').exists():
            uninstall()
print('PASS; logs:', scratch)
