# Hermes Agent for Termux (Android)

**Install [Hermes Agent](https://github.com/NousResearch/hermes-agent) on
Termux without compiling.** Prebuilt, checksum-verified Python wheels for
aarch64 Android, built in CI, so your phone never runs a compiler.

```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/hermes-bionic/main/install.sh | bash
```

## Why this exists

Upstream Hermes depends on native packages (cryptography, pydantic-core,
Pillow, and more). On a phone each one compiles from source, which is slow and
often fails. This project compiles them once in CI and installs them offline.

## Features

- **One-command install** on Termux, Python 3.14, aarch64
- **Verified installs**: SHA-256 checked, and a mismatch stops the install
- **No on-device compiler** needed
- **DuckDuckGo web search** that works on Termux (`ddgs`, no API key)
- **Browser automation** with a native Android `agent-browser` and Termux Chromium

## Documentation

| Guide | What it covers |
| --- | --- |
| [Install](docs/INSTALL.md) | Requirements, install, upgrade, uninstall |
| [DuckDuckGo search](docs/DUCKDUCKGO.md) | Search on Termux and its DNS trade-off |
| [Browser automation](docs/BROWSER.md) | Chromium and `agent-browser` on Android |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Common errors and fixes |
| [Architecture](docs/ARCHITECTURE.md) | How the build and installer work |
| [Releasing](docs/RELEASING.md) | Maintainer release process |

## Status

- Stable release: `v0.22.0` (Hermes 0.22.0, Python 3.14, aarch64)
- Verified on one Termux phone: install, Hermes startup, DuckDuckGo search,
  and browser basics.
- Not yet verified: other Android devices and Android versions.

## Related

- [Hermes Agent](https://github.com/NousResearch/hermes-agent): upstream project
- [opencode-bionic](https://github.com/bd-loser/opencode-bionic): same approach for OpenCode
- **[camoufox-bionic](https://github.com/bd-loser/camoufox-termux)**: Bionic-native Camoufox (anti-fingerprint Firefox) for Termux — built natively, no glibc/proot; powers Hermes' Camofox provider

## Contributing and issues

Report problems at [issues](https://github.com/bd-loser/hermes-bionic/issues),
with your `hermes --version`, Android version, and the full error output.

## License

This repository does not yet include a license file. Hermes Agent itself is
licensed by its [upstream project](https://github.com/NousResearch/hermes-agent).
