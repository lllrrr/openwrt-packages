import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "root/etc/uci-defaults/90_luci-internet-monitor"
ALIDNS_URL = (
    "https://dns.alidns.com/dns-query?"
    "dns=AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"
)
DNSPOD_URL = (
    "https://doh.pub/dns-query?"
    "dns=AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"
)


class UpgradeMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.uci_log = self.base / "uci.log"
        self.init_log = self.base / "init.log"
        self.cache = self.base / "cache"
        self.cache.mkdir()
        self.uci = self.base / "uci"
        self.rpcd_init = self.base / "rpcd"

        self.uci.write_text(
            """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_UCI_LOG"
[ "$1" = '-q' ] && shift
case "$1" in
    get)
        case "$2" in
            internet-monitor.global.defaults_revision)
                [ -n "${FAKE_UCI_REVISION:-}" ] || exit 1
                printf '%s\\n' "$FAKE_UCI_REVISION"
                ;;
            internet-monitor.alidns_https|internet-monitor.dnspod_https)
                [ "${FAKE_UCI_EXISTING:-0}" = '1' ]
                ;;
            *) exit 1 ;;
        esac
        ;;
    show)
        [ -z "${FAKE_UCI_SHOW_ADDRESS:-}" ] || \\
            printf "internet-monitor.custom.address='%s'\\n" "$FAKE_UCI_SHOW_ADDRESS"
        ;;
    set) exit 0 ;;
    commit) [ "${FAKE_UCI_COMMIT_FAIL:-0}" != '1' ] ;;
    *) exit 1 ;;
esac
""",
            encoding="utf-8",
        )
        self._write_init(self.rpcd_init, "rpcd")
        for path in (self.uci, self.rpcd_init):
            path.chmod(path.stat().st_mode | stat.S_IXUSR)

        self.env = os.environ.copy()
        self.env.update(
            {
                "FAKE_UCI_LOG": str(self.uci_log),
                "FAKE_INIT_LOG": str(self.init_log),
                "INTERNET_MONITOR_UCI": str(self.uci),
                "INTERNET_MONITOR_RPCD_INIT": str(self.rpcd_init),
                "INTERNET_MONITOR_CACHE_DIR": str(self.cache),
            }
        )

    @staticmethod
    def _write_init(path, name):
        path.write_text(
            f"#!/bin/sh\nprintf '{name} %s\\n' \"$*\" >> \"$FAKE_INIT_LOG\"\n",
            encoding="utf-8",
        )

    def run_migration(
        self, *, existing=False, revision=None, show_address=None, commit_fail=False
    ):
        env = self.env.copy()
        env["FAKE_UCI_EXISTING"] = "1" if existing else "0"
        if revision is not None:
            env["FAKE_UCI_REVISION"] = str(revision)
        if show_address is not None:
            env["FAKE_UCI_SHOW_ADDRESS"] = show_address
        env["FAKE_UCI_COMMIT_FAIL"] = "1" if commit_fail else "0"
        return subprocess.run(["sh", str(MIGRATION)], env=env, check=False)

    def seed_cache(self):
        (self.cache / "luci-indexcache.test").write_text("cache", encoding="utf-8")
        module_cache = self.cache / "luci-modulecache"
        module_cache.mkdir(exist_ok=True)
        (module_cache / "entry").write_text("cache", encoding="utf-8")

    def test_missing_domestic_targets_are_added_and_applied(self):
        self.seed_cache()
        result = self.run_migration()
        self.assertEqual(result.returncode, 0)
        commands = self.uci_log.read_text(encoding="utf-8")
        self.assertEqual(commands.count("set internet-monitor.alidns_https=target"), 1)
        self.assertEqual(commands.count("set internet-monitor.dnspod_https=target"), 1)
        self.assertIn(
            "set internet-monitor.alidns_https.address="
            f"{ALIDNS_URL}",
            commands,
        )
        self.assertIn(
            "set internet-monitor.dnspod_https.address="
            f"{DNSPOD_URL}",
            commands,
        )
        self.assertIn("set internet-monitor.alidns_https.family=ipv4", commands)
        self.assertIn("set internet-monitor.dnspod_https.family=ipv4", commands)
        self.assertEqual(commands.count("expected_codes=200"), 2)
        self.assertIn("set internet-monitor.global.defaults_revision=1", commands)
        self.assertNotIn("global.quorum", commands)
        self.assertEqual(commands.count("commit internet-monitor"), 1)
        init_calls = self.init_log.read_text(encoding="utf-8")
        self.assertIn("rpcd reload", init_calls)
        self.assertFalse((self.cache / "luci-indexcache.test").exists())
        self.assertFalse((self.cache / "luci-modulecache").exists())

    def test_completed_defaults_revision_is_left_untouched(self):
        self.seed_cache()
        result = self.run_migration(revision=1)
        self.assertEqual(result.returncode, 0)
        commands = self.uci_log.read_text(encoding="utf-8")
        self.assertNotIn(" set ", f" {commands} ")
        self.assertNotIn("commit internet-monitor", commands)
        init_calls = self.init_log.read_text(encoding="utf-8")
        self.assertIn("rpcd reload", init_calls)

    def test_existing_named_targets_are_not_overwritten(self):
        result = self.run_migration(existing=True)
        self.assertEqual(result.returncode, 0)
        commands = self.uci_log.read_text(encoding="utf-8")
        self.assertNotIn("set internet-monitor.alidns_https=target", commands)
        self.assertNotIn("set internet-monitor.dnspod_https=target", commands)
        self.assertIn("set internet-monitor.global.defaults_revision=1", commands)
        self.assertNotIn("global.quorum", commands)

    def test_existing_address_is_not_duplicated(self):
        result = self.run_migration(show_address=ALIDNS_URL)
        self.assertEqual(result.returncode, 0)
        commands = self.uci_log.read_text(encoding="utf-8")
        self.assertNotIn("set internet-monitor.alidns_https=target", commands)
        self.assertIn("set internet-monitor.dnspod_https=target", commands)

    def test_commit_failure_is_reported(self):
        result = self.run_migration(commit_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.init_log.exists())


if __name__ == "__main__":
    unittest.main()
