#!/usr/bin/env python3
"""Emit or verify the CycloneDX inventory of declared third-party inputs.

Reads requirements-dev.lock.txt, .deps/fuse3-arm64/SHA256SUMS, and
build.zig.zon. No network. Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

_PKG = re.compile(r"^([A-Za-z0-9_.-]+)==([^\\\s;]+)(?:\s*;\s*([^\\]+?))?\s*\\?\s*$")
_SHA256_HEX_LEN = 64
_HASH = re.compile(r"^\s*--hash=sha256:([0-9a-f]{64})\s*\\?\s*$")
_ZON_VERSION = re.compile(r'\.version\s*=\s*"([^"]+)"')


@dataclass(slots=True)
class LockedPackage:
    name: str
    version: str
    hashes: list[str] = field(default_factory=list)


def project_root() -> Path:
    """Directory holding build.zig.zon, found by walking up from this file."""
    here = Path(__file__).resolve()
    for d in here.parents:
        if (d / "build.zig.zon").is_file():
            return d
    sys.exit(f"cannot find build.zig.zon above {here}")


def zon_version(text: str) -> str:
    match = _ZON_VERSION.search(text)
    if match is None:
        sys.exit("no .version in build.zig.zon")
    return match.group(1)


def parse_lock(text: str) -> list[LockedPackage]:
    packages: list[LockedPackage] = []
    current: LockedPackage | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        pkg = _PKG.match(line)
        if pkg is not None:
            current = LockedPackage(name=pkg.group(1), version=pkg.group(2))
            packages.append(current)
            continue
        hashed = _HASH.match(line)
        if hashed is not None:
            if current is None:
                sys.exit("hash line before any package in requirements-dev.lock.txt")
            current.hashes.append(hashed.group(1))
            continue
        if line.startswith("--"):
            sys.exit(f"unrecognized lock directive: {line}")
    return packages


def parse_sha256sums(text: str) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        digest, sep, name = line.partition("  ")
        if sep == "" or len(digest) != _SHA256_HEX_LEN or "/" in name or name in {".", ".."}:
            sys.exit(f"malformed SHA256SUMS line: {line}")
        entries.append((name, digest))
    if not entries:
        sys.exit("SHA256SUMS has no entries")
    return entries


def deb_purl(filename: str) -> tuple[str, str, str]:
    stem = filename.removesuffix(".deb")
    arch_at = stem.rfind("_")
    rest_at = stem.rfind("_", 0, arch_at)
    if arch_at < 0 or rest_at < 0:
        sys.exit(f"cannot parse deb filename {filename}")
    name = stem[:rest_at]
    version = stem[rest_at + 1 : arch_at]
    arch = stem[arch_at + 1 :]
    return name, version, f"pkg:deb/ubuntu/{name}@{version}?arch={arch}"


def hashes_cdx(digests: list[str]) -> list[dict[str, str]]:
    # One component, every wheel/sdist digest from the lock: scanners match any.
    return [{"alg": "SHA-256", "content": digest} for digest in dict.fromkeys(digests)]


def build_bom(root: Path) -> dict[str, object]:
    version = zon_version((root / "build.zig.zon").read_text(encoding="utf-8"))
    packages = parse_lock((root / "requirements-dev.lock.txt").read_text(encoding="utf-8"))
    debs = parse_sha256sums(
        (root / ".deps" / "fuse3-arm64" / "SHA256SUMS").read_text(encoding="utf-8")
    )
    components: list[dict[str, object]] = []
    for pkg in packages:
        if not pkg.hashes:
            sys.exit(f"{pkg.name}=={pkg.version} has no sha256 in the lock")
        components.append(
            {
                "type": "library",
                "name": pkg.name,
                "version": pkg.version,
                "purl": f"pkg:pypi/{pkg.name.lower()}@{pkg.version}",
                "hashes": hashes_cdx(pkg.hashes),
                "scope": "excluded",
            }
        )
    for filename, digest in debs:
        name, ver, purl = deb_purl(filename)
        components.append(
            {
                "type": "library",
                "name": name,
                "version": ver,
                "purl": purl,
                "hashes": hashes_cdx([digest]),
                "scope": "required",
            }
        )
    components.sort(key=lambda c: str(c["purl"]))
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "name": "modelfs",
                "version": version,
                "licenses": [{"license": {"id": "GPL-3.0-or-later"}}],
            }
        },
        "components": components,
    }


def dumps(bom: dict[str, object]) -> str:
    return json.dumps(bom, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Generate or verify sbom.cdx.json from the in-tree lock and SHA256SUMS."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--write",
        action="store_true",
        help="overwrite sbom.cdx.json at the project root",
    )
    mode.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if sbom.cdx.json does not match the lock and SHA256SUMS",
    )
    args = parser.parse_args(argv[1:])
    root = project_root()
    path = root / "sbom.cdx.json"
    text = dumps(build_bom(root))
    if args.write:
        path.write_text(text, encoding="utf-8")
        print(f"wrote {path}")
        return 0
    if not path.is_file():
        print(f"{path} is missing; generate with: python3 scripts/sbom.py --write", file=sys.stderr)
        return 1
    got = path.read_text(encoding="utf-8")
    if got != text:
        print(
            f"{path} is out of date; regenerate with: python3 scripts/sbom.py --write",
            file=sys.stderr,
        )
        return 1
    print(f"ok: {path} matches lock and SHA256SUMS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
