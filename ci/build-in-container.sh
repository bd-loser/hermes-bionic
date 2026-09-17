#!/data/data/com.termux/files/usr/bin/bash
# Runs INSIDE termux-docker (aarch64). Clones NousResearch/hermes-agent at
# the pinned release tag and builds a COMPLETE wheel bundle for the
# `.[termux]` extra, so phones never compile anything (Bionic-native wheels
# for cryptography/pydantic-core/aiohttp/... are the whole reason this
# exists).
#
# Env inputs (via /out/build-env.sh; the container entrypoint strips env):
#   HERMES_VERSION     upstream release tag suffix, e.g. 2026.9.14 (tag v2026.9.14)
#   HERMES_UPSTREAM_REF optional; branch/commit to build instead of the tag
#
# Mounts: /workspace = this repo, /out = world-writable artifact dir.

set -euo pipefail

if [ -f /out/build-env.sh ]; then
  # shellcheck disable=SC1091
  . /out/build-env.sh
fi
HERMES_VERSION="${HERMES_VERSION:?HERMES_VERSION must be set}"
HERMES_UPSTREAM_REF="${HERMES_UPSTREAM_REF:-}"
export HERMES_UPSTREAM_REF

echo "deb https://packages.termux.dev/apt/termux-main stable main" \
  > "${PREFIX:-/data/data/com.termux/files/usr}/etc/apt/sources.list"
apt update -y
apt install -y git python clang rust make pkg-config libffi openssl ca-certificates curl

BUILD_ROOT="$HOME/hermes-build"
rm -rf "$BUILD_ROOT"

if [ -n "$HERMES_UPSTREAM_REF" ]; then
  git init -q "$BUILD_ROOT"
  git -C "$BUILD_ROOT" remote add origin https://github.com/NousResearch/hermes-agent.git
  git -C "$BUILD_ROOT" fetch -q --depth 1 origin "$HERMES_UPSTREAM_REF"
  git -C "$BUILD_ROOT" checkout -q FETCH_HEAD
else
  git clone -q --depth 1 -b "v$HERMES_VERSION" \
    https://github.com/NousResearch/hermes-agent.git "$BUILD_ROOT"
fi

PYTAG=""
pick_python() {
  # hermes requires-python is >=3.11,<3.14; termux's default python may sit
  # outside it (3.14.x). Same fallback ladder as upstream's installer:
  # TUR publishes versioned CPythons (python3.13 = the one phones get).
  local p
  if python -c 'import sys;raise SystemExit(0 if (3,11)<=sys.version_info[:2]<(3,14) else 1)' 2>/dev/null; then
    printf python; return
  fi
  pkg install -y tur-repo >/dev/null 2>&1 || true
  for p in python3.13 python3.12 python3.11; do
    pkg install -y "$p" >/dev/null 2>&1 || continue
    command -v "$p" >/dev/null || continue
    if "$p" -c 'import sys;raise SystemExit(0 if (3,11)<=sys.version_info[:2]<(3,14) else 1)' 2>/dev/null; then
      printf '%s' "$p"; return
    fi
  done
  printf none
}
PYBIN="$(pick_python)"
[ "$PYBIN" != none ] || { echo "error: no Python 3.11-3.13 available (TUR install failed?)" >&2; exit 1; }
PYTAG="cp$("$PYBIN" -c 'import sys;print(f"{sys.version_info.major}{sys.version_info.minor}")')"
echo "→ building wheels for $PYTAG ($PYBIN), hermes $HERMES_VERSION"

# termux-docker has no /tmp for the unprivileged `system` user; Termux
# convention is $PREFIX/tmp. Everything that reaches for a scratch dir
# (pip tempdirs, venv, tar staging) follows TMPDIR.
export TMPDIR="$HOME/tmp"
mkdir -p "$TMPDIR"

"$PYBIN" -m venv "$HOME/benv"
# shellcheck disable=SC1091
. "$HOME/benv/bin/activate"
pip install --quiet --upgrade pip wheel

BUNDLE="hermes-wheels-${HERMES_VERSION}-${PYTAG}"
WHEELS="$TMPDIR/$BUNDLE"
mkdir -p "$WHEELS"

pip wheel "$BUILD_ROOT[termux]" \
  -c "$BUILD_ROOT/constraints-termux.txt" \
  -w "$WHEELS"

echo "$HERMES_VERSION" > "$WHEELS/HERMES_VERSION"
tar -czf "/out/$BUNDLE.tar.gz" -C "$TMPDIR" "$BUNDLE"
( cd /out && sha256sum "$BUNDLE.tar.gz" > "$BUNDLE.tar.gz.sha256" )
ls -la /out/
echo "built: $BUNDLE.tar.gz ($(du -h "/out/$BUNDLE.tar.gz" | cut -f1))"
