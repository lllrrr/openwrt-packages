#!/bin/bash

set -e

PKG_NAME=luci-app-block-host
PKG_VERSION=1.0.0
PKG_RELEASE=1
PKG_ARCH=all
PKG_FULLNAME=${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${PKG_ARCH}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
IPK_DIR="${SCRIPT_DIR}/ipk"

echo "Building ${PKG_FULLNAME}..."

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

rm -rf *

echo "2.0" > debian-binary

mkdir -p control
cp "${IPKG_DIR}/control" control/
tar -czf control.tar.gz -C control .

mkdir -p data
cp -r "${SCRIPT_DIR}/root"/* data/ 2>/dev/null || true

if [ -d "${SCRIPT_DIR}/root" ]; then
    cp -r "${SCRIPT_DIR}/root"/* data/
fi

chmod +x data/usr/bin/bind_and_block.sh 2>/dev/null || true
chmod +x data/etc/init.d/block_host 2>/dev/null || true

tar -czf data.tar.gz -C data .

tar -czf "../${PKG_FULLNAME}.ipk" debian-binary control.tar.gz data.tar.gz

cd ..
rm -rf "${BUILD_DIR}"

echo "Successfully created ${PKG_FULLNAME}.ipk"
ls -lh "${PKG_FULLNAME}.ipk"