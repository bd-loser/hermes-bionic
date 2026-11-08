#!/usr/bin/env python3
"""Relax browser-harness's exact pillow pin inside its wheel metadata.

Upstream hermes-agent pins `Pillow==13.0.0` (its own vision-tool pin) while
the equally-pinned `browser-harness==0.1.13` requires `pillow==12.3.0`.
Two exact pins on the same distribution are unresolvable for ANY installer
(pip reports ResolutionImpossible), so the bundle cannot be produced until
upstream reconciles them. This script does the minimal, visible thing:
rewrite the wheel's Requires-Dist from `pillow==12.3.0` to `pillow>=12.3.0`
and re-version the wheel to 0.1.13+termux1 so our patched copy deterministically
wins over the PyPI original.

`==0.1.13` in hermes' pyproject still matches `0.1.13+termux1`: PEP 440
ignores the local version label when the specifier has none. The patched
wheel is only ever consumed from the local find-links dir during the build;
pins.txt then freezes `browser-harness==0.1.13+termux1` and the same wheel
ships in the bundle, so on-device installs stay offline-hermetic.

usage: patch-browser-harness.py <wheel> <out-dir>
Prints the resulting wheel path. Exits 0 with the original copied when the
pin is already relaxed (upstream fixed it) or absent.
"""
import base64
import csv
import hashlib
import io
import os
import re
import sys
import zipfile

LOCAL = "termux1"
PIN_RE = re.compile(r"^Requires-Dist:\s*pillow\s*==\s*12\.3\.0\s*$", re.I | re.M)


def rewrite_record(entries, hashes):
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    for name, (sha256, size) in entries.items():
        hashes[name] = (sha256, size)
        w.writerow([name, f"sha256={sha256}" if sha256 else "", size or ""])
    return buf.getvalue().encode()


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit("usage: patch-browser-harness.py <wheel> <out-dir>")
    src, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    with zipfile.ZipFile(src) as zin:
        names = zin.namelist()
        dist_info = next(
            (n.split("/")[0] for n in names if n.split("/")[0].endswith(".dist-info")), None
        )
        if not dist_info:
            sys.exit(f"error: {src} has no .dist-info directory")
        meta_name = f"{dist_info}/METADATA"
        meta = zin.read(meta_name).decode()

        if not PIN_RE.search(meta):
            dst = os.path.join(out_dir, os.path.basename(src))
            with open(dst, "wb") as fh:
                fh.write(zin.read(src) if False else open(src, "rb").read())
            print(dst)
            print("note: pillow pin already relaxed or absent — wheel used as-is", file=sys.stderr)
            return 0

        version_m = re.search(r"^Version:\s*(\S+)$", meta, re.M)
        if not version_m:
            sys.exit(f"error: {meta_name} has no Version: line")
        base_version = version_m.group(1)
        new_version = f"{base_version}+{LOCAL}"
        new_dist_info = dist_info.replace(base_version, new_version)

        meta = meta.replace(
            "Requires-Dist: pillow==12.3.0",
            "Requires-Dist: pillow>=12.3.0",
            1,
        )
        meta = re.sub(r"^Version:\s*\S+$", f"Version: {new_version}", meta, count=1, flags=re.M)
        # Notice for anyone inspecting the wheel on-device later.
        meta += "\n# Patched by hermes-bionic CI: pillow==12.3.0 -> >=12.3.0\n"

        files = {}
        for n in names:
            if n.endswith("/"):
                continue
            files[n] = zin.read(n)

    # Rename every record under the old dist-info dir, then rewrite METADATA.
    renamed = {}
    for n, data in files.items():
        key = n.replace(dist_info + "/", new_dist_info + "/", 1)
        renamed[key] = data
    renamed[f"{new_dist_info}/METADATA"] = meta.encode()

    # Recompute the whole RECORD (hashes must match the final content).
    record_name = f"{new_dist_info}/RECORD"
    renamed[record_name] = b""
    entries = {n: (None, None) for n in renamed}
    for n in list(renamed):
        if n == record_name:
            continue
        data = renamed[n]
        entries[n] = (base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip("="), len(data))
    renamed[record_name] = rewrite_record(entries, {})

    wheel_name = os.path.basename(src)
    wheel_name = re.sub(r"^(?P<n>[^-]+)-(?P<v>[^-]+)-", lambda m: f"{m.group('n')}-{new_version}-", wheel_name, count=1)
    dst = os.path.join(out_dir, wheel_name)
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for n, data in renamed.items():
            zout.writestr(n, data)

    print(dst)
    print(f"patched: {base_version} -> {new_version} (pillow pin relaxed)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
