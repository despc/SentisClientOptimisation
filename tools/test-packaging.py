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

    def test_unicode_shortcut_helper_is_shipped_and_extracted(self):
        for file in ('tools/release.ps1', 'installer/SentisClientOptimisation.iss', 'package/install.ps1'):
            text = (ROOT / file).read_text(encoding='utf-8-sig')
            self.assertIn('shortcut.ps1', text)
        text = (ROOT / 'installer/SentisClientOptimisation.iss').read_text(encoding='utf-8-sig')
        self.assertIn("ExtractTemporaryFile('shortcut.ps1')", text)

    def test_dependency_progress_is_streamed_to_the_wizard(self):
        text = (ROOT / 'installer/SentisClientOptimisation.iss').read_text(encoding='utf-8-sig')
        self.assertIn('ExecAndLogOutput', text)
        self.assertIn('-ReportProgress', text)
        self.assertIn('@DependencyOutput', text)
        self.assertIn('Progress.iss', text)
        progress = ROOT / 'installer/Progress.iss'
        self.assertTrue(progress.exists(), 'Wizard progress renderer is missing')
        renderer = progress.read_text(encoding='utf-8-sig')
        self.assertIn('SCO_PROGRESS|', renderer)
        self.assertIn('CreateOutputProgressPage', text)
        self.assertIn('npbstMarquee', renderer)
        self.assertIn('EnableDependencyWindow(WizardForm.Handle, True)', renderer)

    def test_dual_runtime_payloads_are_built_staged_and_extracted(self):
        release = (ROOT / 'tools/release.ps1').read_text(encoding='utf-8-sig')
        for framework in ('net48', 'net10.0'):
            self.assertIn(framework, release)
        self.assertIn('-p:TargetFramework=', release)
        self.assertIn('-f $framework', release)
        self.assertIn('-p:AppendTargetFrameworkToOutputPath=false', release)
        self.assertIn('build\\$Plugin\\$framework', release)
        self.assertIn("Copy-Item -LiteralPath $payloads['net48'] -Destination (Join-Path $stage 'SentisClientOptimisation.dll')", release)
        self.assertIn("Copy-Item -LiteralPath $payloads['net10.0'] -Destination (Join-Path $stage 'SentisClientOptimisation.Interim.dll')", release)
        self.assertIn('SentisClientOptimisation.Interim.dll', release)
        installer = (ROOT / 'installer/SentisClientOptimisation.iss').read_text(encoding='utf-8-sig')
        self.assertIn('Source: "{#PayloadDir}\\SentisClientOptimisation.Interim.dll"; DestDir: "{app}"', installer)
        self.assertIn("ExtractTemporaryFile('SentisClientOptimisation.Interim.dll')", installer)
        install = (ROOT / 'package/install.ps1').read_text(encoding='utf-8-sig')
        self.assertIn("if ($Runtime -eq 'Interim') { 'SentisClientOptimisation.Interim.dll' } else { $name }", install)
        self.assertIn('$source = Join-Path $here $payloadName', install)
        self.assertLess(install.index('foreach ($file in @($source,'), install.index('if ($ValidateOnly)'))
        self.assertIn('Copy-Item -LiteralPath $source $target -Force', install)
        self.assertIn('dotnet-version: 10.0.x', (ROOT / '.github/workflows/release.yml').read_text(encoding='utf-8-sig'))

    def test_multisize_icon(self):
        import struct
        data = (ROOT / 'package' / 'SentisClientOptimisation.ico').read_bytes()
        reserved, kind, count = struct.unpack_from('<HHH', data)
        self.assertEqual((reserved, kind), (0, 1))
        sizes = {data[6 + 16 * i] or 256 for i in range(count)}
        self.assertTrue({16, 32, 48, 256}.issubset(sizes))

if __name__ == '__main__':
    unittest.main()
