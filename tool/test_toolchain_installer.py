#!/usr/bin/env python3
"""Exercise the pinned installer without network access or native Wasm execution."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ToolchainInstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'tool').mkdir()
        shutil.copy2(ROOT / 'tool/ensure_toolchains.sh', self.root / 'tool')
        self.downloads = self.root / '.toolchains/.downloads'
        self.downloads.mkdir(parents=True)
        self.mock = self.root / 'mock-bin'
        self.mock.mkdir()
        self.origins = self.root / 'official-archives'
        self.origins.mkdir()
        self.requests = self.root / 'requests.jsonl'
        self.lock = json.loads((ROOT / 'tool/toolchain.lock.json').read_text())
        self.platform = 'linux-x86_64'
        for key in ['wabt', 'wasm_tools']:
            asset = self.lock[key]['assets'][self.platform]
            payload = io.BytesIO()
            with tarfile.open(fileobj=payload, mode='w:gz') as archive:
                names = ['wasm-interp', 'wasm-validate', 'wat2wasm', 'wast2json'] if key == 'wabt' else ['wasm-tools']
                for name in names:
                    version = self.lock[key]['version']
                    output = version if key == 'wabt' else 'wasm-tools ' + version + ' (fixture)'
                    data = ('#!/bin/sh\necho "' + output + '"\n').encode()
                    entry = tarfile.TarInfo('release/bin/' + name)
                    entry.size, entry.mode = len(data), 0o755
                    archive.addfile(entry, io.BytesIO(data))
            data = payload.getvalue()
            (self.origins / asset['name']).write_bytes(data)
            asset['sha256'] = hashlib.sha256(data).hexdigest()
        self.save_lock()
        self.write_mock('uname', '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n')
        self.write_mock('curl', '''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
url = next(arg for arg in args if arg.startswith('https://'))
pathlib.Path(os.environ['REQUEST_LOG']).open('a').write(json.dumps({'url': url}) + '\\n')
output = pathlib.Path(args[args.index('-o') + 1])
if 'api.github.com' in url:
    limited = bool(os.environ.get('API_UNAVAILABLE'))
    if limited:
        output.write_text('{"message":"API rate limit exceeded"}')
    else:
        lock = json.loads(pathlib.Path(os.environ['MOCK_LOCK']).read_text())
        key = 'wabt' if '/WebAssembly/wabt/' in url else 'wasm_tools'
        asset = lock[key]['assets']['linux-x86_64']
        repo = 'WebAssembly/wabt' if key == 'wabt' else 'bytecodealliance/wasm-tools'
        tag = lock[key]['version'] if key == 'wabt' else 'v' + lock[key]['version']
        output.write_text(json.dumps({'assets': [{'name': asset['name'],
            'browser_download_url': 'https://github.com/' + repo + '/releases/download/' + tag + '/' + asset['name'],
            'digest': 'sha256:' + asset['sha256'] if asset.get('sha256') else None}]}))
    if '-D' in args:
        pathlib.Path(args[args.index('-D') + 1]).write_text('HTTP/2 ' + ('403' if limited else '200') + '\\nx-ratelimit-remaining: ' + ('0' if limited else '59') + '\\n')
    if '-w' in args:
        print('403' if limited else '200', end='')
        sys.exit(0)
    sys.exit(22 if limited else 0)
if os.environ.get('FAIL_DOWNLOAD'):
    print('curl: HTTP 403', file=sys.stderr)
    sys.exit(22)
if not (url.startswith('https://github.com/WebAssembly/wabt/releases/download/1.0.41/') or
        url.startswith('https://github.com/bytecodealliance/wasm-tools/releases/download/v1.254.0/')):
    sys.exit(22)
shutil.copyfile(pathlib.Path(os.environ['OFFICIAL_ARCHIVES']) / url.rsplit('/', 1)[1], output)
''')
        self.env = dict(os.environ, PATH=str(self.mock) + os.pathsep + os.environ['PATH'],
                        REQUEST_LOG=str(self.requests), OFFICIAL_ARCHIVES=str(self.origins))
        self.env['MOCK_LOCK'] = str(self.root / 'tool/toolchain.lock.json')
        self.env.pop('WABT_VERSION', None)
        self.env.pop('WASM_TOOLS_VERSION', None)

    def write_mock(self, name, text):
        path = self.mock / name
        path.write_text(text)
        path.chmod(0o755)

    def save_lock(self):
        (self.root / 'tool/toolchain.lock.json').write_text(json.dumps(self.lock))

    def run_installer(self, *args):
        return subprocess.run(['bash', str(self.root / 'tool/ensure_toolchains.sh'), *args],
                              env=self.env, text=True, capture_output=True)

    def cache_archives(self):
        for archive in self.origins.iterdir():
            shutil.copy2(archive, self.downloads / archive.name)

    def test_cold_install_uses_official_pinned_archives_without_api(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        urls = [json.loads(line)['url'] for line in self.requests.read_text().splitlines()]
        self.assertEqual(len(urls), 2)
        self.assertTrue(all('/releases/download/' in url for url in urls))
        self.assertEqual(self.run_installer('--check').returncode, 0)

    def test_install_is_independent_of_metadata_rate_limits(self):
        self.env['API_UNAVAILABLE'] = '1'
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        urls = [json.loads(line)['url'] for line in self.requests.read_text().splitlines()]
        self.assertTrue(all('api.github.com' not in url for url in urls))

    def test_verified_archive_cache_reinstalls_offline(self):
        self.cache_archives()
        self.env['FAIL_DOWNLOAD'] = '1'
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.requests.exists())
        self.assertEqual(self.run_installer('--check').returncode, 0)

    def test_corrupt_cache_is_rejected_before_extraction(self):
        self.cache_archives()
        asset = self.lock['wabt']['assets'][self.platform]
        (self.downloads / asset['name']).write_bytes(b'corrupt cache')
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Checksum verification failed', result.stderr)
        self.assertFalse((self.root / '.toolchains/bin/wasm-interp').exists())

    def test_missing_digest_is_rejected(self):
        del self.lock['wabt']['assets'][self.platform]['sha256']
        self.save_lock()
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('digest', result.stderr.lower())
        self.assertFalse(self.requests.exists())

    def test_download_failure_is_not_hidden(self):
        self.env['FAIL_DOWNLOAD'] = '1'
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('403', result.stderr)
        self.assertFalse((self.root / '.toolchains/bin/wasm-interp').exists())

    def test_version_drift_is_rejected_before_download(self):
        self.env['WABT_VERSION'] = '1.0.40'
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('version drift', result.stderr.lower())
        self.assertFalse(self.requests.exists())

    def test_cached_binaries_are_not_trusted_over_verified_archives(self):
        self.cache_archives()
        binaries = self.root / '.toolchains/bin'
        binaries.mkdir()
        for name in ['wasm-interp', 'wast2json', 'wasm-tools']:
            path = binaries / name
            path.write_text('#!/bin/sh\necho stale-unverified\n')
            path.chmod(0o755)
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.run_installer('--check').returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
