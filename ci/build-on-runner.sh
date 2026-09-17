#!/usr/bin/env bash
# Runs on the GitHub Actions runner (ubuntu-24.04-arm). Builds the Termux
# wheel bundle inside termux-docker. Output lands in ../out/ next to the
# workspace: hermes-wheels-<ver>-<pytag>.tar.gz (+ .sha256).
#
# ../ci-cache (persisted via actions/cache in build.yml) is mounted at
# /ci-cache; the container script puts the pip wheel cache and the cargo
# registry there so repeat builds skip finished compiles entirely.
# NOTE: the host dir must live inside the workspace — actions/cache
# rejects `..` in its paths, so `../ci-cache` is not an option.

set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"

mkdir -p "$GITHUB_WORKSPACE/../out"
OUT_HOST="$(cd "$GITHUB_WORKSPACE/../out" && pwd)"
chmod 0777 "$OUT_HOST"

CACHE_HOST="$GITHUB_WORKSPACE/ci-cache"
mkdir -p "$CACHE_HOST"/{pip,pip-a,pip-b,cargo}
chmod -R 777 "$CACHE_HOST"

cat > "$OUT_HOST/build-env.sh" <<EOF
export HERMES_VERSION='${HERMES_VERSION:-}'
export HERMES_UPSTREAM_REF='${HERMES_UPSTREAM_REF:-}'
export PIP_CACHE_DIR='/ci-cache/pip'
export CARGO_HOME='/ci-cache/cargo'
EOF
chmod 0644 "$OUT_HOST/build-env.sh"

docker run --rm \
  -v "$GITHUB_WORKSPACE:/workspace" \
  -v "$OUT_HOST:/out" \
  -v "$CACHE_HOST:/ci-cache" \
  -w /workspace \
  termux/termux-docker:aarch64 \
  bash /workspace/ci/build-in-container.sh

echo "$OUT_HOST"
