# AGENTS.md

Guidance for coding agents working in this repository.

## Project Shape

- This repository is an OpenWrt LuCI package named `luci-app-flowlens`.
- Router-side code must stay lightweight and compatible with OpenWrt runtime
  tools.
- The React frontend is built at development time and shipped as static LuCI
  assets under `htdocs/luci-static/resources/flowlens/dist/`.

## Important Paths

- `root/usr/libexec/rpcd/luci.flowlens`: rpcd backend and JSON data contract.
- `htdocs/luci-static/resources/view/flowlens/overview.js`: LuCI view wrapper,
  asset loader, and cache-busting version.
- `web/src/`: React frontend source.
- `web/src/domain.js`: frontend normalization, filtering, sorting, and summary
  logic.
- `web/tests/`: frontend unit tests.
- `tests/test_rpc_devices.sh`: backend contract test.
- `root/usr/share/luci/menu.d/luci-app-flowlens.json`: LuCI menu entry.
- `root/usr/share/rpcd/acl.d/luci-app-flowlens.json`: ubus ACL.

## Development Rules

- Keep router-side scripts POSIX shell and BusyBox awk compatible. Avoid
  bashisms, GNU-only awk features, and Node/Python runtime dependencies on the
  router.
- If frontend code changes, run `npm run build` from `web/` and keep the built
  `htdocs/.../dist/flowlens-app.js` and `flowlens-app.css` in sync.
- If the frontend bundle changes, bump the asset version in both:
  - `web/src/main.jsx`
  - `htdocs/luci-static/resources/view/flowlens/overview.js`
- Do not commit `web/node_modules/`.
- Keep `web/package-lock.json` committed when dependencies change.
- Prefer focused changes. Do not refactor unrelated LuCI packaging, router
  scripts, or UI code while fixing a narrow issue.
- Maintain both `README.md` and `README.zh-CN.md` when changing user-facing
  setup, build, or behavior documentation.

## Verification

Use the smallest relevant set for the change, and run the full set before
claiming a release-ready state.

Frontend:

```sh
cd web
npm test
npm run build
```

Backend and LuCI wrapper:

```sh
tests/test_rpc_devices.sh
sh -n root/usr/libexec/rpcd/luci.flowlens
node --check htdocs/luci-static/resources/view/flowlens/overview.js
```

For UI changes, also verify in LuCI or a local browser when practical.

## Data Contract Notes

- IPv4 main display should prefer the current DHCP lease.
- IPv6 main display should expose at most one useful address and hide `fe80::`
  from the default view.
- STALE neighbor entries should stay out of primary address display.
- Historical/neighbor-cache addresses belong in `history_ipv4` and
  `history_ipv6`.
- FlowLens cache should not persist growing full address lists.

## Packaging Notes

- The package depends on `nlbwmon` and `ip-full`.
- Runtime state belongs under `/tmp/run/flowlens` on the router.
- LuCI page actions are intentionally disabled in the FlowLens view with
  `handleSaveApply`, `handleSave`, and `handleReset` set to `null`.
