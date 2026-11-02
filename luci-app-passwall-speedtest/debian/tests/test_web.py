"""Integration smoke test: start the real web service in a subprocess."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class WebTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        base = Path(cls.tmp.name)
        cls.base = base
        cls.port = free_port()
        cls.base_url = "http://127.0.0.1:%d" % cls.port
        env = os.environ.copy()
        env.update({
            "CFPICK_APP_DIR": str(ROOT),
            "CFPICK_STATE_DIR": str(base / "state"),
            "CFPICK_CONFIG_DIR": str(base / "etc"),
            "CFPICK_CONFIG": str(base / "etc" / "config.json"),
            "CFPICK_LOG_DIR": str(base / "log"),
            "CFPICK_SRC_DIR": str(base / "no-source-checkout"),
            "CFPICK_SKIP_CRON": "1",
            "PYTHONPATH": str(ROOT),
            "PYTHONUNBUFFERED": "1",
        })
        cls.proc = subprocess.Popen(
            [sys.executable, "-m", "cfpick", "serve",
             "--listen", "127.0.0.1", "--port", str(cls.port)],
            cwd=str(ROOT), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        deadline = time.time() + 15
        last_error = ""
        while time.time() < deadline:
            try:
                status, data = cls.request("/api/ping")
                if status == 200 and data.get("ok"):
                    return
            except (urllib.error.URLError, OSError) as exc:
                last_error = str(exc)
            if cls.proc.poll() is not None:
                output = cls.proc.stdout.read().decode("utf-8", "replace")
                raise RuntimeError("web server exited: %s\n%s" % (cls.proc.returncode, output))
            time.sleep(0.15)
        cls.proc.kill()
        raise RuntimeError("web server did not start: %s" % last_error)

    @classmethod
    def tearDownClass(cls):
        if cls.proc.poll() is None:
            cls.proc.terminate()
            try:
                cls.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.proc.kill()
        try:
            cls.proc.stdout.close()
        except Exception:
            pass
        cls.tmp.cleanup()

    @classmethod
    def request(cls, path, method="GET", payload=None, headers=None):
        data = None
        all_headers = dict(headers or {})
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            all_headers["Content-Type"] = "application/json"
        request = urllib.request.Request(cls.base_url + path, data=data,
                                         headers=all_headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                body = response.read().decode("utf-8", "replace")
                content_type = response.headers.get("Content-Type", "")
                if "json" in content_type:
                    return response.status, json.loads(body or "{}")
                return response.status, body
        except urllib.error.HTTPError as exc:
            try:
                body = exc.read().decode("utf-8", "replace")
                try:
                    parsed = json.loads(body or "{}")
                except ValueError:
                    parsed = body
            finally:
                exc.close()
            return exc.code, parsed

    def test_ping_and_status(self):
        status, data = self.request("/api/ping")
        self.assertEqual(status, 200)
        self.assertTrue(data["ok"])
        self.assertFalse(data["auth_required"])
        status, data = self.request("/api/status")
        self.assertEqual(status, 200)
        self.assertFalse(data["running"])
        self.assertEqual(data["node_count"], 0)
        self.assertIn("state_dir", data)

    def test_core_modules(self):
        status, data = self.request("/api/core")
        self.assertEqual(status, 200)
        self.assertEqual(data["active"], "mihomo")
        self.assertEqual(set(data["cores"].keys()), {"mihomo", "xray"})
        self.assertFalse(data["cores"]["mihomo"]["installed"])
        self.assertFalse(data["updating"])
        status, data = self.request("/api/status")
        self.assertEqual(data["core_type"], "mihomo")
        self.assertIn("xray", data["cores"])
        status, data = self.request("/api/core/update", method="POST",
                                    payload={"type": "bogus"})
        self.assertEqual(status, 400)

    def test_app_update_api(self):
        status, data = self.request("/api/app")
        self.assertEqual(status, 200)
        self.assertEqual(data["version"], "1.0.7")
        self.assertIn("source_dir", data)
        self.assertIn("update", data)
        self.assertFalse(data["manageable"])
        status, data = self.request("/api/update-app", method="POST", payload={})
        self.assertEqual(status, 400)

    def test_cron_listing(self):
        status, data = self.request("/api/cron")
        self.assertEqual(status, 200)
        self.assertIn("installed", data)
        self.assertIn("managed", data)
        self.assertIn("enabled", data["managed"])
        self.assertIn("line", data["managed"])
        self.assertIsInstance(data["entries"], list)
        self.assertIsInstance(data["errors"], list)

    def test_static_files(self):
        status, text = self.request("/")
        self.assertEqual(status, 200)
        self.assertIn("Cloudflare", text)
        status, text = self.request("/app.js")
        self.assertEqual(status, 200)
        self.assertIn("cfpick", text)
        status, body = self.request("/vendor/chart.js")
        self.assertEqual(status, 200)
        self.assertIn("Chart.js", body[:200])

    def test_start_requires_core_and_nodes(self):
        status, data = self.request("/api/start", method="POST", payload={"mode": "start"})
        self.assertEqual(status, 400)
        self.assertIn("mihomo", data["error"])

    def test_export_without_result(self):
        status, _ = self.request("/api/export/result.csv")
        self.assertEqual(status, 404)

    def test_stop_when_idle(self):
        status, data = self.request("/api/stop", method="POST", payload={})
        self.assertEqual(status, 200)
        self.assertTrue(data["stopped"])

    def test_ddns_preview_endpoint(self):
        status, data = self.request("/api/ddns")
        self.assertEqual(status, 200)
        self.assertIn("preview", data)
        self.assertIn("last", data)
        self.assertEqual(data["preview"]["provider"], "cloudflare")

    def test_ddns_apply_requires_enabled_config(self):
        status, data = self.request("/api/ddns/apply", method="POST", payload={})
        self.assertEqual(status, 400)
        self.assertIn("未启用", data["error"])

    def test_ddns_token_is_masked_and_preserved(self):
        status, data = self.request("/api/config")
        self.assertEqual(status, 200)
        original = data["config"]
        original["ddns"]["cloudflare"]["api_token"] = "secret-token"
        status, data = self.request("/api/config", method="POST",
                                    payload={"config": original})
        self.assertEqual(status, 200)
        self.assertEqual(data["config"]["ddns"]["cloudflare"]["api_token"], "***")

        status, data = self.request("/api/config")
        self.assertEqual(data["config"]["ddns"]["cloudflare"]["api_token"], "***")

        # Saving the masked placeholder must keep the stored token.
        status, data = self.request("/api/config", method="POST",
                                    payload={"config": data["config"]})
        self.assertEqual(status, 200)
        stored = json.loads((self.base / "etc" / "config.json").read_text(encoding="utf-8"))
        self.assertEqual(stored["ddns"]["cloudflare"]["api_token"], "secret-token")

        masked = data["config"]
        masked["ddns"]["cloudflare"]["api_token"] = ""
        self.request("/api/config", method="POST", payload={"config": masked})

    def test_schedule_cron_is_validated(self):
        status, data = self.request("/api/config")
        self.assertEqual(status, 200)
        cfg = data["config"]
        cfg["schedule"]["enabled"] = False
        cfg["schedule"]["custom_enabled"] = True
        cfg["schedule"]["custom_cron"] = "0 99 * * *"
        status, data = self.request("/api/config", method="POST",
                                    payload={"config": cfg})
        self.assertEqual(status, 200)
        self.assertEqual(data["config"]["schedule"]["custom_cron"], "0 3 * * *")
        self.assertTrue(any("cron" in warning for warning in data["warnings"]))

        fixed = data["config"]
        fixed["schedule"]["custom_cron"] = "15 4 * * 1"
        status, data = self.request("/api/config", method="POST",
                                    payload={"config": fixed})
        self.assertEqual(status, 200)
        self.assertEqual(data["config"]["schedule"]["custom_cron"], "15 4 * * 1")

    def test_token_auth(self):
        status, data = self.request("/api/config")
        self.assertEqual(status, 200)
        cfg = data["config"]

        secured = json.loads(json.dumps(cfg))
        secured["web"]["token"] = "test-secret"
        status, data = self.request("/api/config", method="POST", payload={"config": secured})
        self.assertEqual(status, 200)

        try:
            status, _ = self.request("/api/status")
            self.assertEqual(status, 401)
            status, data = self.request("/api/status",
                                        headers={"X-CFPICK-Token": "test-secret"})
            self.assertEqual(status, 200)
            status, data = self.request("/api/status?token=test-secret")
            self.assertEqual(status, 200)
            status, data = self.request("/api/status",
                                        headers={"X-CFPICK-Token": "wrong"})
            self.assertEqual(status, 401)
        finally:
            status, _ = self.request("/api/config", method="POST",
                                     payload={"config": cfg},
                                     headers={"X-CFPICK-Token": "test-secret"})
            self.assertEqual(status, 200)


if __name__ == "__main__":
    unittest.main()
