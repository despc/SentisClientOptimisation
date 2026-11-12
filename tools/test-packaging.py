"""Packaging contract checks; runtime lifecycle is covered by test-install.ps1."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PackagingTests(unittest.TestCase):
    def test_per_user_executable_installer(self):
        path = ROOT / 'installer' / 'SentisClientOptimisation.iss'
        self.assertTrue(path.is_file(), 'EXE installer definition is missing')
        text = path.read_text(encoding='utf-8-sig')
        for expected in ('PrivilegesRequired=lowest', 'SetupIconFile=', 'PrepareToInstall',
                         'InitializeUninstall', 'ExecAndCaptureOutput', '-ValidateOnly',
                         'SentisClientOptimisation.ico', 'CurUninstallStepChanged', 'Abort;'):
            self.assertIn(expected, text)

    def test_release_emits_exe_not_zip(self):
        text = (ROOT / 'tools' / 'release.ps1').read_text(encoding='utf-8-sig')
        self.assertNotIn('Compress-Archive', text)
        self.assertIn('ISCC', text)
        self.assertIn('installer=', text)
        self.assertIn('-Setup.exe', text)

    def test_ci_publishes_installer(self):
        text = (ROOT / '.github' / 'workflows' / 'release.yml').read_text(encoding='utf-8-sig')
        self.assertNotIn('outputs.zip', text)
        self.assertIn('steps.pack.outputs.installer', text)
        self.assertIn('Inno Setup', text)

    def test_legacy_and_interim_runtime_selection(self):
        text = (ROOT / 'installer' / 'SentisClientOptimisation.iss').read_text(encoding='utf-8-sig')
        self.assertIn('CreateInputOptionPage', text)
        self.assertIn('Interim', text)
        self.assertIn('install-dotnet.ps1', text)
        self.assertIn('-Runtime', text)
        self.assertNotIn("if not FileExists(GetEnv('APPDATA') + '\\\\Pulsar\\\\Legacy.exe')", text)

    def test_multisize_icon(self):
        import struct
        data = (ROOT / 'package' / 'SentisClientOptimisation.ico').read_bytes()
        reserved, kind, count = struct.unpack_from('<HHH', data)
        self.assertEqual((reserved, kind), (0, 1))
        sizes = {data[6 + 16 * i] or 256 for i in range(count)}
        self.assertTrue({16, 32, 48, 256}.issubset(sizes))

if __name__ == '__main__':
    unittest.main()
