import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOWNLOAD = 'https://github.com/w9315273/luci-app-pulse/releases/download/v1.2.3/'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='pulse-installer-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.assets = self.root / 'assets'
        self.assets.mkdir()
        self.work = self.root / 'work'
        self.work.mkdir()
        self.calls = self.root / 'calls'
        self.calls.write_text('')
        self.cache = self.root / 'cache'
        self.cache.write_text('existing LuCI cache')

        mock = self.root / 'command.py'
        shutil.copyfile(ROOT / 'tests/fixtures/installer-command.py', mock)
        mock.chmod(0o755)
        for name in ('id', 'uclient-fetch', 'jsonfilter', 'apk', 'mock-service'):
            (self.bin / name).symlink_to(mock)
        # PATH 仅允许桩命令和少量标准工具, 桩不可执行时也不会误用宿主机的 apk.
        for name in ('grep', 'wc', 'sha256sum', 'mktemp', 'rm'):
            command = shutil.which(name)
            self.assertIsNotNone(command, f'缺少测试工具: {name}')
            (self.bin / name).symlink_to(command)
        (self.bin / 'python3').symlink_to(sys.executable)
        self.env = dict(os.environ, PATH=str(self.bin), FIXTURES=str(self.assets),
                        CALLS=str(self.calls), TEST_TMPDIR=str(self.work), TEST_CACHE=str(self.cache))
        for name in ('MOCK_UID', 'FAIL_DOWNLOAD', 'APK_FAIL'):
            self.env.pop(name, None)

        # 仅将固定系统路径重定向至临时目录, 下载选择和校验仍执行原始脚本.
        source = (ROOT / 'install.sh').read_text()
        replacements = {
            'mktemp -d /tmp/pulse-install.XXXXXX': 'mktemp -d "$TEST_TMPDIR/pulse-install.XXXXXX"',
            '/etc/init.d/pulse-traffic': 'mock-service pulse-traffic',
            '/etc/init.d/rpcd': 'mock-service rpcd',
            'rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache/*': 'rm -f "$TEST_CACHE"',
        }
        for old, new in replacements.items():
            self.assertIn(old, source, f'安装脚本边界已变更: {old}')
            source = source.replace(old, new)
        self.assertNotIn('/etc/init.d/', source)
        self.assertNotIn('/tmp/', source)
        self.script = self.root / 'install.sh'
        self.script.write_text(source)
        self.names = ['luci-app-pulse-1.2.3-r2.apk', 'luci-i18n-pulse-ko-0.123.apk',
                      'luci-i18n-pulse-zh-cn-0.123.apk', 'luci-i18n-pulse-fr-0.123.apk']
        self.metadata(self.names)

    def metadata(self, names):
        assets = []
        for name in names:
            content = ('fixture: ' + name).encode()
            (self.assets / name).write_bytes(content)
            assets.append({'name': name, 'browser_download_url': DOWNLOAD + name,
                           'digest': 'sha256:' + hashlib.sha256(content).hexdigest()})
        self.write_metadata(assets)
        return assets

    def write_metadata(self, assets):
        (self.assets / 'release.json').write_text(json.dumps({'assets': assets}))

    def execute(self, success):
        result = subprocess.run(['/bin/sh', str(self.script)], env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertEqual(list(self.work.iterdir()), [], '临时下载文件未清理')
        return result, [json.loads(line) for line in self.calls.read_text().splitlines()]

    def assert_not_installed(self, calls):
        self.assertFalse(any(call[0] in ('apk', 'mock-service') for call in calls), calls)
        self.assertTrue(self.cache.exists())

    def test_install_all_available_translations_and_ignore_other_assets(self):
        """安装主包和所有可用翻译包, 忽略无关资产."""
        self.metadata(self.names + ['luci-app-other-1.0.apk', 'SHA256SUMS'])
        _, calls = self.execute(True)
        installs = [call for call in calls if call[0] == 'apk']
        self.assertEqual(len(installs), 1)
        self.assertEqual([Path(name).name for name in installs[0][3:]], self.names)
        downloaded = [call[-1].rsplit('/', 1)[-1] for call in calls if call[0] == 'uclient-fetch']
        self.assertEqual(downloaded, ['latest', *self.names])
        self.assertEqual([call for call in calls if call[0] == 'mock-service'], [
            ['mock-service', 'pulse-traffic', 'enable'], ['mock-service', 'pulse-traffic', 'restart'],
            ['mock-service', 'rpcd', 'reload']])
        self.assertLess(calls.index(installs[0]), next(i for i, call in enumerate(calls) if call[0] == 'mock-service'))
        self.assertFalse(self.cache.exists())

    def test_release_without_translation_assets(self):
        """没有翻译包时仍能安装主包."""
        self.metadata(self.names[:1])
        _, calls = self.execute(True)
        install = next(call for call in calls if call[0] == 'apk')
        self.assertEqual([Path(name).name for name in install[3:]], self.names[:1])

    def test_failed_install_does_not_restart_services_or_clear_cache(self):
        """安装失败时不重启服务或清除缓存."""
        self.env['APK_FAIL'] = '1'
        result, calls = self.execute(False)
        self.assertTrue(any(call[0] == 'apk' for call in calls))
        self.assertFalse(any(call[0] == 'mock-service' for call in calls))
        self.assertTrue(self.cache.exists())
        self.assertNotIn('Done.', result.stdout)

    def test_failed_download_never_installs_partial_packages(self):
        """下载失败时不安装不完整的包集合."""
        for name in ('release.json', self.names[-1]):
            with self.subTest(name=name):
                self.calls.write_text('')
                self.env['FAIL_DOWNLOAD'] = name
                _, calls = self.execute(False)
                self.assert_not_installed(calls)

    def test_invalid_or_missing_digest_never_installs(self):
        """摘要缺失, 格式错误或校验不符时终止安装."""
        for digest in (None, 'sha256:123', 'sha256:' + 'z' * 64, 'sha256:' + '0' * 64, 'md5:' + '0' * 32):
            with self.subTest(digest=digest):
                self.calls.write_text('')
                assets = self.metadata(self.names)
                assets[-1]['digest'] = digest
                self.write_metadata(assets)
                _, calls = self.execute(False)
                self.assert_not_installed(calls)

    def test_missing_or_ambiguous_main_package_never_installs(self):
        """主包缺失或存在多个候选时终止安装."""
        for names in ([], self.names[1:], self.names + ['luci-app-pulse-9.9.9-r1.apk']):
            with self.subTest(names=names):
                self.calls.write_text('')
                self.metadata(names)
                _, calls = self.execute(False)
                self.assert_not_installed(calls)

    def test_unrelated_download_host_is_rejected(self):
        """拒绝无关域名的下载地址."""
        assets = self.metadata(self.names[:1])
        assets[0]['browser_download_url'] = 'https://example.invalid/' + self.names[0]
        self.write_metadata(assets)
        _, calls = self.execute(False)
        self.assert_not_installed(calls)

    def test_non_root_install_stops_before_download(self):
        """非 root 用户在下载前终止安装."""
        self.env['MOCK_UID'] = '1000'
        _, calls = self.execute(False)
        self.assertEqual(calls, [['id', '-u']])
