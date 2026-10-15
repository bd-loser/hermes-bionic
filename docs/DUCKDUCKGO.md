# DuckDuckGo Search on Termux

Hermes can search the web through DuckDuckGo (the `ddgs` package), with no
API key required.

## Status

Verified on an aarch64 Termux phone with the stable `v0.22.0` bundle:

- `ddgs` 9.16.0 and `primp` 2.0.1 install from the bundle with no compiler.
- A live search through the `ddgs` package in Hermes' own venv returns real
  results. Searching through Hermes' web-search tool end to end is not yet
  verified.

## How it works on Termux

`ddgs` uses `primp`, a Rust HTTP client. Upstream `primp` enables
`hickory-resolver` with its Android system-config feature. That feature needs
an Android app context, which a Termux process does not have, so every request
panicked with `android context was not initialized`.

The bundle therefore ships a `primp` build with that one feature removed (see
`ci/patch-primp.py`).

## Trade-off: DNS resolver

With this build, DuckDuckGo lookups use **Google Public DNS**
(`8.8.8.8` / `8.8.4.4`), not the DNS servers configured on your phone.

This can fail on networks that:

- block outbound DNS to public resolvers, or
- depend on local DNS names, captive portals, or a corporate resolver.

Most mobile networks work normally.

## Troubleshooting

- `android context was not initialized`: you have a `primp` wheel older than
  the `v0.22.0` bundle. Re-run the [install command](INSTALL.md).
- Searches time out or return DNS errors: check whether your network blocks
  `8.8.8.8`. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
