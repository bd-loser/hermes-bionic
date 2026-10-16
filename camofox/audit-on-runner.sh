#!/usr/bin/env bash
# Runner-side wrapper for camofox/patch-audit.sh (mirrors ci/build-on-runner.sh
# but with no caches: the audit is a fresh measurement every run).
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"
: "${CAMOFOX_PIN:?CAMOFOX_PIN must be set}"
: "${TERMUX_PKGS_PIN:?TERMUX_PKGS_PIN must be set}"

mkdir -p "$GITHUB_WORKSPACE/camofox-out"
OUT_HOST="$(cd "$GITHUB_WORKSPACE/camofox-out" && pwd)"
chmod 0777 "$OUT_HOST"
chmod 0777 "$OUT_HOST"

# Pass pins as positional args: docker -e does not reliably forward step env.
docker run --rm \
  -v "$GITHUB_WORKSPACE:/workspace" \
  -v "$OUT_HOST:/out" \
  -w /workspace \
  termux/termux-docker:aarch64 \
  bash -c 'export CAMOFOX_PIN="$1" TERMUX_PKGS_PIN="$2"; shift 2; exec bash /workspace/camofox/patch-audit.sh' \
  _ "$CAMOFOX_PIN" "$TERMUX_PKGS_PIN"

echo "$OUT_HOST"
