#!/bin/bash
# Build script for devman - handles Go compilation
set -e
SRC_DIR="$1"
OUT_DIR="$2"

export HOME="$SRC_DIR"
export GOMODCACHE="$SRC_DIR/.gomodcache"
export PATH="/usr/local/go/bin:$PATH"

cd "$SRC_DIR"
export HOME="$SRC_DIR"
export PATH="/usr/local/go/bin:$PATH"
go mod download
CGO_ENABLED=0 go build -ldflags="-s -w" -o "$OUT_DIR/devman" .
