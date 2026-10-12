# hermes-bionic

[Hermes Agent](https://github.com/NousResearch/hermes-agent) on Termux/Android,
installed from **CI-built wheels** — nothing compiles on your phone.

Upstream already ships a Termux install path, but a fresh install builds every
native wheel (cryptography, pydantic-core, aiohttp, ...) from Rust/C source on
the device: slow and fragile. Here, GitHub Actions (ubuntu-24.04-arm +
`termux/termux-docker:aarch64`) compiles the full `.[termux]` wheel set once
per release; `install.sh` just downloads and pip-installs them locally.

## Install (on-device)

```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/hermes-bionic/main/install.sh | bash
```

The current build and installer target CPython 3.14 (`cp314`). Upstream's
core dependencies are gated on Python 3.14; older interpreters do not
select that dependency set. The installer needs a **published release** with
a matching wheel bundle; draft releases are not available to public downloads.

## How it works

- `versions.json` pins the upstream release tag.
- `build.yml` (workflow_dispatch) clones `v<HERMES_VERSION>` inside
  termux-docker, resolves `.[termux]` against the exact pins in upstream's
  pyproject.toml (older tags still honour `-c constraints-termux.txt`), and
  publishes `hermes-wheels-<ver>-<pytag>.tar.gz` on a GitHub release.
- `watch-upstream.yml` mirrors new upstream releases into `versions.json`
  and dispatches a build — unless the last build it dispatched did not
  survive, in which case run history blocks further automatic builds.
  A successful manual build resumes watching; `force=true` allows one
  watcher run past a failed build. Running builds always block dispatch.
- `install.sh` fetches the matching bundle, verifies the sha256, creates
  `~/.hermes/venv`, and installs `hermes-agent[termux]` with
  `--find-links <bundle>` so resolution never touches a compiler.

Fork-style companion to [opencode-bionic](https://github.com/bd-loser/opencode-bionic);
same toolchain philosophy, wheels instead of ELF.

## Browser automation on Termux

Termux Chromium has been tested headless on-device. The npm `agent-browser`
installer does not ship an Android binary, so installing its Linux binary
does not solve the Bionic compatibility problem.

Our patched **agent-browser 0.38.1** is compiled for Android/Bionic in CI.
It uses Chromium from Termux's official x11 repository. No phone-side Rust
compiler, Playwright installation, glibc runner, or proot is needed.

### 1. Install the prerequisites

```bash
pkg install x11-repo
pkg update
pkg install chromium libc++ git gh
chromium-browser --version
```

These commands install the named packages and their required dependencies;
they do not run a full `pkg upgrade`. Current Chromium needs a matching
`libc++`. During testing, Chromium 155 failed with a missing
`__hash_memory` symbol until `libc++` was updated from 29 to 30.

### 2. Download and install the Android artifact

The binary is currently distributed as a GitHub Actions artifact, **not an
npm package or public release asset**. Artifact downloads require a GitHub
login and are subject to GitHub's retention period.

```bash
gh auth login
git clone https://github.com/bd-loser/hermes-bionic.git
cd hermes-bionic

# Verified build of the pinned, Android-patched source:
gh run download 38302433193 --repo bd-loser/hermes-bionic \
  --name agent-browser-0.38.1-android-arm64 --dir browser-out

# ZIP extraction may not preserve executable permissions.
chmod +x browser-out/agent-browser-android-arm64
bash browser/install.sh "$PWD/browser-out"
agent-browser --version
```

Expected version: `agent-browser 0.38.1`. The installer checks the artifact's
SHA-256, installs the native binary under `$PREFIX/libexec/hermes-bionic/`,
and places the Termux launcher at `$PREFIX/bin/agent-browser`. It replaces
an existing `agent-browser` launcher, including a broken npm symlink.

If that artifact has expired, a maintainer must run
[agent-browser-termux](https://github.com/bd-loser/hermes-bionic/actions/workflows/agent-browser.yml)
again; use the successful run's ID in the download command. Do not substitute
the upstream `linux-arm64` binary—it requires glibc.

### 3. Configure Hermes

```bash
export AGENT_BROWSER_EXECUTABLE_PATH="$PREFIX/bin/chromium-browser"
printf '%s\n' "$AGENT_BROWSER_EXECUTABLE_PATH"
```

Add or update this entry in `~/.hermes/.env`, using the **absolute path**
printed above (do not put a literal `$PREFIX` in the file):

```dotenv
AGENT_BROWSER_EXECUTABLE_PATH=/data/data/com.termux/files/usr/bin/chromium-browser
```

To select Hermes' built-in `browser_*` tools, merge these settings into the
existing `browser:` section of `~/.hermes/config.yaml`, preserving your other
settings:

```yaml
browser:
  backend: "off"
  engine: chrome
```

Here, the quoted string `"off"` disables the alternative **browser-use
backend**, not browser automation. Restart Hermes after changing its config.

### 4. Verify

```bash
# From the repository checkout; uses a separate test session:
bash browser/smoke-test.sh
```

This opens a test page, reads its title, captures an interactive snapshot,
clicks a button, and checks that its text becomes `123`. Then ask Hermes to
open a page with its browser tools and inspect or interact with it.

For unusually long home paths, Unix socket filenames can exceed Android's
limit. Set a short, private socket directory before testing:

```bash
export AGENT_BROWSER_SOCKET_DIR="$PREFIX/tmp/agent-browser-$UID"
mkdir -p "$AGENT_BROWSER_SOCKET_DIR"
chmod 700 "$AGENT_BROWSER_SOCKET_DIR"
```

The wrapper selects Termux Chromium, supplies Android launch flags, and
avoids downloading glibc Chromium. `--no-sandbox` disables Chromium's own
sandbox; this configuration is intended for the non-root Termux environment.

### Verified results and scope

- [Native Android build passed](https://github.com/bd-loser/hermes-bionic/actions/runs/38302433193).
- Removed Chromium 149, confirmed its executable was absent, and installed
  official Chromium **155.0.8059.39**, with **libc++ 30**.
- Tested in an isolated home/profile and clean environment: navigation,
  interactive snapshots, clicks, and screenshot capture passed.
- Called the installed Hermes Python browser-tool functions directly:
  readiness returned true; `browser_navigate`, `browser_click`, and
  `browser_snapshot` passed, including verifying changed button text.

This verifies the fresh browser stack on one aarch64 Termux phone. It is not
a full fresh-Termux installation test, a model-driven conversation test, or
a guarantee for every Android version/device. Existing personal browser
profiles were preserved. See [issue #1](https://github.com/bd-loser/hermes-bionic/issues/1).
