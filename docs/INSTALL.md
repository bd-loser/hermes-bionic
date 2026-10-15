# Install Hermes Agent on Termux (Android)

One command installs [Hermes Agent](https://github.com/NousResearch/hermes-agent)
on Termux without compiling anything on your phone.

```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/hermes-bionic/main/install.sh | bash
```

## Requirements

- Android with [Termux](https://termux.dev) (install from F-Droid or GitHub,
  not the outdated Play Store build)
- aarch64 (64-bit ARM) device
- Python 3.14 (`pkg install python` installs it)
- Internet access to `github.com` and `api.github.com`

## What the installer does

1. Installs Termux prerequisites (`python`, `openssl`, `libffi`, image libraries).
2. Finds the newest release that has a prebuilt wheel bundle for your Python.
3. Downloads the bundle and **verifies its SHA-256 checksum**. A mismatch stops
   the install.
4. Creates `~/.hermes/venv` and installs every dependency from the local
   wheels, with no network package resolution.
5. Installs `hermes-agent` from its upstream git tag.
6. Checks that `hermes --version` runs.

## After installing

Set a model provider key, then start Hermes:

```bash
export OPENROUTER_API_KEY=...   # or another provider
hermes
```

Your data lives in `~/.hermes`. Back it up before reinstalling.

## Reinstall or upgrade

Run the same install command again. It replaces `~/.hermes/venv` and the
wheel bundle, and keeps your `config.yaml`, `.env`, sessions, and memories.

## Uninstall

```bash
rm -f "$PREFIX/bin/hermes" "$PREFIX/bin/hermes-agent" "$PREFIX/bin/hermes-acp"
rm -rf ~/.hermes
```

This deletes all Hermes data, including credentials. Back up `~/.hermes` first.

## Optional features

- [DuckDuckGo web search](DUCKDUCKGO.md) works out of the box.
- [Browser automation](BROWSER.md) needs one extra step.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
