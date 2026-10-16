#!/data/data/com.termux/files/usr/bin/bash
# Phase 1 Camoufox-on-Termux audit. Runs INSIDE termux-docker (aarch64).
#
# Applies the Camoufox patch set to a clean Firefox 156.0.1 tree with their
# own tooling, then applies the Termux Firefox patches on top, recording every
# pass/fail. No compilation: this measures exactly how far the two patch sets
# are from coexisting.
#
# Inputs (env):
#   CAMOFOX_PIN      camoufox repo commit (required, hash-pinned)
#   TERMUX_PKGS_PIN  termux-packages commit containing x11-packages/firefox
# Output in /out: audit-report.txt, rejects/<failed>.rej tree, mozconfig used.

set -euo pipefail

: "${CAMOFOX_PIN:?CAMOFOX_PIN must be set}"
: "${TERMUX_PKGS_PIN:?TERMUX_PKGS_PIN must be set}"

OUT=/out
WORK="${TMPDIR:-/tmp}/camofox-audit"
mkdir -p "$OUT/rejects" "$WORK"
cd "$WORK"

step() { printf '\n===== %s =====\n' "$*"; }

step "install container tools"
# Same mirror preamble as ci/build-in-container.sh; output stays visible.
echo "deb https://packages.termux.dev/apt/termux-main stable main" \
  > "${PREFIX:-/data/data/com.termux/files/usr}/etc/apt/sources.list"
apt update -y
apt install -y make python git curl tar xz-utils

step "fetch camoufox @ $CAMOFOX_PIN"
curl -fsSL -o camoufox.tar.gz \
  "https://codeload.github.com/daijro/camoufox/tar.gz/$CAMOFOX_PIN"
mkdir camoufox && tar -xzf camoufox.tar.gz -C camoufox --strip-components=1
cd camoufox/browser
VERSION="$(sed -n 's/^version=//p' upstream.sh)"
RELEASE="$(sed -n 's/^release=//p' upstream.sh)"
echo "camoufox targets Firefox $VERSION-$RELEASE"

step "fetch Firefox $VERSION source"
FF_TARBALL="firefox-$VERSION.source.tar.xz"
curl -fsSL -o "$FF_TARBALL" \
  "https://archive.mozilla.org/pub/firefox/releases/$VERSION/source/$FF_TARBALL"

step "extract + copy additions (their setup-minimal)"
make setup-minimal
SRC_DIR="camoufox-$VERSION-$RELEASE"
test -d "$SRC_DIR"

# Their patcher's mozconfig step runs the literal `~/.cargo/bin/rustup
# target add aarch64-unknown-linux-gnu` (glibc cross setup) and exits if it
# fails. Termux repos ship rust/cargo but no rustup package, and in this port
# that step is moot anyway: phase 2 builds with the Termux mozconfig + Termux
# rust (like termux-packages' firefox), not rustup toolchains. A logging stub
# is therefore exact enough for a patch-application audit.
if ! command -v rustup >/dev/null 2>&1 && ! [ -x "$HOME/.cargo/bin/rustup" ]; then
  mkdir -p "$HOME/.cargo/bin"
  cat > "$HOME/.cargo/bin/rustup" <<'STUB'
#!/usr/bin/env bash
echo "rustup-stub: $*" | tee -a /out/rustup-stub.log
exit 0
STUB
  chmod +x "$HOME/.cargo/bin/rustup"
fi

step "apply Camoufox patch set via their scripts/patch.py"
# BUILD_TARGET is what their multibuild.py exports before `make dir`. Their
# patcher reports per-patch failures and exits non-zero if any fail; the log
# is the evidence we need, so do not abort the audit on it.
BUILD_TARGET="linux,arm64" python3 scripts/patch.py "$VERSION" "$RELEASE" \
  2>&1 | tee "$OUT/camoufox-patch.log" || echo "note: camoufox patch.py reported failures (see log)"
cd "$SRC_DIR"
git init -q -b main && git add -A && git -c user.email=a@a -c user.name=a commit -qm base

step "fetch termux firefox patches @ $TERMUX_PKGS_PIN"
TF_DIR="$WORK/termux-firefox"
mkdir -p "$TF_DIR" && cd "$TF_DIR"
git init -q
git remote add origin https://github.com/termux/termux-packages.git
git fetch -q --depth 1 origin "$TERMUX_PKGS_PIN"
git checkout -q FETCH_HEAD -- x11-packages/firefox
mv x11-packages/firefox/* .
rm -rf x11-packages .git
N_TERMUX=$(ls *.patch 2>/dev/null | wc -l)
echo "termux firefox patches: $N_TERMUX"

step "apply termux patches on the camoufox-patched tree"
cd "$WORK/camoufox/browser/$SRC_DIR"
PASS=0; FAIL=0; : > "$OUT/audit-report.txt"
echo "camoufox pin: $CAMOFOX_PIN (firefox $VERSION-$RELEASE)" > "$OUT/audit-report.txt"
echo "termux-packages pin: $TERMUX_PKGS_PIN" >> "$OUT/audit-report.txt"
echo "termux patches: $N_TERMUX" >> "$OUT/audit-report.txt"
for p in $(ls "$TF_DIR"/*.patch | sort); do
  name="$(basename "$p")"
  if git apply --check "$p" 2>"$OUT/rejects/$name.check.log"; then
    git apply "$p" && PASS=$((PASS + 1)) && echo "PASS $name" >> "$OUT/audit-report.txt"
  else
    FAIL=$((FAIL + 1))
    git apply --rejects "$p" >"$OUT/rejects/$name.apply.log" 2>&1 || true
    GOT=$(find . -name '*.rej' -newer "$OUT/audit-report.txt" 2>/dev/null | wc -l)
    echo "FAIL $name (rej files: $GOT; see rejects/$name.apply.log)" >> "$OUT/audit-report.txt"
  fi
done
echo "PASS=$PASS FAIL=$FAIL of $N_TERMUX termux patches" >> "$OUT/audit-report.txt"
find . -name '*.rej' -exec mv {} "$OUT/rejects/" \; 2>/dev/null || true

step "done"
cat "$OUT/audit-report.txt"
