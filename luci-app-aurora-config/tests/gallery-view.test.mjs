import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const SRC = "htdocs/luci-static/resources/view/aurora/gallery.js";
const MENU_SRC = "root/usr/share/luci/menu.d/luci-app-aurora.json";

test("gallery view is a browse-only view.extend using hub-api", async () => {
  const src = await readFile(SRC, "utf8");
  assert.match(src, /^"require view";/m);
  assert.match(src, /require utils\.hub-api as hubApi/);
  assert.match(src, /return view\.extend\(/);
  assert.ok(src.includes("callHubList"), "missing callHubList usage");
  assert.ok(src.includes("callHubGet"), "missing callHubGet usage");
  assert.ok(src.includes("hub-cards"), "missing #hub-cards grid");
  assert.match(src, /style\.backgroundColor/);
  assert.ok(src.includes("ui.showModal"), "missing detail modal");
  assert.ok(src.includes("getStale"), "missing stale-cache paint");
  assert.ok(src.includes("listCache.set"), "missing cache write on refresh");
});

test("gallery view is browse-only this task -- no apply/share actions yet", () => {
  return readFile(SRC, "utf8").then((src) => {
    assert.match(src, /handleSave:\s*null/);
    assert.match(src, /handleSaveApply:\s*null/);
    assert.match(src, /handleReset:\s*null/);
  });
});

test("gallery view never assigns innerHTML with hub-sourced data", async () => {
  const src = await readFile(SRC, "utf8");
  assert.ok(!src.includes(".innerHTML"), "no innerHTML with user data");
});

test("gallery view: hub config name always flows through document.createTextNode, never a bare E() child", async () => {
  const src = await readFile(SRC, "utf8");
  // Positive assertion (not just the negative innerHTML check above): every
  // site that renders item.name must wrap it in createTextNode -- a bare
  // string child of E()/ui.showModal can be routed through innerHTML by
  // LuCI, and the hub only strips control characters from names, so a name
  // like "<img src=x onerror=alert(1)>" is otherwise legal hub content.
  const nameTextNodeSites = (src.match(/document\.createTextNode\(\s*item\.name\b/g) || []).length;
  assert.ok(
    nameTextNodeSites >= 3,
    `expected item.name to reach the DOM via createTextNode at every render site (card, detail heading, my-shares row); found ${nameTextNodeSites}`,
  );
  // The detail modal title must be static, never the raw hub name.
  assert.match(src, /ui\.showModal\(_\("Theme Details"\),\s*\[\s*\n\s*buildDetailBody\(item\)/);
  assert.ok(
    !/ui\.showModal\(\s*item\.name/.test(src),
    "modal title must never be item.name directly",
  );
});

test("gallery view: apply flow calls hub_apply and polls get_hub_status like pollFontCache", async () => {
  const src = await readFile(SRC, "utf8");
  assert.ok(src.includes("callHubApply"), "missing callHubApply usage");
  assert.ok(src.includes("callGetHubStatus"), "missing callGetHubStatus usage");
  assert.match(src, /window\.setTimeout/, "missing setTimeout-based polling");
  assert.match(src, /1500/, "missing 1.5s poll interval");
});

test("gallery view: external toolbar URLs are surfaced in plaintext before applying", async () => {
  const src = await readFile(SRC, "utf8");
  assert.match(src, /toolbar/);
  assert.match(src, /url\.startsWith\(\s*"http/, "missing http(s) URL check on toolbar entries");
  assert.ok(src.includes("createTextNode"), "external URLs must render via textContent, not innerHTML");
});

test("gallery view: rollback banner reads hub_applied and offers callHubRestore", async () => {
  const src = await readFile(SRC, "utf8");
  assert.match(src, /require uci/);
  assert.match(src, /hub_applied/);
  assert.ok(src.includes("callHubRestore"), "missing callHubRestore usage");
  assert.ok(src.includes("window.location.reload"), "missing reload after restore");
});

test("gallery view: apply/restore error copy stays result-only (no mechanism words)", async () => {
  const src = await readFile(SRC, "utf8");
  const mechanismLeaks = [
    /_\(\s*["'][^"']*\bjob\b[^"']*["']\s*\)/i,
    /_\(\s*["'][^"']*\bschema\b[^"']*["']\s*\)/i,
    /_\(\s*["'][^"']*bad_payload[^"']*["']\s*\)/i,
  ];
  mechanismLeaks.forEach((re) => assert.ok(!re.test(src), `mechanism word leaked via ${re}`));
});

test("gallery view: share panel and my-shares management (Task 8)", async () => {
  const src = await readFile(SRC, "utf8");
  assert.ok(src.includes("callHubShare"), "missing callHubShare usage");
  assert.ok(src.includes("callHubMyShares"), "missing callHubMyShares usage");
  assert.ok(src.includes("callHubUpdate"), "missing callHubUpdate usage");
  assert.ok(src.includes("callHubDelete"), "missing callHubDelete usage");
  assert.match(src, /aurora\.hub\.nick/, "missing nickname localStorage key");
  assert.ok(src.includes("confirmDelete"), "missing confirmDelete reuse for delete confirms");
  assert.match(src, /require utils\.asset-upload as assetUpload/);
});

test("gallery view: updating a share resends the existing name (not id-only)", async () => {
  const src = await readFile(SRC, "utf8");
  assert.match(
    src,
    /callHubUpdate\(\s*item\.id,\s*item\.name,/,
    "callHubUpdate must be called with item.name so the hub PUT's required-name check doesn't reject the update",
  );
});

test("gallery view: share/update/delete copy stays result-only (no mechanism words)", async () => {
  const src = await readFile(SRC, "utf8");
  const mechanismLeaks = [
    /_\(\s*["'][^"']*\bjob\b[^"']*["']\s*\)/i,
    /_\(\s*["'][^"']*\bschema\b[^"']*["']\s*\)/i,
    /_\(\s*["'][^"']*\btoken\b[^"']*["']\s*\)/i,
    /_\(\s*["'][^"']*bad_payload[^"']*["']\s*\)/i,
    /_\(\s*["'][^"']*pending[^"']*["']\s*\)/i,
  ];
  mechanismLeaks.forEach((re) => assert.ok(!re.test(src), `mechanism word leaked via ${re}`));
});

test("menu: theme store entry registered after theme settings", async () => {
  const menu = JSON.parse(await readFile(MENU_SRC, "utf8"));
  assert.ok(menu["admin/system/aurora/gallery"], "gallery menu entry missing");
  assert.equal(menu["admin/system/aurora/gallery"].order, 15);
  assert.equal(
    menu["admin/system/aurora/gallery"].action.path,
    "aurora/gallery",
  );
});
