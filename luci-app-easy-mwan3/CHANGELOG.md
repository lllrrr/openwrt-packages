# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.1] - 2026-03-07

### Security
- **Fixed XSS vulnerability** in status.htm - Added HTML escaping for dynamic content
- **Fixed command injection risk** in easy_mwan3.lua - Replaced `io.popen` with safe `nixio.fs.readfile`

### Added
- **UCI configuration file** - `/etc/config/easy_mwan3` for storing settings
- **init.d startup script** - Proper service management with procd support
- **Configuration apply script** - `/usr/bin/easy_mwan3_apply.sh` to convert config to mwan3
- **Status API endpoint** - `action_status()` function in controller for real-time status
- **fw3/fw4 compatibility check** - Automatic detection with user-friendly warning
- **Incompatible firewall view** - `incompatible.htm` template for fw4 systems
- **Improved interface detection** - Support for pppoe, 3g/4g, WireGuard interfaces
- **Error handling** - Comprehensive error handling and user feedback

### Fixed
- Fixed missing configuration file installation in Makefile
- Fixed missing init.d script installation in Makefile
- Fixed interface detection to read from UCI config
- Fixed DHCP lease parsing to handle different formats
- Fixed status page polling interval (increased from 5s to 10s)

### Changed
- Updated Makefile to include all necessary files
- Updated translation files with new strings
- Improved code quality with proper variable scoping (added `local` keywords)
- Updated version to 2.1.1 with PKG_RELEASE=2

### Security
- All dynamic content is now properly escaped in HTML
- No shell command execution from Lua code
- Proper input validation added

## [2.1] - 2026-01-21

### Added
- i18n internationalization support
- Chinese translation (zh_Hans)
- Translation template (pot file)
- fw4/nftables incompatibility warning in README
- CHANGELOG.md

### Changed
- Removed redundant `ff0f8630...` subdirectory
- Updated Makefile to use standard `luci.mk` build system
- Added `PKG_NAME` for proper package registration
- Removed `ipset` dependency (not needed for basic functionality)

### Removed
- Deleted 76 redundant files (backup files, generated files)

## [1.0] - 2024-XX-XX

### Added
- Initial release
- Basic MWAN3 configuration interface
- Simple load balancing and failover support

---

[2.1.1]: https://github.com/pengcong226/luci-app-easy-mwan3/compare/v2.1...v2.1.1
[2.1]: https://github.com/pengcong226/luci-app-easy-mwan3/compare/v1.0...v2.1
[1.0]: https://github.com/pengcong226/luci-app-easy-mwan3/releases/tag/v1.0
