#!/data/data/com.termux/files/usr/bin/bash
# Phase 2a: configure-only run of Camoufox-on-Termux inside termux-docker.
# Builds nothing; proves `mach configure` accepts our termux.mozconfig over
# the fully patched tree (camoufox patches + camofox/termux-patches/*).
# Output: /out/configure.log (+ env dump on failure).

set -euo pipefail

: "${CAMOFOX_PIN:?CAMOFOX_PIN must be set}"
: "${TERMUX_PKGS_PIN:?TERMUX_PKGS_PIN must be set}"

OUT=/out
WORK="$HOME/camofox-build"
PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
mkdir -p "$OUT" "$WORK"
cd "$WORK"

step() { printf '\n===== %s =====\n' "$*"; }
export TMPDIR="$HOME/tmp"; mkdir -p "$TMPDIR"

step "install toolchain + build deps (termux)"
echo "deb https://packages.termux.dev/apt/termux-main stable main" > "$PREFIX_DIR/etc/apt/sources.list"
apt update -y
# Compiler/rust/node from termux (no rustup anywhere in this pipeline).
pkg install -y make python git curl tar xz-utils clang rust nodejs-lts pkg-config \
  binutils cbindgen-bin ccache >/dev/null 2>&1 || \
  apt install -y make python git curl tar xz-utils clang rust nodejs-lts pkg-config binutils ccache
# System libs the configure-time checks need (mirrors TERMUX_PKG_DEPENDS/DEPENDS
# of x11-packages/firefox, trimmed to configure-relevant ones). gtk3/nspr/nss
# and friends live in the x11 repo.
pkg install -y x11-repo >/dev/null 2>&1 || true
apt update -y
apt install -y gtk3 pulseaudio libvpx libicu libnspr libnss libwebp zlib libjpeg-turbo \
  libpng freetype fontconfig gdk-pixbuf glib libffi libevent ffmpeg libcairo \
  libx11 libxcb libice libsm libxext

step "fetch camoufox @ $CAMOFOX_PIN"
[ -d camoufox ] || {
  curl -fsSL -o camoufox.tar.gz \
    "https://codeload.github.com/daijro/camoufox/tar.gz/$CAMOFOX_PIN"
  mkdir camoufox && tar -xzf camoufox.tar.gz -C camoufox --strip-components=1
}
cd camoufox/browser
VERSION="$(sed -n 's/^version=//p' upstream.sh)"
RELEASE="$(sed -n 's/^release=//p' upstream.sh)"
SRC_DIR="camoufox-$VERSION-$RELEASE"

step "fetch Firefox $VERSION source + apply patches"
[ -f "$SRC_DIR/mozconfig" ] || {
  FF_TARBALL="firefox-$VERSION.source.tar.xz"
  [ -f "$FF_TARBALL" ] || curl -fsSL -C - -o "$FF_TARBALL" \
    "https://archive.mozilla.org/pub/firefox/releases/$VERSION/source/$FF_TARBALL"
  make setup-minimal
  # rustup stub: their patcher's cross-target step is replaced by the Termux
  # mozconfig (see NOTES.md). /out is a runner bind mount (exec+lock OK).
  RSHIM="$OUT/.rustup-shim"
  mkdir -p "$RSHIM" "$HOME/.cargo/bin"
  printf '#!/data/data/com.termux/files/usr/bin/bash\necho "rustup-stub: $*" >> /out/rustup-stub.log\nexit 0\n' \
    > "$RSHIM/rustup"
  chmod 0755 "$RSHIM/rustup"
  ln -sf "$RSHIM/rustup" "$HOME/.cargo/bin/rustup"
  export PATH="$HOME/.cargo/bin:$PATH"
  BUILD_TARGET="linux,arm64" python3 scripts/patch.py "$VERSION" "$RELEASE"
  cd "$SRC_DIR"

  git init -q -b main && git add -A
  git -c user.email=a@a -c user.name=a commit -qm "camoufox-patched tree"

  step "apply camofox/termux-patches"
  git config --global --add safe.directory "$(pwd)" || true
  FAIL=0
  for p in /work/camofox/termux-patches/*.patch; do
    name="$(basename "$p")"
    if git apply --check "$p"; then
      git apply "$p" && git add -A && echo "TERMUX-PATCH PASS $name"
    else
      echo "TERMUX-PATCH FAIL $name"; FAIL=1
    fi
  done
  [ "$FAIL" = 0 ] || { echo "error: termux-patches did not apply; aborting before configure" >&2; exit 1; }
  git -c user.email=a@a -c user.name=a commit -qm "termux graft" || true
}
cd "$WORK/camoufox/browser/$SRC_DIR"

step "build env (mirrors termux build.sh pre_configure)"
TERMUX_HOST_PLATFORM=aarch64-linux-android
CARGO_TARGET_NAME=aarch64-linux-android
export CC=clang CXX=clang++
export HOST_CC=clang HOST_CXX=clang++
export BINDGEN_CFLAGS="--target=${TERMUX_HOST_PLATFORM} --sysroot=${PREFIX_DIR}/sysroot"
export BINDGEN_EXTRA_CLANG_ARGS_AARCH64_LINUX_ANDROID="$BINDGEN_CFLAGS"
export CXXFLAGS="-U__ANDROID__ -D_LIBCPP_HAS_NO_C11_ALIGNED_ALLOC"
export LDFLAGS="-landroid-shmem -landroid-spawn -llog"
# gkrust OOM guard, same as termux
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS+=" -C debuginfo=1"
env | grep -E '^(CC|CXX|HOST_|BINDGEN|CXXFLAGS|LDFLAGS|CARGO)' | tee "$OUT/env.txt"
command -v cbindgen >/dev/null || cargo install --quiet cbindgen

step "write mozconfig (base + termux)"
sed -e "s|@TERMUX_HOST_PLATFORM@|${TERMUX_HOST_PLATFORM}|g" \
    -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX:-$PREFIX_DIR}|g" \
    -e "s|@CARGO_TARGET_NAME@|${CARGO_TARGET_NAME}|g" \
    /work/camofox/termux.mozconfig > "$WORK/termux-sub.mozconfig"
# base.mozconfig lives at browser/assets/base.mozconfig
cat ../assets/base.mozconfig "$WORK/termux-sub.mozconfig" > mozconfig

step "mach configure (log: $OUT/configure.log)"
set +e
./mach configure 2>&1 | tee "$OUT/configure.log"
RC=${PIPESTATUS[0]}
set -e
echo "configure exit: $RC" | tee -a "$OUT/configure.log"
[ "$RC" = 0 ] \
  && step "CONFIGURE OK" \
  || { step "CONFIGURE FAILED (tail above; full log in artifact)"; exit "$RC"; }
