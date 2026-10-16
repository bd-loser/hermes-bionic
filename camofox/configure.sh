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
apt install -y ndk-sysroot gtk3 pulseaudio libvpx libicu libnspr libnss libwebp zlib libjpeg-turbo \
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

  step "apply termux firefox patches (termux-packages set, minus replaced/no-op ones)"
  git config --global --add safe.directory "$(pwd)" || true
  TFP="$WORK/termux-firefox"
  if [ ! -d "$TFP" ]; then
    mkdir -p "$TFP" && cd "$TFP"
    git init -q
    git remote add origin https://github.com/termux/termux-packages.git
    git fetch -q --depth 1 origin "$TERMUX_PKGS_PIN"
    git checkout -q FETCH_HEAD -- x11-packages/firefox
    mv x11-packages/firefox/*.patch .
    rm -rf x11-packages .git
    cd "$WORK/camoufox/browser/$SRC_DIR"
  fi
  # 0003/0012/0023/0028 are replaced by rebased versions in
  # /work/camofox/termux-patches; 0031 fixes a Firefox-157 regression absent
  # at 156 (its HWInference speech code does not exist here yet).
  FAIL=0
  for p in "$TFP"/*.patch; do
    name="$(basename "$p")"
    case "$name" in
      0003-*|0012-*|0023-*|0028-*|0031-*) echo "SKIP $name"; continue;;
    esac
    if git apply --check "$p"; then
      git apply "$p" && git add -A && echo "TERMUX-PATCH PASS $name"
    else
      echo "TERMUX-PATCH FAIL $name"; FAIL=1
    fi
  done

  step "apply our rebased camofox/termux-patches"
  for p in /work/camofox/termux-patches/*.patch; do
    name="$(basename "$p")"
    if git apply --check "$p"; then
      git apply "$p" && git add -A && echo "REBASED-PATCH PASS $name"
    else
      echo "REBASED-PATCH FAIL $name"; FAIL=1
    fi
  done
  [ "$FAIL" = 0 ] || { echo "error: termux-patches did not apply; aborting before configure" >&2; exit 1; }
  git -c user.email=a@a -c user.name=a commit -qm "termux graft" || true
}
cd "$WORK/camoufox/browser/$SRC_DIR"

step "versioned-triple clang wrapper (termux toolchain emulation)"
# termux-packages compiles through versioned-triple wrappers
# ($TERMUX_HOST_PLATFORM-clang = aarch64-linux-android24). Bare "clang" calls
# from cargo/pip/mach would otherwise fail in cdefs ("Unversioned target
# triples are not supported"). Export the wrapped compiler on PATH so every
# consumer (cc-crate, pip sdists, mach) gets the versioned triple.
CWRAP="$HOME/clangwrap"
mkdir -p "$CWRAP"
for tool in clang clang++; do
  # Quoted delimiter: "$@" must survive verbatim into the wrapper script.
  # Incoming --target args are stripped: cargo/cc-crate passes the unversioned
  # host triple (aarch64-linux-android) which termux headers reject; the
  # versioned triple below must be the one clang sees.
  cat > "$CWRAP/$tool" <<'WEOF'
#!/data/data/com.termux/files/usr/bin/bash
args=()
for a in "$@"; do
  case "$a" in
    --target=*) ;;
    *) args+=("$a") ;;
  esac
done
exec "/data/data/com.termux/files/usr/bin/clang" --target=aarch64-unknown-linux-android24 --sysroot=/data/data/com.termux/files/usr "${args[@]}"
WEOF
  chmod 0755 "$CWRAP/$tool"
done
export PATH="$CWRAP:$PATH"
echo 'int main(){}' | clang -xc - -o /dev/null && echo "clang wrapper selftest ok"

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

step "include-path debug (asm/types.h truth)"
ls -la /data/data/com.termux/files/usr/include/asm 2>/dev/null || echo "NO /usr/include/asm"
ls /data/data/com.termux/files/usr/include/asm-generic/types.h 2>/dev/null || echo "no asm-generic/types.h"
echo '#include <sys/types.h>' | clang -E - >/dev/null 2>&1 && echo "sys/types.h preprocess OK" || echo "sys/types.h preprocess FAILED"
echo '#include <asm/types.h>' | clang -E - >/dev/null 2>&1 && echo "asm/types.h OK" || echo "asm/types.h FAILED"
clang -v 2>&1 | grep -E 'Target|InstalledDir'

step "mach configure (log: $OUT/configure.log)"
set +e
# Termux's 0003 patch removes the set_config("RUSTFLAGS") handler from
# rust.configure (cargo reads CARGO_TARGET_*_RUSTFLAGS at build time). With
# that gone, a stray RUSTFLAGS env var becomes a configure error — unset it
# everywhere it could hide and show what is actually set.
env | grep -i rust || echo "(no rust env vars)"
unset RUSTFLAGS RUSTFLAGS_aarch64_linux_android CAMERA_RUSTFLAGS 2>/dev/null || true
# ./mach's '#!/usr/bin/env python3' shebang fails on the image (no /usr/bin/env);
# run it through the interpreter directly.
python3 ./mach configure 2>&1 | tee "$OUT/configure.log"
RC=${PIPESTATUS[0]}
set -e
echo "configure exit: $RC" | tee -a "$OUT/configure.log"
# Full mozbuild config.log (objdir) is essential for deep-diving failures.
OBJCFG="$(find "$HOME/.mozbuild/srcdirs" -name config.log -path '*obj-*' 2>/dev/null | head -1)"
[ -n "$OBJCFG" ] && cp "$OBJCFG" "$OUT/config-full.log" || echo "(no objdir config.log found)" | tee -a "$OUT/configure.log"
[ "$RC" = 0 ] \
  && step "CONFIGURE OK" \
  || { step "CONFIGURE FAILED (tail above; full log in artifact)"; exit "$RC"; }
