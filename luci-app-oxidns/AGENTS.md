# AGENTS.md

## Repository Background

`luci-app-oxidns` is the OpenWrt LuCI management application for OxiDNS. It provides the web UI and rpcd backend used to install and manage an `oxidns` runtime on OpenWrt.

This repository does not contain the OxiDNS Rust core source code, and it does not contain the OpenWrt `oxidns` core package build implementation. The current LuCI workflow installs the OxiDNS core from official GitHub release archives or from an uploaded archive/binary, verifies release digests where available, and manages the installed binary plus WebUI files directly. OpenWrt package-managed core installation through `opkg` or `apk` is not the default workflow in this repository.

## Main Responsibilities

- LuCI pages: overview, core binary management, configuration, rule file editing, logs, and settings.
- rpcd backend: status, service control, boot enablement, core install/reinstall/upload/remove actions, config read/write/validate, rule file read/write, log access, and LuCI integration settings.
- Target mapping contract files used to align supported OpenWrt architectures with OxiDNS release targets.
- LuCI package builds: released artifacts are compiled by the official OpenWrt SDK (`.github/workflows/build-packages.yml`) into the apk-tools 3 ADB container format used by OpenWrt 25.12, so devices and the official ImageBuilder can consume them directly. `scripts/build-luci-package.sh` can still produce `ipk` and apk-tools 2.x style `.apk` locally for offline testing, but that output is not the release format and must not be used to assemble ImageBuilder images.
- Internationalization: Simplified Chinese translations are shipped as `luci-i18n-oxidns-zh-cn`.

## Repository Relationships

- `../oxidns`: OxiDNS Rust core repository. Owns the core program, generic releases, generic binaries, Docker images, and non-OpenWrt artifacts.
- `../luci-app-oxidns`: this repository. Owns the LuCI management app, rpcd backend, LuCI package release, and OpenWrt-facing runtime integration.

## Boundaries

- `root/usr/share/oxidns/targets.json` is an interface contract for mapping OpenWrt device architectures to OxiDNS release targets.
- Frontend pages must call system operations through the rpcd backend. Do not perform shell/system actions directly in LuCI JavaScript.
- The configuration page is a full YAML editor. It may edit any part of the OxiDNS config, including plugin configuration, but must validate through the rpcd backend before saving.
- The rule files page edits rule list files through the rpcd backend only. Writes must stay inside the rule directory (default `/etc/oxidns/rule`, overridable with `oxidns.main.rules_dir`), accept only single-level `.txt` names, and never escape it.
- GitHub tokens and other secrets must not be echoed to UI, logs, or RPC error messages.
- Development must consider both OpenWrt LuCI package environments: `opkg` / `ipk` on older releases and `apk` / `apk` packages on newer releases. LuCI app package build, install, upgrade, removal, validation, and LuCI Software upload behavior should remain compatible with both unless a change explicitly scopes one environment out.

## Key Paths

- `htdocs/luci-static/resources/view/oxidns/`: LuCI JavaScript pages.
- `root/usr/libexec/rpcd/luci.oxidns`: rpcd shell backend.
- `root/usr/share/luci/menu.d/luci-app-oxidns.json`: LuCI menu entries.
- `root/usr/share/rpcd/acl.d/luci-app-oxidns.json`: rpcd ACL.
- `root/usr/share/oxidns/`: OxiDNS LuCI contract files such as target mappings.
- `po/zh_Hans/oxidns.po`: Simplified Chinese translation.
- `scripts/build-luci-package.sh`: local (offline) LuCI package build script; produces `ipk` / apk-tools 2.x `.apk` for testing, not for release.
- `scripts/check-apk.py`: verifies that a `.apk` is an apk-tools 3 ADB container and asserts its package name / architecture / members.
- `scripts/check.sh`, `scripts/integration-check.sh`, `scripts/release-check.sh`: local validation entry points. `release-check.sh` validates already-built artifacts in a dist directory (it no longer builds anything).

## Common Validation

```sh
scripts/check.sh
scripts/integration-check.sh

# release-check.sh no longer builds; point it at a dist directory that already
# holds SDK-built artifacts (see .github/workflows/build-packages.yml).
scripts/release-check.sh v0.1.4-r4 dist
```

## Commit Notes

- Follow the existing Conventional Commit style for LuCI app changes.
- Changes to package management, config writes, service control, or log access should be checked against rpcd ACLs, frontend callers, and local validation scripts.
