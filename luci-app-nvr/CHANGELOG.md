# Changelog

## [20230818-2] - 2026-01-22

### Changed

- **Internationalization**: Converted Chinese strings in HTM files to English with i18n support
- **Makefile**: Updated to use standard `luci.mk` build system

### Added

- **Translation Support**: Added `po/templates/nvr.pot` template file
- **Chinese Translation**: Added `po/zh_Hans/nvr.po` for Chinese localization
- Separate `luci-i18n-nvr-zh-cn` package will be generated during build

### Removed

- Removed legacy `luasrc/i18n/` directory (translations now in `po/`)
- Removed old `nvr.zh-cn.po` file from root

## [20230818] - Initial Release

### Features

- Network Video Recorder for IP cameras
- Support for Hikvision, TP-Link, and generic RTSP/RTMP cameras
- One-click recording and streaming
- Configurable storage settings
- Loop recording with disk space management
