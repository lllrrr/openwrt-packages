# AGENTS.md

## Repository Background

`luci-app-oxidns` is the OpenWrt LuCI management application for OxiDNS. It provides the web UI and rpcd backend used to install and manage an `oxidns` runtime on OpenWrt.

The OxiDNS Rust core source lives in a separate repository. This repository bundles a pinned official core release through the `oxidns-core` package and a validated rule baseline through `oxidns-rules-baseline`; both are **hard dependencies** of the LuCI app in the buildroot build, so selecting `luci-app-oxidns` also selects them. At runtime the core may still be replaced or upgraded from an uploaded archive or a verified release asset via the `Core` page. Package-managed core installation through `opkg` / `apk` is not the default runtime workflow here.

Two supported build paths must keep working:

1. **OpenWrt buildroot** — a feed containing `Makefile`, `oxidns-core/` and `oxidns-rules-baseline/`; produces `ipk` / `apk` with the official toolchain.
2. **Local quick packaging** — `scripts/build-luci-package.sh` produces architecture-independent `ipk` (ar archive) and `apk` packages; embedded core/rule archives require SHA256 arguments and are checked before extraction.

## Main Responsibilities

- LuCI pages: overview, core management, DNS hijack, CodeMirror YAML configuration, logs, settings, rule subscriptions, Geo data and DNS prewarming.
- rpcd backend: status, service control, boot enablement, core install/reinstall/upload/remove, config read/write/validate, DNS hijack sections, rule updates, Geo data download, prewarm and log access. Core uploads are default-deny (`allow_core_upload=1` plus the `luci-app-oxidns-core-upload` ACL group); uploaded binaries are never executed during validation. Geo downloads support optional SHA-256 pins with atomic staging and rollback.
- Target mapping contract (`root/usr/share/oxidns/targets.json`) aligned with the buildroot mapping in `oxidns-core/Makefile`.
- Rule baseline build (`scripts/build-rules-baseline.sh`) with pinned upstream refs, SHA256 verification, syntax validation and reproducible tarballs.
- Internationalization: Simplified Chinese translations are shipped as `luci-i18n-oxidns-zh-cn`.

## Repository Relationships

- `../oxidns`: OxiDNS Rust core repository. Owns the core program, generic releases and non-OpenWrt artifacts.
- `../luci-app-oxidns`: this repository. Owns the LuCI app, rpcd backend, package releases, rule baseline and OpenWrt-facing runtime integration.

## Boundaries

- `root/usr/share/oxidns/targets.json` is an interface contract for mapping device architectures to OxiDNS release targets; `scripts/check.sh` cross-checks it against `oxidns-core/Makefile`.
- Frontend pages must call system operations through the rpcd backend. Do not perform shell/system actions directly in LuCI JavaScript.
- The configuration page is a CodeMirror YAML editor. It may edit any part of the OxiDNS config, but must validate through the rpcd backend before saving.
- DNS hijack changes must only touch firewall sections tagged `oxidns-dns-hijack` and must set `family=any` so IPv6 :53 is covered.
- Geo data URLs/directories are validated to reject private/loopback addresses; downloads are staged and replaced atomically with rollback on failure.
- GitHub tokens and other secrets must not be echoed to UI, logs, or RPC error messages.
- Support both OpenWrt package systems: `opkg` / `ipk` and `apk`. Package install, upgrade, removal, validation and LuCI Software upload must stay compatible with both.

## Key Paths

- `htdocs/luci-static/resources/view/oxidns/`: LuCI JavaScript pages (including `hijack.js`, `geo.js`, `cmeditor.js`).
- `htdocs/luci-static/resources/oxidns-codemirror/`: vendored MIT-licensed editor assets.
- `root/usr/libexec/rpcd/luci.oxidns`: rpcd shell backend.
- `root/usr/share/luci/menu.d/luci-app-oxidns.json`: LuCI menu entries.
- `root/usr/share/rpcd/acl.d/luci-app-oxidns.json`: rpcd ACL.
- `root/usr/share/oxidns/`: target mapping and default prewarm list.
- `po/zh_Hans/oxidns.po`: Simplified Chinese translation.
- `scripts/build-luci-package.sh`, `scripts/build-rules-baseline.sh`: packaging scripts.
- `scripts/check.sh`, `scripts/integration-check.sh`, `scripts/release-check.sh`, `scripts/service-check.sh`: local validation entry points.
- `.github/workflows/ci.yml`: pull-request/push checks; `.github/workflows/rules-release.yml`: baseline build and publish; `.github/workflows/release.yml`: version-tag packages.

## Common Validation

Use Node.js 22 locally. The scripts derive the package version from the root `Makefile`:

```sh
scripts/check.sh
scripts/integration-check.sh
scripts/release-check.sh 0.2.0 /tmp/luci-app-oxidns-release-check
scripts/build-rules-baseline.sh   # network access required
```

CI runs `scripts/check.sh`, `scripts/integration-check.sh` and `scripts/release-check.sh`, and asserts that version strings in the Makefiles, README examples and workflows agree.

## Commit Notes

- Follow the existing Conventional Commit style for LuCI app changes.
- Changes to package metadata, config writes, service control, rule/Geo write paths or log access should be checked against rpcd ACLs, frontend callers and all local validation scripts.
- Never bump `PKG_VERSION` / `PKG_HASH` in `oxidns-rules-baseline/Makefile` without publishing the matching `rules-v<version>` release asset with the exact archive SHA256.
