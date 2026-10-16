# Camoufox-on-Termux audit results

## Phase 1 — patch-apply matrix (done)

Run: https://github.com/bd-loser/hermes-bionic/actions/runs/38960674762
Pins: camoufox `6f74fa06...` (Firefox 156.0.1-beta.32) · termux-packages `e462d866...`

| Layer | Result |
| --- | --- |
| Firefox 156.0.1 unpack + Camoufox additions | clean (termux-docker aarch64) |
| Camoufox patches (46) via their `scripts/patch.py` | **all 46 applied cleanly** (292 file ops) |
| Termux Firefox patches (31) grafted on top | **26 PASS / 5 FAIL** |

Same score as the vanilla-tree baseline (run 38956746841): Camoufox's patch
set adds **zero extra conflict surface** for the Bionic port.

## The 5 conflicts (all look like 156-vs-158 version drift, not blockers)

| Termux patch | Failing file / hunk | Likely fix |
| --- | --- | --- |
| 0003 configure rustflags | `build/moz.configure/rust.configure:662` hunk 2 | rebase to 156 context |
| 0012 no adaptive mutex | `memory/build/Mutex.h:53,82` | rebase 2 hunks |
| 0023 no native HTTPS DNS | `netwerk/dns/moz.build:51` hunk 1 (rest applied) | trivial rebase |
| 0028 rust-cc CFLAGS | vendored `third_party/rust/cc/src/lib.rs:4326` | match 156's vendored cc |
| 0031 webspeech-disabled build | `dom/ipc/ContentParent.cpp` hunks @153/5190/5208 (+ .rej) | largest: rebase ~3+ files |

Reject files are preserved in the run's `camofox-patch-audit` artifact
(`rejects/*.rej`, `rejects/*.apply.log`).

## Phase 2 — plan

1. Port the 5 termux patches onto the camoufox tree → `camofox/termux-patches/`
   (applied after camoufox's own 46; keep numbering).
2. Write `camofox/termux.mozconfig` = camoufox `base.mozconfig` + Termux
   requirements (no alsa, system libs paths, shmem/spawn libs, no
   pack-relative-relocs, Termux vendor/rust settings — mirroring
   termux-packages' mozconfig.cfg, adapted to camoufox branding/additions).
3. `mach configure` inside a termux-packages-style build env (needs nodejs,
   rust, cbinding deps; ~2 GB container setup). Fix configure-level fallout.
4. `mach build` with ccache persisted multi-hour; iterate.
5. Package engine + fetch/verify `version.json`/`properties.json`, then wire
   the Node side (borrow of Thr45hx MIT wiring, credited).

## Termux container lessons (görbags for future runs)

- image `/data` mount: noexec, flock() unsupported → never install/exec rustup there
- `/tmp` missing, `/workspace` read-only for the `system` user
- bind mounts must be chmod 0777 host-side; `docker -e` is unreliable → pass pins as argv
- `rustup` is not in Termux repos; phase 2 uses Termux `rust` (as termux-packages does)
- shim shebangs must use the absolute Termux bash path (no `/usr/bin/env`)
