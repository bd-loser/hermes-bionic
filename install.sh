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

# hermes pins every dependency as `==X.Y.Z; python_version >= '3.14'`.
# Below 3.14 those markers do not apply, so the bundle must be — and be
# installed on — 3.14. Termux's main repo ships python 3.14.x; the venv is
# pinned to whichever we pick, so a later `pkg upgrade` of default python
# won't break the install.
want_314() {
  "$1" -c 'import sys;raise SystemExit(0 if (3,14)<=sys.version_info[:2]<(3,15) else 1)' 2>/dev/null
}
pick_python() {
  local p
  if want_314 python; then printf python; return; fi
  pkg install -y tur-repo >/dev/null 2>&1 || true
  for p in python3.14 python3.15; do
    pkg install -y "$p" >/dev/null 2>&1 || continue
    command -v "$p" >/dev/null || continue
    want_314 "$p" || continue
    printf '%s' "$p"; return
  done
  printf none
}
PYBIN="$(pick_python)"
[ "$PYBIN" != none ] || die "no Python 3.14 found. Try: pkg install python (Termux main ships 3.14.x)"
PYMINOR="cp$("$PYBIN" -c 'import sys;print(f"{sys.version_info.major}{sys.version_info.minor}")')"
say "Python: $("$PYBIN" --version) ($PYMINOR)"

# /releases/latest skips prereleases and only returns the newest *stable* release,
# which may not carry a bundle for this Python. Walk recent releases (newest
# first, GitHub's order), preferring stable tags, and take the first one that
# actually has a bundle for $PYMINOR. Prereleases are the fallback.
say "Resolving newest $REPO release with a $PYMINOR bundle..."
RELEASES="$(curl -fsSL "$API/releases?per_page=30" 2>/dev/null \
  | grep -oE '"tag_name":\s*"[^"]+"' | sed -E 's/.*"([^"]+)"/\1/' || true)"
[ -n "$RELEASES" ] || die "could not list releases (network?)"
TAG=""
for pass in stable any; do
  while read -r cand; do
    [ -n "$cand" ] || continue
    # never install experiment/prerelease-only builds, even on the fallback pass
    if [[ "$cand" == *-exp.* ]]; then continue; fi
    if [ "$pass" = stable ] && [[ "$cand" == *-dev* ]]; then continue; fi
    cv="${cand#v}"
    if curl -fsIL -o /dev/null "https://github.com/$REPO/releases/download/$cand/hermes-wheels-${cv}-${PYMINOR}.tar.gz" 2>/dev/null; then
      TAG="$cand"; break 2
    fi
  done <<< "$RELEASES"
done
[ -n "$TAG" ] || die "no release has a $PYMINOR bundle (checked: $(echo $RELEASES | tr '\n' ' ')). Try again later, or use upstream: curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
say "Selected $TAG"
VER="${TAG#v}"
ASSET="hermes-wheels-${VER}-${PYMINOR}.tar.gz"

say "Downloading $ASSET..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$ASSET" \
  "https://github.com/$REPO/releases/download/$TAG/$ASSET" \
  || die "no $ASSET in $TAG — your Termux Python ($PYMINOR) has no prebuilt bundle;
    install python 3.14 from Termux main ('pkg install python'), or run upstream:
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
# The bundle is installed with pip --no-index into a long-lived venv, so an
# unverified archive is a supply-chain risk. Fail closed: no checksum, no install.
curl -fsSL -o "$TMP/$ASSET.sha256" \
  "https://github.com/$REPO/releases/download/$TAG/$ASSET.sha256" \
  || die "could not download checksum for $ASSET (refusing to install unverified bundle)"
( cd "$TMP" && sha256sum -c "$ASSET.sha256" >/dev/null ) \
  || die "checksum MISMATCH for $ASSET (refusing to install)"
say "Checksum verified."

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

"$VENV/bin/hermes" --version >/dev/null 2>&1 \
  || die "hermes installed but does not start: run '$VENV/bin/hermes --version' for details"
say "Done: $("$VENV/bin/hermes" --version 2>/dev/null | head -1)"
echo
echo "Next: configure a provider key, e.g.  export OPENROUTER_API_KEY=***  then run 'hermes'."
