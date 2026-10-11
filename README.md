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
  survive, in which case it parks a `WATCH_PAUSED` variable and stops
  watching until the workflow is re-run with `force=true`.
- `install.sh` fetches the matching bundle, verifies the sha256, creates
  `~/.hermes/venv`, and installs `hermes-agent[termux]` with
  `--find-links <bundle>` so resolution never touches a compiler.

Fork-style companion to [opencode-bionic](https://github.com/bd-loser/opencode-bionic);
same toolchain philosophy, wheels instead of ELF.
