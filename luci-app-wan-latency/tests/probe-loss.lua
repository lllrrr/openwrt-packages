local wl = require "wanlatency"
local path = "/tmp/wan-loss-fixture.bin"
os.remove(path)
wl.append_recs(path, wl.pack_rec(100, 20, 0) .. wl.pack_rec(110, nil, 0) .. wl.pack_rec(120, 30, 0))
local d = wl.query_one(path, 0, 1000, 60)
assert(d.count == 3 and d.failed == 1, "count actual probes before downsampling, excluding unobserved periods")
assert(d.avg[2] == 30, "a failed observation must not shift later buckets")
os.remove(path)
print("PASS actual attempts/failures, empty history and downsampled loss counts")
