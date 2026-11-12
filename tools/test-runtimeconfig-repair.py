"""Offline repair regression tests; all writes remain below Hermes scratch."""
from pathlib import Path
import json
import os
import subprocess
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'package/repair-interim-runtimeconfig.ps1'
TEMPLATE = ROOT / 'package/Interim.runtimeconfig.json'

class RepairTests(unittest.TestCase):
    def setUp(self):
        self.root = Path.home() / 'AppData/Local/hermes/cache/scratch' / ('sco-repair-' + uuid.uuid4().hex)
        self.pulsar = self.root / 'Roaming/Pulsar'
        self.pulsar.mkdir(parents=True)
        self.config = self.pulsar / 'Interim.runtimeconfig.json'
        self.backup = Path(str(self.config) + '.bak-before-gc')
        (self.pulsar / 'Interim.exe').write_bytes(b'never launched')
        self.env = os.environ.copy()
        for key, folder in [('APPDATA', 'Roaming'), ('LOCALAPPDATA', 'Local'), ('TEMP', 'Temp'), ('TMP', 'Temp')]:
            path = self.root / folder
            path.mkdir(exist_ok=True)
            self.env[key] = str(path)

    def run_repair(self, *extra, expected=0):
        result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(HELPER), *extra], env=self.env, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout.decode(errors='replace') + result.stderr.decode(errors='replace'))

    def test_missing_is_recovered_from_packaged_template_offline(self):
        self.run_repair()
        self.assertEqual(self.config.read_bytes(), TEMPLATE.read_bytes())

    def test_existing_bytes_are_never_replaced(self):
        data = b'{"runtimeOptions":{"tfm":"net11.0","framework":{"name":"Microsoft.NETCore.App","version":"11.0.0"}},"custom":true}\n'
        self.config.write_bytes(data)
        self.run_repair()
        self.assertEqual(self.config.read_bytes(), data)

    def test_valid_backup_is_preferred_and_preserved(self):
        data = b'{"runtimeOptions":{"tfm":"net10.0","frameworks":[{"name":"Microsoft.NETCore.App","version":"10.0.1"},{"name":"Microsoft.WindowsDesktop.App","version":"10.0.1"}],"configProperties":{"custom":true}}}\n'
        self.backup.write_bytes(data)
        self.run_repair()
        self.assertEqual(self.config.read_bytes(), data)
        self.assertEqual(self.backup.read_bytes(), data)

    def test_validate_only_does_not_restore_missing_config(self):
        self.run_repair('-ValidateOnly')
        self.assertFalse(self.config.exists())
        self.assertEqual(list(self.pulsar.iterdir()), [self.pulsar / 'Interim.exe'])

    def test_invalid_backup_fails_without_changes(self):
        self.backup.write_bytes(b'{"runtimeOptions":{}}')
        self.run_repair(expected=1)
        self.assertFalse(self.config.exists())
        self.assertEqual(self.backup.read_bytes(), b'{"runtimeOptions":{}}')

    def test_invalid_existing_is_not_overwritten(self):
        self.config.write_bytes(b'broken')
        self.run_repair(expected=1)
        self.assertEqual(self.config.read_bytes(), b'broken')

    def test_target_directory_is_rejected(self):
        self.config.mkdir()
        self.run_repair(expected=1)
        self.assertTrue(self.config.is_dir())

    def test_repaired_file_survives_real_transaction_rollback(self):
        self.run_repair()
        original = self.config.read_bytes()
        desktop = self.root / 'Desktop'
        desktop.mkdir()
        state = self.root / 'transaction'
        def transaction(action):
            result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(ROOT / 'package/install-transaction.ps1'), '-Action', action, '-StatePath', str(state), '-Desktop', str(desktop)], env=self.env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
        transaction('Begin')
        self.config.write_bytes(b'failed installation mutation')
        transaction('Rollback')
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse(state.exists())

    def test_rollback_overwrites_existing_config_without_deleting_it(self):
        import ctypes
        from ctypes import wintypes
        self.run_repair()
        original = self.config.read_bytes()
        desktop = self.root / 'Desktop'
        desktop.mkdir()
        state = self.root / 'transaction'
        command = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(ROOT / 'package/install-transaction.ps1'), '-StatePath', str(state), '-Desktop', str(desktop)]
        subprocess.run(command + ['-Action', 'Begin'], env=self.env, check=True, capture_output=True, timeout=30)
        self.config.write_bytes(b'failed install mutation')
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        # Permit read/write, but not FILE_SHARE_DELETE. Rollback must not unlink it.
        handle = kernel.CreateFileW(str(self.config), 0x80000000, 3, None, 3, 0, None)
        self.assertNotEqual(handle, wintypes.HANDLE(-1).value, ctypes.get_last_error())
        try:
            result = subprocess.run(command + ['-Action', 'Rollback'], env=self.env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.config.read_bytes(), original)
        finally:
            kernel.CloseHandle(handle)

    def test_uninstall_preserves_recovered_bytes_when_backup_is_identical(self):
        self.run_repair()
        original = self.config.read_bytes()
        self.backup.write_bytes(original)
        profile = self.pulsar / 'Legacy/Profiles/Current.xml'
        profile.parent.mkdir(parents=True)
        profile.write_text('<Profile><Local/></Profile>', encoding='utf-8')
        desktop = self.root / 'Desktop'
        desktop.mkdir()
        result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(ROOT / 'package/uninstall.ps1'), '-Runtime', 'Interim', '-NonInteractive', '-Desktop', str(desktop)], env=self.env, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse(self.backup.exists())

    def test_parent_junction_is_rejected(self):
        target = self.root / 'outside'
        target.mkdir()
        (target / 'Interim.exe').write_bytes(b'never launched')
        (self.pulsar / 'Interim.exe').unlink()
        self.pulsar.rmdir()
        subprocess.run(['cmd.exe', '/c', 'mklink', '/J', str(self.pulsar), str(target)], check=True, capture_output=True, timeout=30)
        try:
            self.run_repair(expected=1)
            self.assertFalse((target / self.config.name).exists())
        finally:
            os.rmdir(self.pulsar)

if __name__ == '__main__':
    unittest.main()
