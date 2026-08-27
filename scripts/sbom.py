#!/usr/bin/env python3
"""Emit or verify the CycloneDX inventory of declared third-party inputs.

Reads requirements-dev.txt, requirements-dev.lock.txt,
.deps/fuse3-arm64/SHA256SUMS, .github/workflows/*.yml, and build.zig.zon.
No network. Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

_PKG = re.compile(r"^([A-Za-z0-9_.-]+)==([^\\\s;]+)(?:\s*;\s*([^\\]+?))?\s*\\?\s*$")
_SHA256_HEX_LEN = 64
_HASH = re.compile(r"^--hash=sha256:([0-9a-f]{64})\s*\\?\s*$")
_ZON_VERSION = re.compile(r'\.version\s*=\s*"([^"]+)"')
_BOUND = re.compile(r"^([A-Za-z0-9_.-]+)\s*(?:===|==|!=|<=|>=|~=|<|>)")
_PEP503_PUNCT = re.compile(r"[-_.]+")
_ACTION = re.compile(
    r"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)"
    r"@([0-9a-f]{40}|[0-9a-f]{64})$"
)
_LOCK_REL = "requirements-dev.lock.txt"
_BOUNDS_REL = "requirements-dev.txt"

# SPDX for every PyPI and deb name this inventory emits. A new lock package
# or vendored .deb without an entry fails generation instead of shipping an
# unlicensed component. PyPI ids are License-Expression from the pinned
# wheel METADATA (pathspec: the Trove classifier; it has no License-Expression).
# Deb ids follow .deps/fuse3-arm64/NOTICE and copyright.
_SPDX: dict[str, str] = {
    "ast-serialize": "MIT",
    "librt": "MIT",
    "mypy": "MIT",
    "mypy-extensions": "MIT",
    "pathspec": "MPL-2.0",
    "ruff": "MIT",
    "typing-extensions": "PSF-2.0",
    "libfuse3-3": "LGPL-2.1-or-later",
    "libfuse3-dev": "GPL-2.0-only AND LGPL-2.1-or-later",
}


@dataclass(slots=True)
class LockedPackage:
    name: str
    version: str
    hashes: list[str] = field(default_factory=list)


@dataclass(slots=True)
class PinnedAction:
    name: str
    digest: str


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


def _pep503(name: str) -> str:
    return _PEP503_PUNCT.sub("-", name).lower()


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
                sys.exit(f"hash line before any package in {_LOCK_REL}")
            current.hashes.append(hashed.group(1))
            continue
        sys.exit(f"unrecognized lock line: {line}")
    return packages


def parse_bounds(text: str) -> list[str]:
    names: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        bound = _BOUND.match(line)
        if bound is None:
            sys.exit(f"unrecognized bounds line: {line}")
        names.append(bound.group(1))
    if not names:
        sys.exit(f"{_BOUNDS_REL} lists no packages")
    return names


def require_bounds_locked(bounds: list[str], packages: list[LockedPackage]) -> None:
    if not packages:
        sys.exit(f"{_LOCK_REL} lists no packages")
    locked = {_pep503(pkg.name) for pkg in packages}
    for name in bounds:
        if _pep503(name) not in locked:
            sys.exit(f"{name} is in {_BOUNDS_REL} but missing from the lock")


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


def parse_actions(text: str, source: str) -> list[PinnedAction]:
    """Every `uses:` in a workflow file; a moving tag is a hard error."""
    found: list[PinnedAction] = []
    seen: set[str] = set()
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- "):
            stripped = stripped[2:].lstrip()
        if not stripped.startswith("uses:"):
            continue
        spec = stripped.removeprefix("uses:").strip().split("#", 1)[0].strip()
        if spec.startswith("./"):
            continue
        action = _ACTION.match(spec)
        if action is None:
            sys.exit(
                f"{source}: unpinned or unsupported uses: {spec!r} "
                "(need owner/repo@<40- or 64-char commit sha>)"
            )
        name, digest = action.group(1), action.group(2)
        key = f"{name}@{digest}"
        if key in seen:
            continue
        seen.add(key)
        found.append(PinnedAction(name=name, digest=digest))
    return found


def load_actions(root: Path) -> list[PinnedAction]:
    wf_dir = root / ".github" / "workflows"
    if not wf_dir.is_dir():
        sys.exit("missing .github/workflows")
    files = sorted(wf_dir.glob("*.yml")) + sorted(wf_dir.glob("*.yaml"))
    if not files:
        sys.exit("no GitHub Actions workflow files")
    actions: list[PinnedAction] = []
    seen: set[str] = set()
    for path in files:
        for action in parse_actions(path.read_text(encoding="utf-8"), path.as_posix()):
            key = f"{action.name}@{action.digest}"
            if key in seen:
                continue
            seen.add(key)
            actions.append(action)
    if not actions:
        sys.exit("no GitHub Actions uses: pins in .github/workflows")
    return actions


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


def github_purl(name: str, digest: str) -> str:
    parts = name.split("/")
    owner, repo, *rest = parts
    purl = f"pkg:github/{owner}/{repo}@{digest}"
    if rest:
        purl += "#" + "/".join(rest)
    return purl


def hashes_cdx(digests: list[str]) -> list[dict[str, str]]:
    # One component, every wheel/sdist digest from the lock: scanners match any.
    return [{"alg": "SHA-256", "content": digest} for digest in dict.fromkeys(digests)]


def licenses_cdx(name: str, *, required: bool) -> list[dict[str, object]]:
    spdx = _SPDX.get(name)
    if spdx is None:
        if required:
            sys.exit(
                f"{name} has no SPDX entry; add it to _SPDX in scripts/sbom.py "
                "(PyPI: License-Expression on the pinned wheel METADATA)"
            )
        return []
    if " " in spdx:
        return [{"expression": spdx}]
    return [{"license": {"id": spdx}}]


def build_bom(root: Path) -> dict[str, object]:
    version = zon_version((root / "build.zig.zon").read_text(encoding="utf-8"))
    packages = parse_lock((root / _LOCK_REL).read_text(encoding="utf-8"))
    require_bounds_locked(
        parse_bounds((root / _BOUNDS_REL).read_text(encoding="utf-8")),
        packages,
    )
    debs = parse_sha256sums(
        (root / ".deps" / "fuse3-arm64" / "SHA256SUMS").read_text(encoding="utf-8")
    )
    actions = load_actions(root)
    components: list[dict[str, object]] = []
    for pkg in packages:
        if not pkg.hashes:
            sys.exit(f"{pkg.name}=={pkg.version} has no sha256 in the lock")
        licenses = licenses_cdx(pkg.name, required=True)
        components.append(
            {
                "type": "library",
                "name": pkg.name,
                "version": pkg.version,
                "purl": f"pkg:pypi/{pkg.name.lower()}@{pkg.version}",
                "hashes": hashes_cdx(pkg.hashes),
                "licenses": licenses,
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
                "licenses": licenses_cdx(name, required=True),
                "scope": "required",
            }
        )
    for action in actions:
        entry: dict[str, object] = {
            "type": "library",
            "name": action.name,
            "version": action.digest,
            "purl": github_purl(action.name, action.digest),
            "scope": "excluded",
        }
        licenses = licenses_cdx(action.name, required=False)
        if licenses:
            entry["licenses"] = licenses
        components.append(entry)
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


def _must_exit(thunk: Callable[[], object], needle: str) -> None:
    try:
        thunk()
    except SystemExit as exc:
        text = str(exc)
        if needle not in text:
            sys.exit(f"self-test failed: {needle!r} not in {text!r}")
        return
    sys.exit(f"self-test failed: {needle!r} did not SystemExit")


def _self_test_lock() -> None:
    pkgs = parse_lock(
        "foo==1.2.3 \\\n    --hash=sha256:" + ("a" * _SHA256_HEX_LEN) + "\n    # via bar\n"
    )
    if [p.name for p in pkgs] != ["foo"] or pkgs[0].version != "1.2.3" or len(pkgs[0].hashes) != 1:
        sys.exit("self-test failed: parse_lock dropped a hashed pin")
    marked = parse_lock(
        "librt==0.15.0 ; platform_python_implementation != 'PyPy' \\\n"
        "    --hash=sha256:" + ("b" * _SHA256_HEX_LEN) + "\n"
    )
    if marked[0].name != "librt":
        sys.exit("self-test failed: parse_lock dropped an environment marker")
    _must_exit(
        lambda: parse_lock("foo @ https://example.invalid/foo.whl\n"), "unrecognized lock line"
    )
    _must_exit(
        lambda: parse_lock("--hash=sha256:" + ("c" * _SHA256_HEX_LEN) + "\n"), "hash line before"
    )
    _must_exit(
        lambda: parse_lock("foo==1.0\n    --hash=sha512:" + ("d" * 128) + "\n"),
        "unrecognized lock line",
    )


def _self_test_bounds() -> None:
    names = parse_bounds("# comment\nmypy>=2.1,<3\nruff>=0.16,<0.17\n")
    if names != ["mypy", "ruff"]:
        sys.exit(f"self-test failed: parse_bounds got {names}")
    _must_exit(lambda: parse_bounds("# none\n"), "lists no packages")
    _must_exit(lambda: parse_bounds("not-a-requirement\n"), "unrecognized bounds line")
    pkg = LockedPackage(name="mypy", version="2.3.1", hashes=["ab"])
    _must_exit(lambda: require_bounds_locked(["mypy", "ruff"], [pkg]), "missing from the lock")
    _must_exit(lambda: require_bounds_locked(["mypy"], []), "lists no packages")
    require_bounds_locked(["Mypy"], [pkg])


def _self_test_actions() -> None:
    sha = "f" * 40
    got = parse_actions(
        f"      - uses: actions/checkout@{sha} # v5\n"
        f"      - uses: actions/checkout@{sha} # duplicate\n"
        "      # uses: ignored/comment@v1\n",
        "ci.yml",
    )
    if len(got) != 1 or got[0].name != "actions/checkout" or got[0].digest != sha:
        sys.exit("self-test failed: parse_actions pin/dedup")
    _must_exit(
        lambda: parse_actions("      - uses: actions/checkout@v5\n", "ci.yml"),
        "unpinned or unsupported uses:",
    )
    _must_exit(
        lambda: parse_actions("      - uses: docker://ubuntu:24.04\n", "ci.yml"),
        "unpinned or unsupported uses:",
    )
    _must_exit(
        lambda: parse_actions("      - uses:\n          actions/checkout@v5\n", "ci.yml"),
        "unpinned or unsupported uses:",
    )
    local = parse_actions("      - uses: ./local-action\n", "ci.yml")
    if local:
        sys.exit("self-test failed: in-tree uses: ./ should be skipped")
    purl = github_purl("actions/checkout", sha)
    if purl != f"pkg:github/actions/checkout@{sha}":
        sys.exit(f"self-test failed: github_purl {purl}")


def _self_test_spdx() -> None:
    mit = licenses_cdx("mypy", required=True)
    if mit != [{"license": {"id": "MIT"}}]:
        sys.exit(f"self-test failed: mypy SPDX {mit}")
    mixed = licenses_cdx("libfuse3-dev", required=True)
    if mixed != [{"expression": "GPL-2.0-only AND LGPL-2.1-or-later"}]:
        sys.exit(f"self-test failed: libfuse3-dev SPDX {mixed}")
    if licenses_cdx("actions/checkout", required=False) != []:
        sys.exit("self-test failed: unknown action SPDX should be omitted")
    _must_exit(lambda: licenses_cdx("not-a-real-package", required=True), "has no SPDX entry")


def _self_test_repo(root: Path) -> None:
    packages = parse_lock((root / _LOCK_REL).read_text(encoding="utf-8"))
    names = {pkg.name for pkg in packages}
    for required in ("mypy", "ruff"):
        if required not in names:
            sys.exit(f"self-test failed: lock missing {required}")
    for pkg in packages:
        if pkg.name not in _SPDX:
            sys.exit(f"self-test failed: {_LOCK_REL} package {pkg.name} has no _SPDX entry")
    actions = load_actions(root)
    wanted = {"actions/checkout", "mlugg/setup-zig", "astral-sh/setup-uv"}
    got = {action.name for action in actions}
    missing = wanted - got
    if missing:
        sys.exit(f"self-test failed: workflow missing uses: {sorted(missing)}")


def self_test(root: Path) -> None:
    _self_test_lock()
    _self_test_bounds()
    _self_test_actions()
    _self_test_spdx()
    _self_test_repo(root)
    print("ok: sbom self-test")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Generate or verify sbom.cdx.json from the in-tree lock, SHA256SUMS, and CI workflows."
        )
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
        help="exit 1 if sbom.cdx.json does not match the lock, SHA256SUMS, and workflows",
    )
    mode.add_argument(
        "--self-test",
        action="store_true",
        help="run parser tests (lock, bounds, workflow pins, SPDX); no file write",
    )
    args = parser.parse_args(argv[1:])
    root = project_root()
    if args.self_test:
        self_test(root)
        return 0
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
    print(f"ok: {path} matches lock, SHA256SUMS, and workflows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
