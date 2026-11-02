"""Thread-safe run log with rotation and chunked reads for the web UI."""

import os
import shutil
import threading
import time
from pathlib import Path


class Logger:
    def __init__(self, path, echo=True):
        self.path = Path(path)
        self.echo = echo
        # RLock: a signal handler running in the main thread may log while the
        # main thread already holds the lock.
        self._lock = threading.RLock()
        self._prepare()

    def _prepare(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            self.path.touch()

    def log(self, message):
        line = "%s: %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), message)
        with self._lock:
            try:
                with open(self.path, "a", encoding="utf-8", errors="replace") as handle:
                    handle.write(line + "\n")
                    handle.flush()
            except OSError:
                pass
            if self.echo:
                print(line, flush=True)
        return line

    def rotate(self, keep=5):
        """Archive the current log to .1 ... .keep before a run."""
        with self._lock:
            if not self.path.exists() or self.path.stat().st_size == 0:
                return
            oldest = Path(str(self.path) + ".%d" % keep)
            try:
                if oldest.exists():
                    oldest.unlink()
                for index in range(keep - 1, 0, -1):
                    source = Path(str(self.path) + ".%d" % index)
                    if source.exists():
                        os.replace(source, str(self.path) + ".%d" % (index + 1))
                os.replace(self.path, str(self.path) + ".1")
                self.path.touch()
            except OSError:
                pass

    def size_guard(self, limit=10 * 1024 * 1024):
        try:
            if self.path.stat().st_size > limit:
                self.rotate()
                self.log("日志已超过 %d MB，已滚动归档" % (limit // (1024 * 1024)))
        except OSError:
            pass

    def persist(self, destination):
        """Copy the latest run log so it survives /var cleanup and restarts."""
        destination = Path(destination)
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.path, destination)
        except OSError:
            pass


def read_chunk(path, pos=0, first_tail=0, max_chunk=1024 * 1024):
    path = Path(path)
    if not path.exists():
        return {"pos": 0, "content": ""}
    size = path.stat().st_size
    try:
        pos = int(pos)
    except (TypeError, ValueError):
        pos = 0
    if pos < 0 or pos > size:
        pos = 0
    if pos == 0 and first_tail and size > first_tail:
        pos = size - first_tail
    with open(path, "rb") as handle:
        handle.seek(pos)
        data = handle.read(max_chunk)
    return {
        "pos": pos + len(data),
        "content": data.decode("utf-8", "replace"),
    }
