#!/data/data/com.termux/files/usr/bin/bash
# hermes-bionic installer — Hermes Agent on Termux without compiling.
#
#   curl -fsSL https://raw.githubusercontent.com/bd-loser/hermes-bionic/main/install.sh | bash
#
# Downloads the CI-built `.[termux]` wheel bundle (compiled in termux-docker
# on ubuntu-24.04-arm) and pip-installs it into ~/.hermes/venv from local
# wheels only. No on-device Rust/C builds, no uv, no proot.

set -euo pipefail

REPO="bd-loser/hermes-bionic"
API="https://api.github.com/repos/$REPO"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] \
  || die "run this inside Termux (PREFIX not set)"

PYMINOR="cp$(python -c 'import sys;print(f"{sys.version_info.major}{sys.version_info.minor}")")"
say "Python: $(python --version) ($PYMINOR)"

say "Installing Termux prerequisites..."
pkg install -y python curl ca-certificates git ripgrep >/dev/null \
  || die "pkg install failed"

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
   install a matching one with 'pkg install python' or run upstream:
   curl -fsSL https://hermes-usercontent.nousresearch.com/install.sh | bash"
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
python -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip

say "Installing hermes-agent (from local wheels, nothing compiles)..."
# constraints-termux.txt is unnecessary here: the bundle only contains the
# CI-resolved, Android-tested versions, so --find-links is the constraint.
"$VENV/bin/pip" install \
  --find-links "$HERMES_HOME/wheels/$PYMINOR" \
  "hermes-agent[termux]"

ln -sf "$VENV/bin/hermes" "$PREFIX/bin/hermes"
ln -sf "$VENV/bin/hermes-agent" "$PREFIX/bin/hermes-agent" 2>/dev/null || true
ln -sf "$VENV/bin/hermes-acp" "$PREFIX/bin/hermes-acp" 2>/dev/null || true

say "Done: $(hermes --version 2>/dev/null || echo 'hermes installed — run: hermes')"
echo
echo "Next: configure a provider key, e.g.  export OPENROUTER_API_KEY=***  then run 'hermes'."
