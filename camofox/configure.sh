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
apt install -y ndk-sysroot ndk-multilib gtk3 pulseaudio libvpx libicu libnspr libnss libwebp zlib libjpeg-turbo \
  libpng freetype fontconfig gdk-pixbuf glib libffi libevent ffmpeg libcairo \
  libx11 libxcb libice libsm libxext libandroid-shmem libandroid-spawn

# pyo3/uniffi wheels in the mach venvs are built by maturin, which refuses
# Android without an explicit API level (upstream never builds on Android).
export ANDROID_API_LEVEL=24

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
TERMUX_PREFIX_UX="${PREFIX:-/data/data/com.termux/files/usr}"
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
    # Termux substitutes build variables (@TERMUX_PREFIX@ etc.) in patch
    # files before applying; raw placeholders would end up as literal paths
    # inside the binary (0009's shm_open("/@TERMUX_PREFIX@/tmp/...")!).
    sed -e "s|@TERMUX_PREFIX@|$TERMUX_PREFIX_UX|g" \
        -e "s|@TERMUX_HOST_PLATFORM@|aarch64-linux-android|g" \
        "$p" > "$WORK/termux-patch-$name"
    if git apply --check "$WORK/termux-patch-$name"; then
      git apply "$WORK/termux-patch-$name" && git add -A && echo "TERMUX-PATCH PASS $name"
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

  step "refresh vendored cargo checksums (patches edit vendored crates)"
  # Cargo verifies every file listed in a vendored crate's
  # .cargo-checksum.json; patches that touch third_party/rust/* must update
  # those entries or the build dies ("directory sources are not intended to
  # be edited"). Recompute drift for all vendored crates in one sweep.
  python3 - <<'PYCS'
import hashlib, json
from pathlib import Path
for cc in Path(".").glob("third_party/rust/*/.cargo-checksum.json"):
    d = json.loads(cc.read_text())
    files = d.get("files", {})
    changed = False
    for rel, sha in list(files.items()):
        f = cc.parent / rel
        if f.is_file():
            h = hashlib.sha256(f.read_bytes()).hexdigest()
            if h != sha:
                files[rel] = h
                changed = True
    if changed:
        cc.write_text(json.dumps(d, separators=(",", ":")))
        print("checksums updated:", cc.parent.name)
PYCS
  git add -A
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
    # Legacy cc-crate injection: flips vendored C code (glslopt et al.) into
    # NDK-only branches (#include <log/log.h>) that Termux cannot satisfy.
    # __ANDROID__ remains defined via the versioned triple.
    -DANDROID) ;;
    *) args+=("$a") ;;
  esac
done
# No --sysroot: this is the native Termux compiler; it resolves its own
# prefix include/lib dirs (the phone builds the same code without one).
# Forcing --sysroot shadows the baked-in include order (asm/types.h class).
exec "/data/data/com.termux/files/usr/bin/clang" --target=aarch64-unknown-linux-android24 "${args[@]}"
WEOF
  chmod 0755 "$CWRAP/$tool"
done
export PATH="$CWRAP:$PATH"
echo 'int main(){}' | clang -xc - -o /dev/null && echo "clang wrapper selftest ok"

step "build env (mirrors termux build.sh pre_configure)"
TERMUX_HOST_PLATFORM=aarch64-linux-android
CARGO_TARGET_NAME=aarch64-linux-android
export CC=clang CXX=clang++
# Host tools (elfhack relrhack etc.) are compiled AND linked natively: use
# the absolute native compiler and add the libc++ library the host linker
# needs (ld.lld adds no default -lc++_shared; termux libc++ ABI is __ndk1).
export HOST_CC="$PREFIX_DIR/bin/clang"
export HOST_CXX="$PREFIX_DIR/bin/clang++"
export HOST_LDFLAGS="-L$PREFIX_DIR/lib -lc++_shared"
export BINDGEN_CFLAGS="--target=aarch64-unknown-linux-android24"
export BINDGEN_EXTRA_CLANG_ARGS_AARCH64_LINUX_ANDROID="$BINDGEN_CFLAGS"
export CXXFLAGS="-U__ANDROID__ -D_LIBCPP_HAS_NO_C11_ALIGNED_ALLOC"
# -lc++_shared: bare ld.lld links (small plugin .so's like gmp-clearkey)
# otherwise miss the termux libc++ runtime (ABI __ndk1).
# -lm: FF's android .so links assume NDK libm (sin/cos/exp in liblgpllibs etc.).
# Termux ships it inside ndk-multilib; Android's /system/lib64 provides it at runtime.
# -l:libm.a: static, because modern Android merged libm into libc and does
# not ship /system libm.so — a shared DT_NEEDED would break on real phones.
export LDFLAGS="-landroid-shmem -landroid-spawn -llog -L$PREFIX_DIR/lib -lc++_shared -L$PREFIX_DIR/opt/ndk-multilib/aarch64-linux-android/lib -l:libm.a"
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
[ -n "$OBJCFG" ] && cp "$OBJCFG" "$OUT/config-full.log" || echo "(no objdir config.log found)"
cd "$WORK/camoufox/browser/$SRC_DIR"
[ "$RC" = 0 ] \
  && step "CONFIGURE OK" \
  || { step "CONFIGURE FAILED (tail above; full log in artifact)"; exit "$RC"; }

if [ "${CAMOFOX_BUILD:-0}" != "1" ]; then
  step "configure-only run done (set CAMOFOX_BUILD=1 for mach build)"
  exit 0
fi

step "cargo-linker + maturin android env"
# Firefox routes cargo linking through objdir/build/cargo-linker (a symlink
# its cross-compile logic creates from NDK wrappers). With a native Android
# host/target pair the file is never created, but the linker reference is:
# create it ourselves, pointing at the versioned-triple wrapped clang.
# The objdir lives inside the source tree (MOZ_OBJDIR set by base.mozconfig);
# ~/.mozbuild/srcdirs only holds the mach virtualenvs.
OBJDIR="$(ls -d "$WORK/camoufox/browser/$SRC_DIR"/obj-* 2>/dev/null | head -1)"
echo "objdir: ${OBJDIR:-MISSING}" | tee -a "$OUT/build.log"
[ -n "$OBJDIR" ] || { ls "$WORK/camoufox/browser/$SRC_DIR" >&2; echo "no objdir after configure" >&2; exit 1; }
# rust.mk references $SRC_DIR/build/cargo-linker (topsrcdir), created by the
# cross-compile logic at configure time — absent with our native host pair.
mkdir -p "$WORK/camoufox/browser/$SRC_DIR/build" "$OBJDIR/build"
ln -sf "$HOME/clangwrap/clang" "$WORK/camoufox/browser/$SRC_DIR/build/cargo-linker"
ln -sf "$HOME/clangwrap/clang" "$OBJDIR/build/cargo-linker"
ls -la "$WORK/camoufox/browser/$SRC_DIR/build/cargo-linker" | tee -a "$OUT/build.log"

step "mach build (this is the long one)"
# ccache placement for persistence across runs.
export CCACHE_DIR="/ci-cache/ccache"
mkdir -p "$CCACHE_DIR"
export CCacheGravity="1"
NPROC=$(nproc)
echo "building with -j$NPROC, CCACHE_DIR=$CCACHE_DIR"
time python3 ./mach build -j"$NPROC" 2>&1 | tee "$OUT/build.log"
RC_B=${PIPESTATUS[0]}
echo "build exit: $RC_B" | tee -a "$OUT/build.log"
OBJDIR="$(ls -d "$WORK/camoufox/browser/$SRC_DIR"/obj-* 2>/dev/null | head -1)"  # refresh
BIN="$(find "$WORK/camoufox/browser/$SRC_DIR/obj-"*/dist/bin -name camoufox* -type f 2>/dev/null | head -1)"
HERMES_PKGVER="$(cat "$WORK/camoufox/browser/$SRC_DIR/browser/config/version.txt" 2>/dev/null || echo unknown)"
if [ "$RC_B" = 0 ] && [ -n "$BIN" ]; then
  echo "BUILD OK: $BIN" | tee -a "$OUT/build.log"
  ls -la "$BIN" | tee -a "$OUT/build.log"
  cp "$BIN"* "$OUT/" 2>/dev/null || true
  DISTBIN="$(dirname "$BIN")"
  PKG="$OUT/camoufox-termux-$HERMES_PKGVER-aarch64"
  step "package full dist/bin tree"
  tar -czf "$PKG.tar.gz" -C "$DISTBIN" . 
  ( cd "$(dirname "$PKG.tar.gz")" && sha256sum "$(basename "$PKG.tar.gz")" > "$(basename "$PKG.tar.gz").sha256" )
  du -sh "$PKG.tar.gz" | tee -a "$OUT/build.log"
  exit 0
else
  echo "BUILD FAILED or binary missing (log preserved)" >&2
  exit "${RC_B:-1}"
fi | tee -a "$OUT/configure.log"
[ "$RC" = 0 ] \
  && step "CONFIGURE OK" \
  || { step "CONFIGURE FAILED (tail above; full log in artifact)"; exit "$RC"; }
