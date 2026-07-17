# Changelog

## [1.1.16-1] - 2026-07-17

### Changed

- Improved HTTPing and TCPing probe reliability and validation
- Added bounded history aggregation, retention cleanup, and safer database operations
- Prevented overlapping refresh requests and hardened frontend rendering
- Expanded Simplified Chinese translations, CI checks, and licensing metadata

## [1.1.14-2] - 2026-01-21

### Changed

- **Internationalization**: Converted all Chinese strings to English with i18n support
- **Makefile**: Updated to use standard `luci.mk` build system

### Added

- **Translation Support**: Added `po/templates/httping.pot` template file
- **Chinese Translation**: Added `po/zh_Hans/httping.po` for Chinese localization
- Separate `luci-i18n-httping-zh-cn` package will be generated during build

## [1.1.14] - Initial Release

### Features

- Network latency monitoring using HTTPing and TCPing
- Real-time ECharts visualization with trend graphs
- Multiple server node support
- Configurable detection intervals
- SQLite database for historical data storage
- Auto-refresh and peak clipping (smoothing) options
- Time range presets (1h, 6h, 12h, 24h, 7d, 1m, 6m, 1y)
- Custom time range queries
- Server filtering with packet loss statistics
- Dark/Light mode support
