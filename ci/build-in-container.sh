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
# bundle (pins.txt).
#
# Build order (each step feeds the next):
#   1. patched psutil wheel (platform refusal) → find-links dir
#   2. dry-run + install report → exact dep list (deps.txt/pins.txt);
#      it also says whether uvloop is still in the [termux] graph
#   3. patched uvloop wheel at that exact version (only if present)
#   4. `pip wheel -r deps.txt` in TWO PARALLEL halves (serial native
#      compiles are what made this job take 40+ min)
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
# hermes's requires-python allows 3.11..3.14, but every exact == pin in its
# pyproject is gated `python_version >= '3.14'`. Below 3.14 those markers do
# not apply, so the resolver comes back with NOTHING pinned — exactly the
# situation the pins were introduced to prevent. The bundle therefore has to
# be produced on 3.14, and installed on 3.14.
want_314() {
  "$1" -c 'import sys;raise SystemExit(0 if (3,14)<=sys.version_info[:2]<(3,15) else 1)' 2>/dev/null
}
pick_python() {
  # termux main ships `python` = 3.14.x; a stale image (or one pinned to an
  # older snapshot) may still carry 3.13, so refresh it and fall back the
  # same way the on-device installer does.
  local p
  if want_314 python; then printf python; return; fi
  apt update -y >/dev/null 2>&1 || true
  apt install -y python >/dev/null 2>&1 || true
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
[ "$PYBIN" != none ] || { echo "error: need CPython 3.14 — hermes' exact pins are marker-gated python_version >= '3.14', so an older interpreter resolves unpinned. Try 'apt update && apt install python'." >&2; exit 1; }
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

# Rust cdylibs built with pyo3's `extension-module` feature (cryptography's
# setuptools-rust build) deliberately do NOT link libpython — fine on glibc
# (undefined Py symbols resolve against the hosting interpreter), fatal on
# Bionic (Android's linker never resolves dlopened libs against the
# executable → "cannot locate symbol PyModule_Type" at import). Force the
# link explicitly; harmless for builds that already link it (maturin).
# Reaches isolated PEP 517 builds too (pip passes RUSTFLAGS through).
PYVER="$("$PYBIN" -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-L${PREFIX:-/data/data/com.termux/files/usr}/lib -C link-arg=-lpython$PYVER"
echo "→ RUSTFLAGS=$RUSTFLAGS"

"$PYBIN" -m venv "$HOME/benv"
# shellcheck disable=SC1091
. "$HOME/benv/bin/activate"
pip install --upgrade pip wheel

BUNDLE="hermes-wheels-${HERMES_VERSION}-${PYTAG}"
WHEELS="$TMPDIR/$BUNDLE"
mkdir -p "$WHEELS"

# psutil's setup.py refuses sys.platform=="android" on the release tags.
# Termux ships python-psutil with an android.patch for that case, so build
# the tree first and hand it to the resolver via --find-links: a local wheel
# beats PyPI's sdist, which cannot build here.
#
# Which requirement applies is NOT ours to decide. Upstream has served three
# different shapes for the same pin:
#   "psutil==7.2.2"                                                          (to 2026.09)
#   "psutil==7.2.2; sys_platform != 'android' and python_version >= '3.14'"   (marker-gated)
#   "psutil @ git+https://github.com/giampaolo/psutil.git@<sha> ; sys_platform == 'android' ..."
# A literal grep for `"psutil==X.Y.Z"` only ever matched the first one, which
# is why the build died with "could not parse psutil== pin" the day markers
# landed. Instead, read the requirement the way pip does — with markers
# evaluated against the interpreter that is about to resolve — and build
# exactly what the resolver is going to pick.
PSUTIL_REQ="$(python - "$BUILD_ROOT/pyproject.toml" <<'PYEOF'
import sys, tomllib
from pip._vendor.packaging.requirements import Requirement
from pip._vendor.packaging.markers import default_environment

project = tomllib.load(open(sys.argv[1], "rb"))["project"]
pool = list(project["dependencies"])
for extra in project.get("optional-dependencies", {}).values():
    pool.extend(extra)

env = default_environment()
for raw in pool:
    req = Requirement(raw)
    if req.name.lower() != "psutil":
        continue
    if req.marker and not req.marker.evaluate(env):
        continue
    if req.url:
        print(f"git\t{req.url}")
    else:
        print(f"pin\t{next(iter(req.specifier)).version}")
    sys.exit(0)
sys.exit(f"no psutil requirement applies to {env['sys_platform']}/py{env['python_version']}")
PYEOF
)" || { echo "error: could not read the applicable psutil pin from upstream pyproject.toml" >&2; exit 1; }
PSUTIL_KIND="${PSUTIL_REQ%%$'\t'*}"
PSUTIL_VAL="${PSUTIL_REQ#*$'\t'}"
PSUTIL_DIR="$TMPDIR/psutil-src"
if [ "$PSUTIL_KIND" = git ]; then
  # Source pin. `git clone` cannot take a revision, so mirror what pip does:
  # clone the repo, then fetch and check out the pinned commit. The wheel
  # version is whatever that tree declares, so it lines up with the version
  # the resolver gets from the same ref.
  PSUTIL_REPO="${PSUTIL_VAL#git+}"
  PSUTIL_SHA="${PSUTIL_REPO##*@}"
  PSUTIL_REPO="${PSUTIL_REPO%@*}"
  echo "→ vendored psutil from $PSUTIL_REPO @ $PSUTIL_SHA (git source pin)"
  git init -q "$PSUTIL_DIR"
  git -C "$PSUTIL_DIR" remote add origin "$PSUTIL_REPO"
  git -C "$PSUTIL_DIR" fetch -q --depth 1 origin "$PSUTIL_SHA"
  git -C "$PSUTIL_DIR" checkout -q FETCH_HEAD
  # No android.patch here: the pinned commit IS upstream's Android support
  # (#2891), which already does what the Termux patch did to the 7.2.2
  # release. Forcing the old patch on top half-conflicts with it.
else
  echo "→ vendored psutil $PSUTIL_VAL (release tarball, parsed from upstream pyproject.toml)"
  mkdir -p "$PSUTIL_DIR"
  curl -fsSL -o "$TMPDIR/psutil.tar.gz" \
    "https://github.com/giampaolo/psutil/archive/refs/tags/release-$PSUTIL_VAL.tar.gz"
  if [ "$PSUTIL_VAL" = "7.2.2" ]; then
    # sha256 from termux-packages/packages/python-psutil/build.sh
    echo "38f406bf21acc67e45f414b7980463b2e6e6270ba3616ffd41995d997078cbe6  $TMPDIR/psutil.tar.gz" \
      | sha256sum -c -
  else
    echo "WARNING: no pinned sha256 for psutil $PSUTIL_VAL — proceeding on https only" >&2
  fi
  tar -xzf "$TMPDIR/psutil.tar.gz" -C "$PSUTIL_DIR" --strip-components=1
  PSUTIL_PATCH_COMMIT="d8e0fab40f58388602048fd349cd233b3b5d0169"
  curl -fsSL "https://raw.githubusercontent.com/termux/termux-packages/$PSUTIL_PATCH_COMMIT/packages/python-psutil/android.patch" \
    -o "$TMPDIR/android.patch"
  # hard fail (no `|| true`): an unapplied patch means the platform refusal
  # resurfaces later as a cryptic build error.
  patch -d "$PSUTIL_DIR" -p1 -i "$TMPDIR/android.patch"
fi
pip wheel --no-deps "$PSUTIL_DIR" -w "$TMPDIR/psutil-wheel"

# upstream deleted constraints-termux.txt when every direct dep moved into
# pyproject.toml behind exact == pins; an unconditional -c then dies with
# "Could not open requirements file". Keep honouring it where upstream still
# ships one, and resolve from the pyproject pins otherwise.
CONSTRAINTS=()
if [ -f "$BUILD_ROOT/constraints-termux.txt" ]; then
  CONSTRAINTS=(-c "$BUILD_ROOT/constraints-termux.txt")
else
  echo "note: no constraints-termux.txt at this ref — resolving from pyproject.toml's exact pins"
fi

# Resolve the full `.[termux]` graph WITHOUT building anything (dry-run +
# install report). This produces the exact pinned set. The uvloop version
# comes out of it too, but uvloop is OPTIONAL now: the [termux] profile
# deliberately omits it (libuv's ./configure cannot run on Android) and
# upstream gates the extra behind `sys_platform != 'android'`, so whether it
# appears depends on the marker environment, not on our wishes.
# `ddgs` is a separate upstream extra (DuckDuckGo search backend, pulls primp,
# a Rust package with no Termux wheel). It is not in [termux], so it must be
# requested explicitly or the bundle cannot satisfy DuckDuckGo search offline.
"$PYBIN" -m pip install --dry-run --report "$TMPDIR/report.json" \
  "$BUILD_ROOT[termux,ddgs]" \
  "${CONSTRAINTS[@]}" \
  -f "$TMPDIR/psutil-wheel"
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
UVLOOP_PIN="$(grep -i '^uvloop==' "$TMPDIR/deps.txt" | head -1 | cut -d= -f3 || true)"

# uvloop vendors libuv and builds it with autotools ./configure. Same
# /bin/sh problem as above, but exporting CONFIG_SHELL is not enough: the
# failing exec is `['./configure', ...]`, launched directly by setup.py, so
# the shebang is resolved by the kernel. Patch setup.py to invoke the
# interpreter explicitly (validated on-device against this exact sdist).
if [ -n "$UVLOOP_PIN" ]; then
  echo "→ vendoring uvloop $UVLOOP_PIN"
  UVLOOP_SRC="$TMPDIR/uvloop-src"
  mkdir -p "$UVLOOP_SRC"
  pip download --no-deps --no-binary :all: "uvloop==$UVLOOP_PIN" -d "$UVLOOP_SRC"
  tar -xzf "$UVLOOP_SRC"/uvloop-*.tar.gz -C "$UVLOOP_SRC" --strip-components=1
  "$PYBIN" - "$UVLOOP_SRC/setup.py" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
n = s.count("cmd = ['./configure'")
# 0 = upstream stopped shipping the pattern; 2 = the two sites we know of.
# Anything else means the layout changed and a blind rewrite is worse than
# a loud stop.
assert n in (0, 2), f"expected 2 configure sites, found {n}"
s = s.replace("cmd = ['./configure'",
              "cmd = [os.environ.get('CONFIG_SHELL', '/bin/sh'), './configure'")
open(p, "w").write(s)
print(f"uvloop setup.py patched ({n} sites)")
EOF
  pip wheel --no-deps "$UVLOOP_SRC" -w "$TMPDIR/uvloop-wheel"
fi

# Wheel the pinned set. Native compiles run serially inside one pip, which
# is what made this job take 40+ min — so split into halves built in
# parallel (same output dir, disjoint filenames; separate pip caches, also
# disjoint — pip's cache is not concurrent-safe). Caches live on the
# persisted /ci-cache mount when present, so unchanged deps come back
# pre-built on the next run.
if [ -d /ci-cache ]; then
  CACHE_A=/ci-cache/pip-a
  CACHE_B=/ci-cache/pip-b
else
  CACHE_A="$TMPDIR/pipecache-a"
  CACHE_B="$TMPDIR/pipecache-b"
fi
split -n l/2 -d "$TMPDIR/deps.txt" "$TMPDIR/half-"
wheel_half() {
  # $1 = half file, $2 = cache dir, $3 = tag printed before every line.
  # Streams LIVE with a tag prefix: backgrounded halves that only print
  # at the end look like a hung job in the Actions log.
  PIP_CACHE_DIR="$2" "$PYBIN" -u -m pip wheel --no-deps -r "$1" \
    "${CONSTRAINTS[@]}" \
    -f "$TMPDIR/psutil-wheel" \
    ${UVLOOP_PIN:+-f "$TMPDIR/uvloop-wheel"} \
    -w "$WHEELS" 2>&1 | sed -u "s/^/[$3] /"
}
wheel_half "$TMPDIR/half-00" "$CACHE_A" A &
PID_A=$!
wheel_half "$TMPDIR/half-01" "$CACHE_B" B &
PID_B=$!
FAIL=0
wait "$PID_A" || { echo "half A failed (see [A] lines above)"; FAIL=1; }
wait "$PID_B" || { echo "half B failed (see [B] lines above)"; FAIL=1; }
[ "$FAIL" = 0 ] || { echo "error: wheel build failed" >&2; exit 1; }
echo "→ both halves done"

# the patched wheels are inputs, not outputs — copy them into the bundle.
cp "$TMPDIR"/psutil-wheel/*.whl "$WHEELS"/
[ -n "$UVLOOP_PIN" ] && cp "$TMPDIR"/uvloop-wheel/*.whl "$WHEELS"/

# Check normalized distribution names, exact versions, and interpreter tags.
"$PYBIN" /workspace/ci/check-wheelhouse.py "$TMPDIR/deps.txt" "$WHEELS"
# Prove the frozen graph installs offline in a fresh environment before release.
"$PYBIN" -m venv "$TMPDIR/verify-venv"
"$TMPDIR/verify-venv/bin/python" -m pip install --no-index \
  --find-links "$WHEELS" -r "$TMPDIR/deps.txt"
"$TMPDIR/verify-venv/bin/python" -m pip check
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
