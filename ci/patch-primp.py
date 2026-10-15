#!/usr/bin/env python3
"""Patch the pinned primp sdist for Termux (DuckDuckGo search via `ddgs`).

primp builds hickory-resolver with the `system-config` feature. On Android
that feature pulls ndk-context, whose read_system_conf() panics in any Termux
process ("android context was not initialized") on every request.

Termux has no Android app context, so this patch:
  1. removes `system-config` from primp's hickory-resolver dependency;
  2. makes primp's hickory resolver use hickory's explicit Google DNS config
     directly (the same fallback primp already uses when system config fails).

Trade-off (documented in README): DNS goes to Google 8.8.8.8 / 8.8.4.4, not the
device resolver. Each replacement must match exactly once, or we fail loudly.
"""
import pathlib
import sys


def replace_once(path: pathlib.Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        sys.exit(f"patch-primp: expected 1 match in {path}, found {count}")
    path.write_text(text.replace(old, new))


def main(src_dir: str) -> None:
    src = pathlib.Path(src_dir)

    replace_once(
        src / "crates/primp/Cargo.toml",
        'hickory-resolver = { version = "0.26", optional = true, features = ["tokio", "system-config"] }',
        'hickory-resolver = { version = "0.26", optional = true, features = ["tokio"] }',
    )

    replace_once(
        src / "crates/primp/src/dns/hickory.rs",
        "/// Builds a resolver from `/etc/resolv.conf` (falling back to Google DNS),\n",
        "/// Builds a resolver using Google DNS (Termux patch: system config off),\n",
    )
    replace_once(
        src / "crates/primp/src/dns/hickory.rs",
        """    let mut builder = TokioResolver::builder_tokio().unwrap_or_else(|err| {
        log::debug!(
            "hickory-dns: failed to load system DNS configuration; falling back to Google DNS: {:?}",
            err
        );
        TokioResolver::builder_with_config(
            ResolverConfig::udp_and_tcp(&GOOGLE),
            TokioRuntimeProvider::default(),
        )
    });""",
        """    // Termux/Android: system-config is compiled out (see patch-primp.py).
    let mut builder = TokioResolver::builder_with_config(
        ResolverConfig::udp_and_tcp(&GOOGLE),
        TokioRuntimeProvider::default(),
    );""",
    )
    print("patch-primp: applied (hickory system-config off, Google DNS direct)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: patch-primp.py <primp-sdist-dir>")
    main(sys.argv[1])
