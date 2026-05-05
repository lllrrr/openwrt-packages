#!/bin/bash
# kiwi-build.sh — 交叉编译 kixdns for OpenWrt
# 调用方式: ./kiwi-build.sh <PKG_BUILD_DIR> <TOPDIR> <TOOLCHAIN_DIR>

set -e
PKG_BUILD_DIR="$1"
TOPDIR="$2"
TOOLCHAIN_DIR="$3"
PKG_VERSION="0.1.0"
RUST_TARGET="x86_64-unknown-linux-musl"

# 解压源码（如果需要）
EXTRACT_DIR="$PKG_BUILD_DIR"
if [ ! -f "$PKG_BUILD_DIR/Cargo.toml" ]; then
    rm -rf "$PKG_BUILD_DIR"
    mkdir -p "$(dirname "$PKG_BUILD_DIR")"
    tar xzf "$TOPDIR/dl/kixdns-$PKG_VERSION.tar.gz" -C "$(dirname "$PKG_BUILD_DIR")"
    mv "$(dirname "$PKG_BUILD_DIR")/kixdns-main" "$PKG_BUILD_DIR"
fi

# 交叉编译
export PATH="$TOOLCHAIN_DIR:${PATH}"
export CC=gcc
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="$TOOLCHAIN_DIR/x86_64-openwrt-linux-musl-gcc"
export RUSTFLAGS="-Clinker=$TOOLCHAIN_DIR/x86_64-openwrt-linux-musl-gcc -Ccodegen-units=1"

cargo build --release \
    --target "$RUST_TARGET" \
    --manifest-path "$PKG_BUILD_DIR/Cargo.toml"

echo "BUILD OK: $PKG_BUILD_DIR/target/$RUST_TARGET/release/kixdns"
