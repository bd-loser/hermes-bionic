# Architecture

Hermes Agent is Python. Termux (Android's Bionic libc) cannot build many of
its native dependencies from source on the phone, so this project builds them
once in CI and ships the results as wheels.

## Components

| Path | Role |
| --- | --- |
| `install.sh` | Phone-side installer. Picks a release, verifies it, installs from local wheels. |
| `versions.json` | Pins the upstream Hermes version and Python minor. Updated by the watcher. |
| `ci/build-on-runner.sh` | Runs on the GitHub runner; starts termux-docker. |
| `ci/build-in-container.sh` | Runs inside termux-docker; builds the wheel bundle. |
| `ci/patch-primp.py` | Termux patch for `primp` (DuckDuckGo search). |
| `ci/check-wheelhouse.py` | Confirms every pinned package has a compatible wheel. |
| `ci/watch-build-gate.sh` | Stops automatic builds after a failed build. |
| `browser/` | Native `agent-browser` install, wrapper, and smoke test. |
| `.github/workflows/build.yml` | Builds and publishes the wheel bundle. |
| `.github/workflows/watch-upstream.yml` | Watches upstream releases and dispatches builds. |
| `.github/workflows/agent-browser.yml` | Builds the Android `agent-browser` artifact. |

## Install flow

1. `install.sh` lists recent releases and selects the newest one that has a
   bundle for the phone's Python (`cp314`). Prereleases are used only when no
   stable release has one. `-exp.` experiment releases are never selected.
2. It downloads `hermes-wheels-<version>-cp314.tar.gz` and its `.sha256`.
   A missing or mismatched checksum stops the install.
3. It creates `~/.hermes/venv` and runs `pip install --no-index` against the
   bundle, using `pins.txt` (the exact resolved versions).
4. It installs `hermes-agent` in editable mode from the upstream git tag,
   without build isolation, so nothing is fetched from PyPI.
5. It runs `hermes --version` as a final check.

## Build flow

1. `watch-upstream` detects a new upstream tag and updates `versions.json`.
2. `build.yml` runs `build-in-container.sh` inside `termux/termux-docker:aarch64`
   on an ARM Ubuntu runner.
3. The build resolves the `.[termux,ddgs]` dependency graph with a dry run,
   builds each wheel from source (psutil, primp, and the rest), and splits the
   work into two parallel halves.
4. `check-wheelhouse.py` verifies names, versions, and interpreter tags.
5. The bundle is installed offline into a fresh venv and `pip check` must pass.
6. The bundle is published as a GitHub release with its checksum.

## Why some packages are patched

| Package | Problem on Termux | Fix |
| --- | --- | --- |
| `psutil` | Upstream refuses the `android` platform | Termux patch, or upstream git commit |
| `primp` | Hickory system-config needs an Android app context | Built without that feature; Google DNS is used |
| `agent-browser` | npm ships an empty Android binary; Playwright cache lookup fails on Android | Native build with an Android patch |

## Versioning

- Hermes version tags follow upstream (`0.22.0`).
- Experimental builds publish to `v<version>-exp.<run_id>` prereleases and are
  never used by the installer.

## Security model

- Bundles are verified with SHA-256 before install (fail closed).
- The phone installs only from local wheels, so an unexpected PyPI package
  cannot appear at install time.
- Build secrets never leave the GitHub runner.
