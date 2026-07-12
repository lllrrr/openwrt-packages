import json
import os
import re
import stat
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MENU = ROOT / "root/usr/share/luci/menu.d/luci-app-monitor.json"
ACL = ROOT / "root/usr/share/rpcd/acl.d/luci-app-monitor.json"
DAEMON = ROOT / "root/usr/libexec/internet-monitor/daemon"
RPCD = ROOT / "root/usr/libexec/rpcd/luci.internet-monitor"
BUILD_SCRIPT = ROOT / "scripts/build-openwrt-packages.sh"
TIMELINE_TEST = ROOT / "tests/test_timeline.js"


class AssetTests(unittest.TestCase):
    def test_json_assets_are_valid(self):
        for path in (MENU, ACL):
            with self.subTest(path=path):
                self.assertIsInstance(json.loads(path.read_text(encoding="utf-8")), dict)

    def test_acl_uses_explicit_rpc_methods_only(self):
        acl = json.loads(ACL.read_text(encoding="utf-8"))["luci-app-monitor"]
        self.assertNotIn("file", acl["read"])
        self.assertNotIn("file", acl["write"])
        self.assertEqual(
            acl["read"]["ubus"]["luci.internet-monitor"],
            ["getStatus", "getHistory"],
        )
        self.assertEqual(
            acl["write"]["ubus"]["luci.internet-monitor"],
            ["runProbe", "clearHistory"],
        )

    def test_shell_scripts_parse_and_are_executable(self):
        scripts = [
            ROOT / "root/etc/init.d/internet-monitor",
            ROOT / "root/etc/uci-defaults/90_luci-internet-monitor",
            DAEMON,
            RPCD,
            *sorted((ROOT / "tests/fixtures/bin").iterdir()),
            ROOT / "tests/fixtures/functions.sh",
            ROOT / "tests/fixtures/jshn-trace.sh",
        ]
        subprocess.run(["sh", "-n", *map(str, scripts)], check=True)
        for path in scripts[:4]:
            self.assertTrue(path.stat().st_mode & stat.S_IXUSR, path)

    def test_makefile_declares_portable_package_and_dependencies(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("LUCI_PKGARCH:=all", makefile)
        self.assertIn("+luci-base", makefile)
        self.assertIn("+curl", makefile)
        self.assertIn("+ca-bundle", makefile)
        self.assertIn("+jshn", makefile)
        self.assertIn("/etc/config/internet-monitor", makefile)
        self.assertNotIn("src/Makefile", makefile)

    def test_release_version_metadata_is_consistent(self):
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        version = re.search(r"^PKG_VERSION:=(\S+)$", makefile, re.MULTILINE).group(1)
        rpc = RPCD.read_text(encoding="utf-8")
        build = BUILD_SCRIPT.read_text(encoding="utf-8")
        checks = (ROOT / "scripts/check-static.sh").read_text(encoding="utf-8")
        catalog = (ROOT / "po/zh_Hans/internet-monitor.po").read_text(encoding="utf-8")
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

        self.assertIn(f"VERSION='{version}'", rpc)
        self.assertIn(f"PACKAGE_VERSION='{version}'", build)
        self.assertIn(f"PKG_VERSION:={version}", checks)
        self.assertIn(f"Project-Id-Version: luci-app-monitor {version}", catalog)
        for artifact in (
            f"luci-app-monitor_{version}_all.ipk",
            f"luci-app-monitor_{version}-r1_all.ipk",
            f"luci-app-monitor-{version}-r1.apk",
            f"luci-i18n-monitor-zh-cn_{version}_all.ipk",
            f"luci-i18n-monitor-zh-cn_{version}-r1_all.ipk",
            f"luci-i18n-monitor-zh-cn-{version}-r1.apk",
            f"luci-app-monitor-openwrt-all-v{version}.tar.gz",
        ):
            self.assertIn(artifact, workflow)

    def test_rpc_methods_match_frontend_contract(self):
        rpc = RPCD.read_text(encoding="utf-8")
        for method in ("getStatus", "getHistory", "runProbe", "clearHistory"):
            self.assertIn(method, rpc)

        frontend = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ROOT / "htdocs/luci-static/resources/view/internet-monitor").glob("*.js")
        )
        declared = set(re.findall(r"method:\s*'([^']+)'", frontend))
        self.assertEqual(declared, {"getStatus", "getHistory", "runProbe", "clearHistory"})
        for method in declared:
            self.assertIn(method, rpc)
        self.assertNotRegex(frontend, r"innerHTML\s*=")

    def test_timeline_uses_router_clock_and_maps_history_states(self):
        frontend = (
            ROOT / "htdocs/luci-static/resources/view/internet-monitor/overview.js"
        ).read_text(encoding="utf-8")
        self.assertIn("var end = toTimestamp(generatedAt);", frontend)
        self.assertIn("if (end == null)\n\t\tend = Date.now();", frontend)
        self.assertIn(
            "timelineBins(points, 24, 96, history && history.generated_at)",
            frontend,
        )
        self.assertIn(
            "var severity = { operational: 1, degraded: 2, unknown: 3, outage: 4 };",
            frontend,
        )
        self.assertIn(
            "if (!bins[index].observed || severity[state] >= severity[bins[index].state])",
            frontend,
        )
        self.assertIn("timestamp < start || timestamp >= end", frontend)
        self.assertIn(
            "/^(up|ok|online|healthy|operational|success|available)$/.test(state))"
            "\n\t\treturn 'operational';",
            frontend,
        )
        self.assertIn(
            "/^(degraded|warning|warn|partial|unstable)$/.test(state))"
            "\n\t\treturn 'degraded';",
            frontend,
        )
        self.assertIn(
            "/^(down|offline|outage|critical|failed|failure|unavailable)$/.test(state))"
            "\n\t\treturn 'outage';",
            frontend,
        )

    def test_timeline_bins_behavior(self):
        subprocess.run(["node", str(TIMELINE_TEST)], check=True)

    def test_no_native_payload_is_present(self):
        forbidden_suffixes = {".so", ".o", ".a", ".dylib", ".exe"}
        for path in ROOT.rglob("*"):
            if not path.is_file() or ".git" in path.parts:
                continue
            self.assertNotIn(path.suffix, forbidden_suffixes, path)
            head = path.read_bytes()[:4]
            self.assertNotEqual(head, b"\x7fELF", path)
            self.assertNotIn(head, {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}, path)

    def test_defaults_use_diverse_providers_and_protocols(self):
        config = (ROOT / "root/etc/config/internet-monitor").read_text(encoding="utf-8")
        self.assertIn("1.1.1.1", config)
        self.assertIn("223.5.5.5", config)
        domestic_targets = {
            "alidns_https": (
                "https://dns.alidns.com/dns-query?"
                "dns=AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"
            ),
            "dnspod_https": (
                "https://doh.pub/dns-query?"
                "dns=AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"
            ),
        }
        for section, address in domestic_targets.items():
            with self.subTest(section=section):
                block = config.split(f"config target '{section}'", 1)[1].split(
                    "\nconfig ", 1
                )[0]
                self.assertIn(f"option address '{address}'", block)
                self.assertIn("option family 'ipv4'", block)
                self.assertIn("option timeout '6'", block)
                self.assertIn("option expected_codes '200'", block)
        self.assertIn("https://openwrt.org/", config)
        self.assertGreaterEqual(config.count("option type 'icmp'"), 2)
        self.assertGreaterEqual(config.count("option type 'http'"), 4)

    def test_readme_documents_luci_status_menu(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("状态 → 互联网连接", readme)
        self.assertIn("不会出现在“服务”菜单", readme)

    def test_container_output_is_writable_by_unprivileged_builder(self):
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        prepare = script.index('chown -R builder:builder "/out/$version"')
        build = script.index("runuser -u builder -- /tmp/build-as-user.sh")
        self.assertLess(prepare, build)


if __name__ == "__main__":
    unittest.main()
