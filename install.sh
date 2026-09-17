#!/data/data/com.termux/files/usr/bin/bash
# hermes-bionic installer — Hermes Agent on Termux without compiling.
#
#   curl -fsSL https://raw.githubusercontent.com/bd-loser/hermes-bionic/main/install.sh | bash
#
# Downloads the CI-built `.[termux]` dependency wheel bundle (compiled in
# termux-docker on ubuntu-24.04-arm), clones the matching upstream release,
# and installs everything into ~/.hermes/venv from local wheels only.
# No on-device Rust/C builds, no uv, no proot.

set -euo pipefail

REPO="bd-loser/hermes-bionic"
API="https://api.github.com/repos/$REPO"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] \
  || die "run this inside Termux (PREFIX not set)"

say "Installing Termux prerequisites..."
# openssl/libffi/libjpeg-turbo/libpng/zlib/freetype/libwebp/libheif are
# runtime .so deps of the bundled wheels (cryptography, Pillow,
# pillow-heif) — wheels link against the Termux system libs.
pkg install -y python curl ca-certificates git ripgrep \
  openssl libffi libjpeg-turbo libpng zlib freetype libwebp libheif >/dev/null 2>&1 \
  || die "pkg install failed"

# hermes needs CPython >=3.11,<3.14; Termux's default python may be newer.
# TUR publishes versioned interpreters (python3.13) — same ladder upstream
# uses. The venv is pinned to whichever we pick, so a later `pkg upgrade`
# of default python won't break the install.
pick_python() {
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
[ "$PYBIN" != none ] || die "no Python 3.11-3.13 found. Try: pkg install tur-repo && pkg install python3.13"
PYMINOR="cp$("$PYBIN" -c 'import sys;print(f"{sys.version_info.major}{sys.version_info.minor}")')"
say "Python: $("$PYBIN" --version) ($PYMINOR)"

say "Resolving latest $REPO release..."
TAG="$(curl -fsSL "$API/releases/latest" 2>/dev/null \
  | grep -oE '"tag_name":\s*"[^"]+"' | sed -E 's/.*"([^"]+)"/\1/' || true)"
[ -n "$TAG" ] || die "could not resolve latest release (network?)"
VER="${TAG#v}"
ASSET="hermes-wheels-${VER}-${PYMINOR}.tar.gz"

say "Downloading $ASSET..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$ASSET" \
  "https://github.com/$REPO/releases/download/$TAG/$ASSET" \
  || die "no $ASSET in $TAG — your Termux Python ($PYMINOR) has no prebuilt bundle;
   install a matching one (e.g. 'pkg install tur-repo && pkg install python3.13') or run upstream:
   curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
curl -fsSL -o "$TMP/$ASSET.sha256" \
  "https://github.com/$REPO/releases/download/$TAG/$ASSET.sha256" \
  && ( cd "$TMP" && sha256sum -c "$ASSET.sha256" ) \
  || warn "checksum unavailable/skipped"

say "Unpacking wheels into $HERMES_HOME..."
mkdir -p "$HERMES_HOME"
rm -rf "$HERMES_HOME/wheels"
mkdir -p "$HERMES_HOME/wheels/$PYMINOR"
tar -xzf "$TMP/$ASSET" --strip-components=1 -C "$HERMES_HOME/wheels/$PYMINOR"

say "Creating venv..."
VENV="$HERMES_HOME/venv"
rm -rf "$VENV"
"$PYBIN" -m venv "$VENV"
# setuptools+wheel up front: the editable install below runs with
# --no-build-isolation (fully offline), so the backend must pre-exist.
"$VENV/bin/pip" install --quiet --upgrade pip setuptools wheel

say "Installing dependencies (from local wheels, nothing compiles)..."
# pins.txt is the exact set CI resolved: == pins + --no-index makes the
# phone-side resolution hermetic, so a newer PyPI release can never sneak
# in an sdist that would compile on-device.
# pip -q stays mute for a full minute here (78 wheels), which reads like a
# hang; count installed .dist-info dirs to tick a compact progress line.
PIP_LOG="$HERMES_HOME/install-pip.log"
TOTAL_DEPS="$(grep -c . "$HERMES_HOME/wheels/$PYMINOR/pins.txt")"
SITE="$VENV/lib/python$("$PYBIN" -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')/site-packages"
"$VENV/bin/pip" install -q --no-index \
  --find-links "$HERMES_HOME/wheels/$PYMINOR" \
  -r "$HERMES_HOME/wheels/$PYMINOR/pins.txt" 2>"$PIP_LOG" &
PIP_PID=$!
while kill -0 "$PIP_PID" 2>/dev/null; do
  sleep 3
  if [[ -t 1 ]]; then
    n="$(find "$SITE" -maxdepth 1 -name '*.dist-info' -type d 2>/dev/null | wc -l)"
    printf '\r\033[2K\033[36m==>\033[0m installed %s/%s wheels...' "$n" "$TOTAL_DEPS"
  fi
done
wait "$PIP_PID" || { echo; tail -15 "$PIP_LOG" >&2; die "pip dependency install failed (full log: $PIP_LOG)"; }
[[ -t 1 ]] && printf '\r\033[2K' || true

say "Installing hermes-agent itself (editable, from upstream git)..."
# hermes-agent's setup.py refuses bdist_wheel/sdist outside Nix, so it is
# NOT in the bundle; the editable (PEP 660) path is explicitly allowed by
# its guard and needs no compilation (pure Python).
VER="$(sed -n 's/^HERMES_VERSION=//p' "$HERMES_HOME/wheels/$PYMINOR/META.txt")"
[ -n "$VER" ] || die "META.txt missing HERMES_VERSION in bundle"
SRC="$HERMES_HOME/hermes-agent"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --quiet --depth 1 origin "refs/tags/v$VER:refs/tags/v$VER" || true
  git -C "$SRC" checkout --quiet "v$VER" \
    || die "cannot check out v$VER in $SRC"
else
  rm -rf "$SRC"
  # shallow clones of a big repo flake on mobile networks (SSL EOF mid
  # fetch-pack) — retry instead of dying on the first attempt.
  for i in 1 2 3 4 5; do
    if git clone --quiet --depth 1 --branch "v$VER" \
      https://github.com/NousResearch/hermes-agent.git "$SRC"; then
      break
    fi
    rm -rf "$SRC"
    [ "$i" = 5 ] && die "git clone of hermes-agent v$VER failed after 5 attempts"
    warn "clone attempt $i failed, retrying in 10s..."
    sleep 10
  done
fi
"$VENV/bin/pip" install -q --no-index --no-deps --no-build-isolation \
  --find-links "$HERMES_HOME/wheels/$PYMINOR" \
  -e "$SRC[termux]"

ln -sf "$VENV/bin/hermes" "$PREFIX/bin/hermes"
ln -sf "$VENV/bin/hermes-agent" "$PREFIX/bin/hermes-agent" 2>/dev/null || true
ln -sf "$VENV/bin/hermes-acp" "$PREFIX/bin/hermes-acp" 2>/dev/null || true

say "Done: $(hermes --version 2>/dev/null || echo 'hermes installed — run: hermes')"
echo
echo "Next: configure a provider key, e.g.  export OPENROUTER_API_KEY=***  then run 'hermes'."
