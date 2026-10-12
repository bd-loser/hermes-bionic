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

Wheels are tagged per Python minor (e.g. `cp314`); pick the bundle that
matches `python --version` in Termux. Hermes pins every dependency behind
`python_version >= '3.14'`, so 3.14 is the only interpreter both the bundle
and the install target.

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

## Browser integration (issue #1 — pending native CI validation)

Termux Chromium has been tested headless on-device. The npm `agent-browser`
installer does not ship an Android binary, so installing its Linux binary
does not solve the Bionic compatibility problem.

The manual **agent-browser-termux** workflow builds pinned agent-browser
0.38.1 inside termux-docker, using its Android Rust toolchain. It uploads an
artifact rather than publishing an untested release. No phone-side compiler
installation or package upgrade is required.

After that workflow succeeds, download and extract its artifact, then:

```bash
# Only needed if Chromium is not already installed:
pkg install x11-repo
pkg install chromium

# From this repository checkout:
bash browser/install.sh /path/to/extracted-artifact
export AGENT_BROWSER_EXECUTABLE_PATH="$PREFIX/bin/chromium-browser"
bash browser/smoke-test.sh
```

Add `AGENT_BROWSER_EXECUTABLE_PATH` with its expanded absolute path to
`~/.hermes/.env` so Hermes' browser readiness check finds Chromium too.
The wrapper selects Termux Chromium, supplies Android launch flags, and
avoids downloading glibc Chromium. `--no-sandbox` disables Chromium's own
sandbox; this configuration is intended for the non-root Termux environment.

The native build and full Hermes browser-tool test must pass before issue #1
can be considered resolved. The Chromium-only smoke test is not proof that
agent-browser or Hermes integration works.
