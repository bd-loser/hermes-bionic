"""Verify every resolved pin has a compatible wheel, including dotted names."""
import sys
from pathlib import Path

from pip._vendor.packaging.requirements import Requirement
from pip._vendor.packaging.tags import sys_tags
from pip._vendor.packaging.utils import canonicalize_name, parse_wheel_filename


def missing_wheels(pins, filenames, supported):
    wheels = [parse_wheel_filename(Path(f).name) for f in filenames]
    missing = []
    for line in pins.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        req = Requirement(line)
        if not any(
            name == canonicalize_name(req.name)
            and version in req.specifier
            and tags & supported
            for name, version, _, tags in wheels
        ):
            missing.append(line)
    return missing


if __name__ == "__main__":
    pins, directory = map(Path, sys.argv[1:])
    missing = missing_wheels(pins.read_text(), directory.glob("*.whl"), set(sys_tags()))
    for requirement in missing:
        print(f"MISSING compatible wheel for {requirement}", file=sys.stderr)
    sys.exit(bool(missing))
