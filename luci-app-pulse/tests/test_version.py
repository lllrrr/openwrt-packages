import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='pulse-version-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / 'package'
        self.repo.mkdir()
        for name in ('generate-version.sh', 'Makefile'):
            shutil.copyfile(ROOT / name, self.repo / name)
        self.output = self.repo / 'htdocs/luci-static/resources/view/pulse/index.js'
        self.output.parent.mkdir(parents=True)
        self.original = "var VERSION='old'; // @pulse-version\n"
        self.output.write_text(self.original)
        self.env = dict(os.environ)
        self.env.pop('PULSE_VERSION', None)
        self.env.pop('MAKEFLAGS', None)
        makefile = (self.repo / 'Makefile').read_text()
        self.release = re.search(r'^PULSE_RELEASE:=(.+)$', makefile, re.M)[1].strip()
        self.revision = re.search(r'^PKG_RELEASE:=(.+)$', makefile, re.M)[1].strip()

    def run_command(self, args, success=True, env=None):
        result = subprocess.run(args, cwd=self.repo, env=env or self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout.strip()

    def test_resolve_without_git_and_with_override(self):
        """无 Git 历史时正确解析版本并支持显式覆盖."""
        self.assertFalse((self.repo / '.git').exists())
        self.assertEqual(self.run_command(['sh', 'generate-version.sh', '--resolve', self.release]), self.release)
        env = dict(self.env, PULSE_VERSION='1.2.3_git4')
        self.assertEqual(self.run_command(['sh', 'generate-version.sh', '--resolve', self.release], env=env),
                         '1.2.3_git4')
        for invalid in ('', 'invalid', '1.2', '1.2.3-r2', "1.2.3';echo bad"):
            with self.subTest(invalid=invalid):
                self.run_command(['sh', 'generate-version.sh', '--resolve', invalid], success=False)

    def test_write_validates_version_and_unique_marker(self):
        """写入版本前校验版本格式和唯一标记."""
        self.run_command(['sh', 'generate-version.sh', '--write', '1.2.3_git4'])
        self.assertIn("VERSION='1.2.3_git4'", self.output.read_text())
        before = self.output.read_text()
        self.run_command(['sh', 'generate-version.sh', '--write', "bad';code"], success=False)
        self.assertEqual(self.output.read_text(), before)
        for content in ('no marker\n', self.original * 2):
            with self.subTest(content=content):
                self.output.write_text(content)
                self.run_command(['sh', 'generate-version.sh', '--write', self.release], success=False)
                self.assertEqual(self.output.read_text(), content)

    def test_git_history_does_not_change_configured_version(self):
        """Git 历史及浅克隆不会改变配置的版本号."""
        self.run_command(['git', 'init', '-q'])
        self.run_command(['git', 'config', 'user.name', 'Test'])
        self.run_command(['git', 'config', 'user.email', 'test@example.invalid'])
        self.run_command(['git', 'add', '.'])
        self.run_command(['git', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Fixture'])
        self.run_command(['git', '-c', 'tag.gpgsign=false', 'tag', 'v0.0.1'])
        self.assertEqual(self.run_command(['sh', 'generate-version.sh', '--resolve', self.release]), self.release)
        shallow = self.root / 'shallow'
        self.run_command(['git', 'clone', '-q', '--depth', '1', self.repo.as_uri(), str(shallow)])
        self.assertEqual(self.run_command(['sh', str(shallow / 'generate-version.sh'), '--resolve', self.release]),
                         self.release)

    def test_makefile_passes_version_into_frontend(self):
        """Makefile 将正确版本写入前端."""
        # 用最小 SDK 骨架运行真实 Makefile, 验证构建钩子而非重复版本计算逻辑.
        sdk = self.root / 'sdk'
        (sdk / 'feeds/luci').mkdir(parents=True)
        (sdk / 'rules.mk').write_text('SHELL:=/bin/sh\nPKG_BUILD_DIR:=$(CURDIR)\n')
        (sdk / 'feeds/luci/luci.mk').write_text(
            'all:\n\t@echo $(PKG_VERSION)-r$(PKG_RELEASE)\n\t$(Build/Prepare/luci-app-pulse)\n')
        for override in (None, '1.2.3_git4'):
            with self.subTest(override=override):
                env = dict(self.env)
                if override:
                    env['PULSE_VERSION'] = override
                expected = override or self.release
                output = self.run_command(['make', '--no-print-directory', f'TOPDIR={sdk}'], env=env)
                self.assertEqual(output.splitlines()[0], f'{expected}-r{self.revision}')
                self.assertIn(f"VERSION='{expected}'", self.output.read_text())

    def test_workflow_accepts_only_matching_release_tags(self):
        """工作流仅接受与版本及修订号匹配的发布标签."""
        # 执行工作流中的原始 shell 步骤, 标签规则只保留一份实现.
        workflow = (ROOT / '.github/workflows/build-apk.yml').read_text()
        marker = '      - name: 检查版本\n        run: |\n'
        self.assertEqual(workflow.count(marker), 1)
        block = workflow.split(marker)[1].split('\n      - name:', 1)[0]
        script = '\n'.join(line[10:] for line in block.splitlines())
        cases = [
            (f'refs/tags/v{self.release}', True),
            (f'refs/tags/v{self.release}-{self.revision}', True),
            (f'refs/tags/v{self.release}-{int(self.revision) + 1}', False),
            ('refs/tags/v999.999.999', False),
            (f'refs/tags/v{self.release}-rc1', False),
            ('refs/tags/dev-test', True), ('refs/heads/main', True),
        ]
        for ref, success in cases:
            with self.subTest(ref=ref):
                self.output.write_text(self.original)
                environment_file = self.root / 'github-env'
                environment_file.write_text('')
                env = dict(self.env, GITHUB_REF=ref, GITHUB_REF_NAME=ref.rsplit('/', 1)[-1],
                           GITHUB_ENV=str(environment_file))
                self.run_command(['bash', '-c', script], success=success, env=env)
                self.assertEqual(environment_file.read_text(), f'PULSE_VERSION={self.release}\n' if success else '')
                self.assertEqual(self.output.read_text(),
                                 self.original.replace('old', self.release) if success else self.original)
