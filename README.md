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

Wheels are tagged per Python minor (e.g. `cp313`); pick the bundle that
matches `python --version` in Termux.

## How it works

- `versions.json` pins the upstream release tag.
- `build.yml` (workflow_dispatch) clones `v<HERMES_VERSION>` inside
  termux-docker, runs `pip wheel ".[termux]" -c constraints-termux.txt`, and
  publishes `hermes-wheels-<ver>-<pytag>.tar.gz` on a GitHub release.
- `install.sh` fetches the matching bundle, verifies the sha256, creates
  `~/.hermes/venv`, and installs `hermes-agent[termux]` with
  `--find-links <bundle>` so resolution never touches a compiler.

Fork-style companion to [opencode-bionic](https://github.com/bd-loser/opencode-bionic);
same toolchain philosophy, wheels instead of ELF.
