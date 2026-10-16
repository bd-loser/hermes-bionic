# Camoufox on Termux (Bionic) — port workspace

Goal: a **Bionic-native** Camoufox (Firefox fork with anti-detect patches) so
Hermes' optional Camofox provider can run entirely on-device, replacing the
third-party glibc-loader approach.

## Where we are (audit summary, 2026-10-16)

| Fact | Source |
| --- | --- |
| Camoufox = vanilla Firefox **156.0.1** + 46 public patches (incl. Playwright/Juggler) + brand/additions, built with `make` | [daijro/camoufox](https://github.com/daijro/camoufox) `browser/` |
| Firefox is already built for Bionic by termux-packages (Firefox **158.0**, `x11-packages/firefox`, ~15 Termux patches + mozconfig template) | [termux-packages](https://github.com/termux/termux-packages) |
| No glibc needed: the alternative (private Debian glibc loader) is what [Thr45hx/camoufox-termux-native](https://github.com/Thr45hx/camoufox-termux-native) does today; we aim to replace that layer | see links |
| Hermes' Camofox provider needs zero changes: it only talks HTTP to `@askjo/camofox-browser` (Node side already proven on Bionic) | `tools/browser_camofox.py` upstream |

Version gap: camoufox base **156.0.1** vs Termux recipe **158.0** — same era;
conflicts are expected in `configure`/platform code only.

## Phases

1. **patch-audit.sh** (this commit): inside termux-docker — unpack Firefox
   156.0.1, apply Camoufox patches (their own `scripts/patch.py`), then apply
   the Termux Firefox patches on top, one by one. Output: per-patch pass/fail
   report + `.rej` files as a CI artifact. No compile.
2. Resolve conflicts, write `termux.mozconfig`, run `mach configure` inside
   the termux-packages build harness.
3. `mach build` in CI with ccache (multi-hour), then package + wire the Node
   side so Hermes can drive it.

## Pins

- Camoufox repo: `6f74fa06df586b8dce7a86c6d2b35a1c13b498b2` (upstream Firefox 156.0.1-beta.32)
- termux-packages (x11-packages/firefox): `e462d86688f194debff9073440b3b6b72a7a35ae`
- Reference (Node wiring, future reuse): Thr45hx hermes-camofox-termux, MIT

## Licenses

Firefox/Camoufox are MPL-2.0. Termux patches are MIT (their repo). This folder
keeps our scripts MIT-consistent with this repo and never republishes their
sources except by fetching from the pinned origins.
