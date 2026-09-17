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

say "Installing Termux prerequisites..."
pkg install -y python curl ca-certificates git ripgrep >/dev/null \
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
