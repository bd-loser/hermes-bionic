# Browser Automation on Termux

Hermes can drive a real Chromium browser (navigate, read the page, click,
type, take screenshots) using a native Android build of `agent-browser`.

Nothing is compiled on the phone, and no Playwright, glibc runner, or proot
is needed.

## Status

Verified on one aarch64 Termux phone:

- Native Android build of `agent-browser` 0.38.1 succeeded in CI.
- Official Termux Chromium 155.0.8059.39 with `libc++` 30.
- Navigation, interactive snapshots, clicks, and screenshots passed in an
  isolated profile.
- Hermes' built-in browser tools (`browser_navigate`, `browser_snapshot`,
  `browser_click`) passed when called directly.

Not yet verified: a full model-driven conversation using the browser, or
other Android devices.

## 1. Install prerequisites

```bash
pkg install x11-repo
pkg update
pkg install chromium libc++ git gh
chromium-browser --version
```

These install the named packages and their dependencies. They do not run a
full `pkg upgrade`.

Chromium needs a matching `libc++`. During testing, Chromium 155 failed with a
missing `__hash_memory` symbol until `libc++` was upgraded from 29 to 30.

## 2. Install the agent-browser binary

The binary is a GitHub Actions artifact from the
[`agent-browser-termux`](https://github.com/bd-loser/hermes-bionic/actions/workflows/agent-browser.yml)
workflow. It is not on npm and not a release asset. Downloading artifacts
requires a GitHub login, and artifacts expire after a retention period.

```bash
gh auth login
git clone https://github.com/bd-loser/hermes-bionic.git
cd hermes-bionic

# Replace RUN_ID with the ID of a successful agent-browser-termux run:
gh run download RUN_ID --repo bd-loser/hermes-bionic \
  --name agent-browser-0.38.1-android-arm64 --dir browser-out

chmod +x browser-out/agent-browser-android-arm64
bash browser/install.sh "$PWD/browser-out"
agent-browser --version     # expect: agent-browser 0.38.1
```

The installer checks the artifact's SHA-256, installs the binary under
`$PREFIX/libexec/hermes-bionic/`, and creates the launcher at
`$PREFIX/bin/agent-browser`.

Do not use the upstream `linux-arm64` binary. It needs glibc and will not run
on Termux.

## 3. Configure Hermes

Add the Chromium path to `~/.hermes/.env` using the absolute path:

```dotenv
AGENT_BROWSER_EXECUTABLE_PATH=/data/data/com.termux/files/usr/bin/chromium-browser
```

Merge this into the existing `browser:` section of `~/.hermes/config.yaml`:

```yaml
browser:
  backend: "off"
  engine: chrome
```

`backend: "off"` disables the alternative browser-use backend. It does not
disable browser automation. Restart Hermes after changing the config.

## 4. Verify

```bash
bash browser/smoke-test.sh
```

The smoke test opens a test page, reads its title, takes a snapshot, clicks a
button, and checks that the button text changes.

If Unix socket paths fail because your home directory path is long, use a
short socket directory:

```bash
export AGENT_BROWSER_SOCKET_DIR="$PREFIX/tmp/agent-browser-$UID"
mkdir -p "$AGENT_BROWSER_SOCKET_DIR" && chmod 700 "$AGENT_BROWSER_SOCKET_DIR"
```

## Security note

The wrapper starts Chromium with `--no-sandbox`. Chromium's own sandbox does
not work in the non-root Termux environment. Only browse sites you trust with
this setup.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#browser).
