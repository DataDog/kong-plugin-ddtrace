#!/usr/bin/env bash
# Build libdatadog's libdd-ai-usage-ffi, which the plugin requires for its AI
# usage metrics, at the ref in .libdatadog-version, into
# lib/libdd_ai_usage_ffi-<arch>.so: the name the rockspec installs and the
# plugin loads. Needs git and cargo. CI runs it in a manylinux2014 image, so
# the library needs nothing newer than glibc 2.17 and loads on every
# distribution Kong ships for.
#
# Usage: scripts/build-libdd-ai-usage.sh [output-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/lib}"
REF="$(tr -d '[:space:]' < "$ROOT/.libdatadog-version")"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64 | aarch64) ;;
    arm64) ARCH=aarch64 ;;
    *)
        echo "unsupported architecture: $ARCH" >&2
        exit 1
        ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q libdatadog
git -C "$WORK/libdatadog" fetch -q --depth 1 https://github.com/DataDog/libdatadog.git "$REF"
git -C "$WORK/libdatadog" checkout -q FETCH_HEAD

# Line tables are kept by libdatadog's release profile; the plugin ships
# the library on its own, so they are stripped.
(cd "$WORK/libdatadog" && CARGO_PROFILE_RELEASE_STRIP=debuginfo cargo build --locked --release -p libdd-ai-usage-ffi)

mkdir -p "$OUT"
cp "$WORK/libdatadog/target/release/libdd_ai_usage_ffi.so" "$OUT/libdd_ai_usage_ffi-$ARCH.so"
echo "$OUT/libdd_ai_usage_ffi-$ARCH.so (libdatadog $REF)"
