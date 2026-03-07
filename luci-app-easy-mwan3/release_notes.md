# Easy MWAN3 v2.1.1 - Complete Implementation

## Security Fixes
- Fixed XSS vulnerability in status.htm
- Fixed command injection risk

## Core Features
- Configuration conversion (easy_mwan3 -> mwan3)
- Hybrid policy engine (global + device-specific)
- Real-time status monitoring
- Configuration validation
- Automated testing suite

## New Scripts
- easy_mwan3_apply.sh: Configuration conversion
- easy_mwan3_policy.sh: Hybrid policy engine
- easy_mwan3_status.sh: Status monitoring
- easy_mwan3_validate.sh: Configuration validation
- easy_mwan3_test.sh: Automated testing

## Improvements
- fw3/fw4 compatibility check
- Improved interface detection
- Enhanced error handling
- Complete documentation

## Installation
```bash
cd /tmp
wget https://github.com/pengcong226/luci-app-easy-mwan3/releases/download/v2.1.1/luci-app-easy-mwan3_2.1.1_all.ipk
opkg install luci-app-easy-mwan3_2.1.1_all.ipk
```

## Requirements
- OpenWrt 21.02+
- firewall3 (fw3) - NOT compatible with fw4
- mwan3 package

See [CHANGELOG.md](CHANGELOG.md) for full details.
