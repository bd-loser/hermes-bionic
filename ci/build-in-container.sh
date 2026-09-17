#!/data/data/com.termux/files/usr/bin/bash
# Runs INSIDE termux-docker (aarch64). Clones NousResearch/hermes-agent at
# the pinned release tag and builds a wheel bundle of its `.[termux]`
# DEPENDENCIES, so phones never compile anything (Bionic-native wheels
# for cryptography/pydantic-core/aiohttp/... are the whole reason this
# exists).
#
# hermes-agent ITSELF is deliberately not wheelified: its setup.py refuses
# bdist_wheel/sdist outside Nix (HERMES_NIX_BUILD guard). Phones install it
# from the upstream git tag as an editable install (PEP 660 path the guard
# explicitly allows), with every dependency resolved offline from this
# bundle (pins.txt). This mirrors upstream's own Termux flow:
#   pip install -e '.[termux]' -c constraints-termux.txt
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
# libjpeg-turbo/zlib/libpng/freetype/libwebp: Pillow's C ext needs them and
# its sdist build fails cryptically without (its setup.py prints the real
# cause above "Failed building wheel for Pillow").
# libheif: pillow-heif links it; the sdist build needs the headers + .pc.
apt install -y git python clang rust make pkg-config libffi openssl ca-certificates curl patch jq \
  libjpeg-turbo zlib libpng freetype libwebp libheif

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

# maturin-based wheels (firecrawl-anydoc, pydantic-core, ...) refuse to
# build on Android without an explicit API level; on-device this comes from
# `getprop`, the container has none. API 24 keeps the wheels loadable on the
# widest range of devices.
export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-24}"
echo "→ ANDROID_API_LEVEL=$ANDROID_API_LEVEL"

# autotools scripts (uvloop's vendored libuv ./configure) have a #!/bin/sh
# shebang, but the image has no /bin/sh and we can't create one (non-root).
# Point every shell lookup at the interpreter that actually exists.
SH_BIN="$(command -v sh || command -v bash)"
export SHELL="$SH_BIN" CONFIG_SHELL="$SH_BIN" INSTALL_SHELL="$SH_BIN"
echo "→ SHELL=$SH_BIN"

"$PYBIN" -m venv "$HOME/benv"
# shellcheck disable=SC1091
. "$HOME/benv/bin/activate"
pip install --upgrade pip wheel

BUNDLE="hermes-wheels-${HERMES_VERSION}-${PYTAG}"
WHEELS="$TMPDIR/$BUNDLE"
mkdir -p "$WHEELS"

# psutil's setup.py refuses sys.platform=="android" upstream. Termux ships
# python-psutil with an android.patch; build that patched tree FIRST and
# hand it to the resolver via --find-links so every psutil reference
# resolves to it (a local wheel beats PyPI's sdist, which can't build
# here).
PSUTIL_VER="7.2.2"
PSUTIL_PATCH_COMMIT="d8e0fab40f58388602048fd349cd233b3b5d0169"
PSUTIL_DIR="$TMPDIR/psutil-src"
mkdir -p "$PSUTIL_DIR"
curl -fsSL -o "$TMPDIR/psutil.tar.gz" \
  "https://github.com/giampaolo/psutil/archive/refs/tags/release-$PSUTIL_VER.tar.gz"
# sha256 from termux-packages/packages/python-psutil/build.sh
echo "38f406bf21acc67e45f414b7980463b2e6e6270ba3616ffd41995d997078cbe6  $TMPDIR/psutil.tar.gz" \
  | sha256sum -c -
tar -xzf "$TMPDIR/psutil.tar.gz" -C "$PSUTIL_DIR" --strip-components=1
curl -fsSL "https://raw.githubusercontent.com/termux/termux-packages/$PSUTIL_PATCH_COMMIT/packages/python-psutil/android.patch" \
  -o "$TMPDIR/android.patch"
# hard fail (no `|| true`): an unapplied patch means the platform refusal
# resurfaces later as a cryptic build error.
patch -d "$PSUTIL_DIR" -p1 -i "$TMPDIR/android.patch"
pip wheel --no-deps "$PSUTIL_DIR" -w "$TMPDIR/psutil-wheel"

# uvloop vendors libuv and builds it with autotools ./configure. Same
# /bin/sh problem as above, but exporting CONFIG_SHELL is not enough: the
# failing exec is `['./configure', ...]`, launched directly by setup.py, so
# the shebang is resolved by the kernel. Patch setup.py to invoke the
# interpreter explicitly (validated on-device against this exact sdist).
UVLOOP_PIN="$(grep -hoiE '^uvloop==[0-9][^;[:space:]]*' "$BUILD_ROOT/requirements.txt" "$BUILD_ROOT/constraints-termux.txt" 2>/dev/null | head -1 | cut -d= -f3 || true)"
[ -n "$UVLOOP_PIN" ] || { echo "error: no uvloop== pin in requirements.txt/constraints-termux.txt" >&2; exit 1; }
echo "→ vendored uvloop $UVLOOP_PIN"
UVLOOP_SRC="$TMPDIR/uvloop-src"
mkdir -p "$UVLOOP_SRC"
pip download --no-deps --no-binary :all: "uvloop==$UVLOOP_PIN" -d "$UVLOOP_SRC"
tar -xzf "$UVLOOP_SRC"/uvloop-*.tar.gz -C "$UVLOOP_SRC" --strip-components=1
"$PYBIN" - "$UVLOOP_SRC/setup.py" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
n = s.count("cmd = ['./configure'")
assert n == 2, f"expected 2 configure sites, found {n}"
s = s.replace("cmd = ['./configure'",
              "cmd = [os.environ.get('CONFIG_SHELL', '/bin/sh'), './configure'")
open(p, "w").write(s)
print(f"uvloop setup.py patched ({n} sites)")
EOF
pip wheel --no-deps "$UVLOOP_SRC" -w "$TMPDIR/uvloop-wheel"

# Resolve the full `.[termux]` graph WITHOUT building anything (dry-run +
# install report), drop hermes-agent itself (wheel guard, installed from
# git on-device), then wheel exactly that pinned set. The second pass hits
# pip's wheel cache for everything resolved above, so native deps compile
# once.
"$PYBIN" -m pip install --dry-run --report "$TMPDIR/report.json" \
  "$BUILD_ROOT[termux]" \
  -c "$BUILD_ROOT/constraints-termux.txt" \
  -f "$TMPDIR/psutil-wheel" -f "$TMPDIR/uvloop-wheel"
"$PYBIN" - "$TMPDIR/report.json" "$TMPDIR/deps.txt" <<'EOF'
import json, sys
rep = json.load(open(sys.argv[1]))
names = []
for item in rep["install"]:
    md = item["metadata"]
    name, ver = md["name"], md["version"]
    if name.lower().replace("-", "_") == "hermes_agent":
        continue
    names.append(f"{name}=={ver}")
assert names, "empty dependency set — resolver found nothing?"
open(sys.argv[2], "w").write("\n".join(names) + "\n")
print(f"deps (minus hermes-agent): {len(names)}")
EOF
pip wheel -r "$TMPDIR/deps.txt" \
  -c "$BUILD_ROOT/constraints-termux.txt" \
  -f "$TMPDIR/psutil-wheel" -f "$TMPDIR/uvloop-wheel" \
  -w "$WHEELS"

# the patched wheels are inputs, not outputs — copy them into the bundle.
cp "$TMPDIR"/psutil-wheel/*.whl "$TMPDIR"/uvloop-wheel/*.whl "$WHEELS"/

# hard check: every resolved dep must have a wheel in the bundle.
missing=0
while IFS= read -r req; do
  [ -n "$req" ] || continue
  norm="$(printf '%s' "${req%%==*}" | tr '[:upper:]' '[:lower:]' | sed 's/[-_.][-_ .]*/_/g; s/[-_.]/_/g')"
  if ! ls "$WHEELS" | grep -qi "^${norm}-"; then
    echo "MISSING wheel for $req" >&2
    missing=1
  fi
done < "$TMPDIR/deps.txt"
[ "$missing" = 0 ] || { echo "error: bundle incomplete" >&2; exit 1; }
echo "→ bundle complete: $(ls "$WHEELS"/*.whl | wc -l) wheels"

cp "$TMPDIR/deps.txt" "$WHEELS/pins.txt"
{
  echo "HERMES_VERSION=$HERMES_VERSION"
  echo "PYTHON_TAG=$PYTAG"
} > "$WHEELS/META.txt"
tar -czf "/out/$BUNDLE.tar.gz" -C "$TMPDIR" "$BUNDLE"
( cd /out && sha256sum "$BUNDLE.tar.gz" > "$BUNDLE.tar.gz.sha256" )
ls -la /out/
echo "built: $BUNDLE.tar.gz ($(du -h "/out/$BUNDLE.tar.gz" | cut -f1))"
