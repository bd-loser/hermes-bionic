#!/data/data/com.termux/files/usr/bin/bash
# Runs only inside termux-docker. No phone-side Rust installation required.
set -euo pipefail
apt update
apt install -y git rust rust-std-aarch64-linux-android clang make pkg-config binutils
export TMPDIR="$HOME/tmp"
mkdir -p "$TMPDIR"
SRC="$TMPDIR/agent-browser"
git init "$SRC"
git -C "$SRC" remote add origin https://github.com/vercel-labs/agent-browser.git
# v0.38.1, the version reported in issue #1. Pin source and Cargo.lock together.
git -C "$SRC" fetch --depth 1 origin aff6125c023b810ea3f2e5deec5379e9a4270bdc
git -C "$SRC" checkout --detach FETCH_HEAD
git -C "$SRC" apply --check /workspace/browser/agent-browser-android.patch
git -C "$SRC" apply /workspace/browser/agent-browser-android.patch
cargo build --locked --profile ci --manifest-path "$SRC/cli/Cargo.toml" -j 2
install -m 755 "$SRC/cli/target/ci/agent-browser" /out/agent-browser-android-arm64
/out/agent-browser-android-arm64 --version
readelf -l /out/agent-browser-android-arm64 | grep '/system/bin/linker64'
(cd /out && sha256sum agent-browser-android-arm64 > agent-browser-android-arm64.sha256)
