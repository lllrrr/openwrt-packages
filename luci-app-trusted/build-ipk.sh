#!/bin/sh
# Build luci-app-trusted IPK (no OpenWrt SDK required).
#
# The real work is in build-ipk.py: this opkg build only accepts an .ipk that
# is a gzip-compressed tar archive containing debian-binary, control.tar.gz
# and data.tar.gz. A flat concatenation is rejected with
# "pkg_init_from_file: Malformed package file".
set -e
cd "$(dirname "$0")"
exec python3 ./build-ipk.py "$@"
