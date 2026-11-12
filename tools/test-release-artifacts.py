"""Exercise the workflow's real PowerShell publication block with a fake gh CLI.

No GitHub calls are made. Files and child-process environment are isolated in Hermes scratch.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/release.yml'
PLUGIN = 'SentisClientOptimisation'


def publish_script():
    lines = WORKFLOW.read_text(encoding='utf-8-sig').splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == '- name: Publish the release')
    start = next(i + 1 for i in range(start, len(lines)) if lines[i].strip() == 'run: |')
    block = []
    for line in lines[start:]:
        if line and not line.startswith('          '):
            break
        block.append(line[10:] if line else '')
    return '\n'.join(block)


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


class ReleaseAssetTests(unittest.TestCase):
    def exercise(self, exists, missing=None):
        scratch = Path(os.environ['LOCALAPPDATA']) / 'hermes/cache/scratch'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='release assets-[test]-', dir=scratch) as directory:
            root = Path(directory)
            installer = root / f'dist/{PLUGIN}-9.8.7-Setup.exe'
            dlls = [root / f'dist/{PLUGIN}/{name}' for name in (PLUGIN + '.dll', PLUGIN + '.Interim.dll')]
            assets = [installer, *dlls]
            for asset in assets:
                asset.parent.mkdir(parents=True, exist_ok=True)
                if asset.name != missing:
                    asset.write_bytes(b'Explicit test fixture, not a plugin binary')
            body = publish_script().replace('${{ github.ref_name }}', 'v9.8.7').replace('${{ steps.pack.outputs.installer }}', str(installer))
            script = f'''$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:PLUGIN = {quote(PLUGIN)}
$env:GITHUB_WORKSPACE = {quote(root)}
$script:Calls = New-Object 'Collections.Generic.List[object]'
function gh {{
    $script:Calls.Add([string[]]$args)
    if ($args[0] -eq 'release' -and $args[1] -eq 'view') {{
        $global:LASTEXITCODE = {0 if exists else 1}
    }} else {{ $global:LASTEXITCODE = 0 }}
}}
{body}
ConvertTo-Json -InputObject @($script:Calls.ToArray()) -Depth 5 -Compress
'''
            path = root / 'exercise.ps1'
            path.write_text(script, encoding='utf-8-sig')
            result = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(path)], capture_output=True, timeout=30)
            if missing:
                self.assertNotEqual(result.returncode, 0, 'A missing DLL must fail before publishing an incomplete release')
                return
            self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
            calls = json.loads(result.stdout.decode('utf-8-sig'))
            self.assertEqual(calls[0][:3], ['release', 'view', 'v9.8.7'])
            self.assertEqual(calls[1][:3], ['release', 'upload' if exists else 'create', 'v9.8.7'])
            for asset in assets:
                self.assertEqual(calls[1].count(str(asset)), 1, f'Missing or duplicate release asset: {asset.name}; {calls[1]}')
            return calls[1]

    def test_new_release_contains_exe_and_both_runtime_dlls(self):
        call = self.exercise(False)
        self.assertIn('--verify-tag', call)

    def test_existing_release_uploads_exe_and_both_runtime_dlls(self):
        call = self.exercise(True)
        self.assertIn('--clobber', call)

    def test_missing_interim_dll_prevents_publication(self):
        self.exercise(False, PLUGIN + '.Interim.dll')

    def test_actions_artifact_contains_both_runtime_dlls(self):
        workflow = WORKFLOW.read_text(encoding='utf-8-sig')
        artifact = workflow.split('uses: actions/upload-artifact@v4', 1)[1].split('- name: Publish the release', 1)[0]
        self.assertIn('steps.pack.outputs.installer', artifact)
        self.assertIn('dist/${{ env.PLUGIN }}/${{ env.PLUGIN }}.dll', artifact)
        self.assertIn('dist/${{ env.PLUGIN }}/SentisClientOptimisation.Interim.dll', artifact)


if __name__ == '__main__':
    unittest.main()
