# Troubleshooting

## Install

### `could not list releases (network?)`

The installer cannot reach `api.github.com`. Check your connection, then run
the install command again.

### `no release has a cp314 bundle`

No published release contains a bundle for your Python. Make sure
`python --version` reports 3.14 (`pkg install python`), then retry. If the
problem continues, open an issue with the output.

### `checksum MISMATCH` or `could not download checksum`

The installer refuses to install a bundle it cannot verify. Run the install
command again. If the mismatch repeats, open an issue: the bundle may be
corrupted or tampered with, and the install is blocked on purpose.

### `hermes installed but does not start`

Run `~/.hermes/venv/bin/hermes --version` to see the error. Include it when
you report the problem.

### `ERROR: Failed building wheel` during a manual `pip install`

Do not build packages on the phone. Use the install command, which installs
prebuilt wheels only.

## DuckDuckGo

### `android context was not initialized`

Your `primp` is older than the current bundle. Re-run the
[install command](INSTALL.md). See [DUCKDUCKGO.md](DUCKDUCKGO.md).

### Search times out or returns DNS errors

DuckDuckGo lookups use Google Public DNS. Your network may block it. See
[DUCKDUCKGO.md](DUCKDUCKGO.md#trade-off-dns-resolver).

## Browser

### `agent-browser` fails with a glibc or linker error

You installed the upstream Linux binary. Install the Android artifact from
[BROWSER.md](BROWSER.md#2-install-the-agent-browser-binary).

### `CANNOT LINK EXECUTABLE ... __hash_memory`

Chromium needs a newer `libc++`. Run `pkg install libc++` (version 30 or
later).

### `Session name ... is too long`

The socket path exceeds Android's 103-byte limit. Set `AGENT_BROWSER_SOCKET_DIR`
to a shorter path. See [BROWSER.md](BROWSER.md#4-verify).

### Chromium sandbox errors

The wrapper already passes `--no-sandbox`. Make sure you use the wrapper at
`$PREFIX/bin/agent-browser`, not a bare binary.
