"""Per-node run locks and the global download queue."""

import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from cfpick import lock


class LockTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.patches = [
            mock.patch.object(lock.paths, "STATE_DIR", self.root),
            mock.patch.object(lock, "WORKER_LOCK_DIR", self.root / ".worker-locks"),
            mock.patch.object(lock, "RUN_REGISTRY", self.root / ".runs"),
            mock.patch.object(lock, "COMMIT_LOCK_DIR", self.root / ".commit.lock"),
            mock.patch.object(lock, "RUN_PID_FILE", self.root / "current_run"),
            mock.patch.object(lock.paths, "RUN_LOCK_DIR", self.root / ".run.lock"),
            mock.patch.object(lock.paths, "STOP_FILE", self.root / "stop.request"),
            mock.patch.object(lock.paths, "STATE_FILE", self.root / "state.json"),
            mock.patch.object(lock, "_pid_alive", return_value=True),
        ]
        for item in self.patches:
            item.start()
        self.log = mock.Mock()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.tmp.cleanup()

    def busy(self, name, pid=999):
        path = lock.WORKER_LOCK_DIR / (lock._lock_id(name) + ".lock")
        path.mkdir(parents=True, exist_ok=True)
        (path / "pid").write_text(str(pid), encoding="utf-8")
        (path / "started").write_text(str(int(time.time())), encoding="utf-8")
        return path

    def test_partial_overlap_skips_only_busy_node(self):
        busy = self.busy("a")
        run = lock.RunLock(self.log)
        self.assertTrue(run.acquire(nodes=["a", "b"]))
        self.assertEqual(run.node_names, ["b"])
        self.assertTrue(busy.exists())
        run.release()
        self.assertFalse((lock.WORKER_LOCK_DIR / (lock._lock_id("b") + ".lock")).exists())

    def test_all_nodes_busy_aborts(self):
        self.busy("a")
        self.busy("b")
        run = lock.RunLock(self.log)
        self.assertFalse(run.acquire(nodes=["a", "b"]))
        self.assertEqual(run.node_names, [])

    def test_commit_slot_owner_detection(self):
        lock.COMMIT_LOCK_DIR.mkdir(parents=True)
        (lock.COMMIT_LOCK_DIR / "pid").write_text("999", encoding="utf-8")
        (lock.COMMIT_LOCK_DIR / "started").write_text(str(int(time.time())), encoding="utf-8")
        self.assertTrue(lock.download_active_by_other(os.getpid()))
        self.assertFalse(lock.download_active_by_other(999))

    def test_commit_lock_acquire_release(self):
        self.assertTrue(lock.acquire_commit(self.log, timeout=2))
        self.assertTrue(lock.download_active_by_other(999))
        self.assertFalse(lock.download_active_by_other(os.getpid()))
        lock.release_commit()
        self.assertFalse(lock.COMMIT_LOCK_DIR.exists())

    def test_run_registry_and_other_runs(self):
        lock.RUN_REGISTRY.mkdir(parents=True)
        (lock.RUN_REGISTRY / "777").write_text("nodes=a\n", encoding="utf-8")
        self.assertIn(777, lock.run_pids())
        self.assertTrue(lock.other_runs_active())
        (lock.RUN_REGISTRY / "777").unlink()
        self.assertFalse(lock.other_runs_active())

    def test_stop_flag(self):
        lock.request_stop()
        self.assertTrue(lock.stop_requested())
        lock.clear_stop()
        self.assertFalse(lock.stop_requested())


if __name__ == "__main__":
    unittest.main()
