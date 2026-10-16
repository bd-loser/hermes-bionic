#!/usr/bin/env bash
# Runner-side wrapper for camofox/patch-audit.sh (mirrors ci/build-on-runner.sh
# but with no caches: the audit is a fresh measurement every run).
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"
: "${CAMOFOX_PIN:?CAMOFOX_PIN must be set}"
: "${TERMUX_PKGS_PIN:?TERMUX_PKGS_PIN must be set}"

mkdir -p "$GITHUB_WORKSPACE/../camofox-out"
OUT_HOST="$(cd "$GITHUB_WORKSPACE/../camofox-out" && pwd)"
chmod 0777 "$OUT_HOST"

docker run --rm \
  -v "$GITHUB_WORKSPACE:/workspace" \
  -v "$OUT_HOST:/out" \
  -w /workspace \
  -e CAMOFOX_PIN -e TERMUX_PKGS_PIN \
  termux/termux-docker:aarch64 \
  bash /workspace/camofox/patch-audit.sh

echo "$OUT_HOST"
