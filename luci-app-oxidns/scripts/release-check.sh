#!/bin/sh

set -eu

VERSION="${1:-${VERSION:-0.1.0}}"
OUT_DIR="${2:-${OUT_DIR:-dist}}"

scripts/check.sh
scripts/integration-check.sh
scripts/build-luci-package.sh "$VERSION" "$OUT_DIR"
scripts/verify-packages.sh "$VERSION" "$OUT_DIR"

printf 'Release check passed for %s in %s\n' "$VERSION" "$OUT_DIR"
