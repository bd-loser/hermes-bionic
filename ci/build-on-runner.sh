#!/usr/bin/env bash
# Runs on the GitHub Actions runner (ubuntu-24.04-arm). Builds the Termux
# wheel bundle inside termux-docker. Output lands in ../out/ next to the
# workspace: hermes-wheels-<ver>-<pytag>.tar.gz (+ .sha256).

set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"

mkdir -p "$GITHUB_WORKSPACE/../out"
OUT_HOST="$(cd "$GITHUB_WORKSPACE/../out" && pwd)"
chmod 0777 "$OUT_HOST"

cat > "$OUT_HOST/build-env.sh" <<EOF
export HERMES_VERSION='${HERMES_VERSION:-}'
export HERMES_UPSTREAM_REF='${HERMES_UPSTREAM_REF:-}'
EOF
chmod 0644 "$OUT_HOST/build-env.sh"

docker run --rm \
  -v "$GITHUB_WORKSPACE:/workspace" \
  -v "$OUT_HOST:/out" \
  -w /workspace \
  termux/termux-docker:aarch64 \
  bash /workspace/ci/build-in-container.sh

echo "$OUT_HOST"
