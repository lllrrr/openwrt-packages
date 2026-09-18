"""Validate locally generated v1.4.0 artifacts and their embedded contents."""
import gzip
import hashlib
import io
import tarfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
out = root / "dist"
main = "luci-app-wan-latency_1.4.0-1_all.ipk"
runner = "luci-app-wan-latency-1.4.0-1.run"
source = "luci-app-wan-latency-1.4.0-1-source.zip"
expected = {main, runner, source}

sums = {}
for line in (out / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
    digest, name = line.split("  ")
    sums[name] = digest
assert set(sums) == expected
for name, digest in sums.items():
    assert hashlib.sha256((out / name).read_bytes()).hexdigest() == digest, name

with zipfile.ZipFile(out / source) as z:
    paths = z.namelist()
    assert not any("higo" in p.lower() or "__pycache__" in p or "/dist/" in p for p in paths)
    assert any(p.endswith("docs/screenshots/dashboard-overview-v140.jpg") for p in paths)
    assert any(p.endswith("docs/screenshots/history-chart-v140.png") for p in paths)

ipk = (out / main).read_bytes()
with tarfile.open(fileobj=io.BytesIO(ipk), mode="r:gz") as outer:
    members = {m.name.removeprefix("./"): outer.extractfile(m).read() for m in outer}
assert members["debian-binary"] == b"2.0\n"
with tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"]), mode="r:gz") as controls:
    control = controls.extractfile("./control").read()
    assert b"Version: 1.4.0-1\n" in control
    assert b"Package: luci-app-wan-latency\n" in control
with tarfile.open(fileobj=io.BytesIO(members["data.tar.gz"]), mode="r:gz") as data:
    paths = data.getnames()
    assert "./www/wan-latency/index.html" in paths
    assert "./usr/libexec/wan-latency-api" in paths
    assert not any("higo" in p.lower() for p in paths)

blob = (out / runner).read_bytes()
marker = b"__PAYLOAD_BELOW__\n"
assert blob.count(marker) == 1
header, payload = blob.split(marker, 1)
assert b"opkg install \"$work/luci-app-wan-latency_1.4.0-1_all.ipk\"" in header
assert b"higo" not in header.lower()
with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as bundle:
    assert bundle.getnames() == ["./" + main]
    assert bundle.extractfile("./" + main).read() == ipk

print("Release artifacts passed (checksums, IPK, .run, source ZIP, screenshots).")
