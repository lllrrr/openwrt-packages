import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const SRC = "htdocs/luci-static/resources/utils/hub-api.js";

test("hub-api module exposes the shared surface", async () => {
  const src = await readFile(SRC, "utf8");
  assert.match(src, /^"require baseclass";/m);
  assert.match(src, /^"require rpc";/m);
  assert.ok(src.includes("aurora.hub.list"), "missing cache key");
  assert.ok(src.includes("callHubList"), "missing callHubList");
  assert.ok(src.includes("callHubGet"), "missing callHubGet");
  assert.match(src, /rpc\.declare\(/);
  assert.match(src, /params:\s*\["sort", "page"\]/);
  assert.ok(src.includes("getStale"), "missing getStale");
  assert.match(src, /return baseclass\.extend\(/);
});

test("hub-api module clones the version-api cache TTL logic", () => {
  return readFile(SRC, "utf8").then((src) => {
    assert.match(src, /CACHE_TTL\s*=\s*300000/);
    assert.match(src, /localStorage\.getItem\(CACHE_KEY\)/);
    assert.match(src, /localStorage\.setItem\(/);
    assert.match(src, /localStorage\.removeItem\(CACHE_KEY\)/);
  });
});

test("hub-api module exposes the apply/status/restore declares (Task 6)", async () => {
  const src = await readFile(SRC, "utf8");
  assert.ok(src.includes("callHubApply"), "missing callHubApply");
  assert.match(src, /method:\s*"hub_apply"/);
  assert.match(src, /params:\s*\["id"\]/);
  assert.ok(src.includes("callGetHubStatus"), "missing callGetHubStatus");
  assert.match(src, /method:\s*"get_hub_status"/);
  assert.match(src, /params:\s*\["job_id"\]/);
  assert.ok(src.includes("callHubRestore"), "missing callHubRestore");
  assert.match(src, /method:\s*"hub_restore_backup"/);
});

test("hub-api module exposes the share/my-shares/update/delete declares (Task 8)", async () => {
  const src = await readFile(SRC, "utf8");
  assert.ok(src.includes("callHubShare"), "missing callHubShare");
  assert.match(src, /method:\s*"hub_share"/);
  assert.match(src, /params:\s*\["name", "description", "author"\]/);
  assert.ok(src.includes("callHubMyShares"), "missing callHubMyShares");
  assert.match(src, /method:\s*"hub_my_shares"/);
  assert.ok(src.includes("callHubUpdate"), "missing callHubUpdate");
  assert.match(src, /method:\s*"hub_update"/);
  assert.match(
    src,
    /params:\s*\["id", "name", "author", "description"\]/,
    "callHubUpdate must resend the existing name (and author/description) so the hub PUT's required-name validation doesn't reject an id-only update",
  );
  assert.ok(src.includes("callHubDelete"), "missing callHubDelete");
  assert.match(src, /method:\s*"hub_delete"/);
});
