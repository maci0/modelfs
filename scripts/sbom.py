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
from typing import TYPE_CHECKING, override

if TYPE_CHECKING:
    from collections.abc import Callable

_PKG = re.compile(r"^([A-Za-z0-9_.-]+)==([^\\\s;]+)(?:\s*;\s*([^\\]+?))?\s*\\?\s*$")
_SHA1_HEX_LEN = 40
_SHA256_HEX_LEN = 64
_HASH = re.compile(r"^--hash=sha256:([0-9a-f]{64})\s*\\?\s*$")
_HEX64 = re.compile(r"[0-9a-f]{64}")
# Line-anchored, same as scripts/check.sh. An unanchored `\.version` also
# matches `.minimum_zig_version` (it ends in `.version`).
_ZON_STRING = re.compile(r'^\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)"', re.MULTILINE)
_BOUND = re.compile(r"^([A-Za-z0-9_.-]+)\s*(?:===|==|!=|<=|>=|~=|<|>)")
_EXACT = re.compile(r"^([A-Za-z0-9_.-]+)==([^\\\s,;]+)$")
_PEP503_PUNCT = re.compile(r"[-_.]+")
_ACTION = re.compile(
    r"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)"
    r"@([0-9a-f]{40}|[0-9a-f]{64})$"
)
_LOCK_REL = "requirements-dev.lock.txt"
_BOUNDS_REL = "requirements-dev.txt"

# SPDX for every PyPI, deb, GitHub Action, and toolchain name this inventory
# emits. A new lock package, vendored .deb, or uses: pin without an entry
# fails generation instead of shipping an unlicensed component. PyPI ids are
# License-Expression from the pinned wheel METADATA (pathspec: the Trove
# classifier; it has no License-Expression). Deb ids follow
# .deps/fuse3-arm64/NOTICE and copyright. Action ids are LICENSE at the
# pinned commit. zig is MIT (ziglang/zig).
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
    "actions/checkout": "MIT",
    "actions/download-artifact": "MIT",
    "actions/upload-artifact": "MIT",
    "astral-sh/setup-uv": "MIT",
    "mlugg/setup-zig": "MIT",
    "zig": "MIT",
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


def zon_string(text: str, field: str) -> str:
    """Quoted string field in build.zig.zon, matched as a whole identifier."""
    for match in _ZON_STRING.finditer(text):
        if match.group(1) == field:
            return match.group(2)
    sys.exit(f"no .{field} in build.zig.zon")


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


def require_exact_pins(text: str, packages: list[LockedPackage]) -> None:
    """Bounds file must be name==version and match the lock, not a range."""
    if not packages:
        sys.exit(f"{_LOCK_REL} lists no packages")
    locked = {_pep503(pkg.name): pkg.version for pkg in packages}
    saw = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        saw = True
        exact = _EXACT.match(line)
        if exact is None:
            sys.exit(f"{_BOUNDS_REL} must pin exactly (name==version), not {line!r}")
        name, ver = exact.group(1), exact.group(2)
        got = locked.get(_pep503(name))
        if got is None:
            sys.exit(f"{name} is in {_BOUNDS_REL} but missing from the lock")
        if got != ver:
            sys.exit(f"{name}=={ver} in {_BOUNDS_REL} does not match lock {got}")
    if not saw:
        sys.exit(f"{_BOUNDS_REL} lists no packages")


def parse_sha256sums(text: str) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    seen: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        digest, sep, name = line.partition("  ")
        if sep == "" or _HEX64.fullmatch(digest) is None or "/" in name or name in {".", ".."}:
            sys.exit(f"malformed SHA256SUMS line: {line}")
        if name in seen:
            sys.exit(f"duplicate SHA256SUMS entry: {name}")
        seen.add(name)
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


def commit_hashes(digest: str) -> list[dict[str, str]]:
    """GitHub Actions pins: 40-char SHA-1 or 64-char SHA-256 commit id."""
    if len(digest) == _SHA256_HEX_LEN:
        return [{"alg": "SHA-256", "content": digest}]
    if len(digest) == _SHA1_HEX_LEN:
        return [{"alg": "SHA-1", "content": digest}]
    sys.exit(f"unsupported commit digest length {len(digest)}")


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
    zon_text = (root / "build.zig.zon").read_text(encoding="utf-8")
    version = zon_string(zon_text, "version")
    min_zig = zon_string(zon_text, "minimum_zig_version")
    packages = parse_lock((root / _LOCK_REL).read_text(encoding="utf-8"))
    bounds_text = (root / _BOUNDS_REL).read_text(encoding="utf-8")
    require_bounds_locked(parse_bounds(bounds_text), packages)
    require_exact_pins(bounds_text, packages)
    deb_dir = root / ".deps" / "fuse3-arm64"
    debs = parse_sha256sums((deb_dir / "SHA256SUMS").read_text(encoding="utf-8"))
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
        if not filename.endswith(".deb"):
            sys.exit(f"SHA256SUMS entry {filename} is not a .deb")
        if not (deb_dir / filename).is_file():
            sys.exit(f"{filename} is listed in SHA256SUMS but missing")
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
    components.extend(
        {
            "type": "library",
            "name": action.name,
            "version": action.digest,
            "purl": github_purl(action.name, action.digest),
            "hashes": commit_hashes(action.digest),
            "licenses": licenses_cdx(action.name, required=True),
            "scope": "excluded",
        }
        for action in actions
    )
    components.append(
        {
            "type": "application",
            "name": "zig",
            "version": min_zig,
            "purl": f"pkg:github/ziglang/zig@{min_zig}",
            "licenses": licenses_cdx("zig", required=True),
            "scope": "excluded",
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
    require_exact_pins("mypy==2.3.1\n", [pkg])
    _must_exit(lambda: require_exact_pins("mypy>=2.1,<3\n", [pkg]), "must pin exactly")
    _must_exit(lambda: require_exact_pins("mypy==2.0.0\n", [pkg]), "does not match lock")
    _must_exit(
        lambda: require_exact_pins(
            "mypy==2.3.1\n",
            [LockedPackage(name="ruff", version="1", hashes=["a"])],
        ),
        "missing from the lock",
    )
    _must_exit(lambda: require_exact_pins("# none\n", [pkg]), "lists no packages")


def _self_test_zon() -> None:
    text = (
        ".{\n    .name = .modelfs,\n"
        '    .minimum_zig_version = "0.16.0",\n'
        '    .version = "0.1.0",\n}\n'
    )
    if zon_string(text, "version") != "0.1.0":
        sys.exit("self-test failed: zon_string confused .minimum_zig_version for .version")
    if zon_string(text, "minimum_zig_version") != "0.16.0":
        sys.exit("self-test failed: zon_string missed .minimum_zig_version")
    _must_exit(
        lambda: zon_string('.{\n    .version = "0.1.0",\n}\n', "minimum_zig_version"),
        "no .minimum_zig_version",
    )


def _self_test_sums() -> None:
    digest = "a" * _SHA256_HEX_LEN
    line = f"{digest}  libfuse3-3_1_arm64.deb\n"
    got = parse_sha256sums(f"# comment\n{line}")
    if got != [("libfuse3-3_1_arm64.deb", digest)]:
        sys.exit(f"self-test failed: parse_sha256sums {got}")
    _must_exit(
        lambda: parse_sha256sums(("A" * _SHA256_HEX_LEN) + "  foo.deb\n"),
        "malformed SHA256SUMS line",
    )
    _must_exit(lambda: parse_sha256sums(line + line), "duplicate SHA256SUMS entry")
    _must_exit(lambda: parse_sha256sums("# none\n"), "SHA256SUMS has no entries")


def _self_test_actions() -> None:
    sha = "f" * _SHA1_HEX_LEN
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
    sha1 = commit_hashes(sha)
    if sha1 != [{"alg": "SHA-1", "content": sha}]:
        sys.exit(f"self-test failed: commit_hashes sha1 {sha1}")
    sha256 = "b" * _SHA256_HEX_LEN
    hashed = commit_hashes(sha256)
    if hashed != [{"alg": "SHA-256", "content": sha256}]:
        sys.exit(f"self-test failed: commit_hashes sha256 {hashed}")
    _must_exit(lambda: commit_hashes("abc"), "unsupported commit digest length")


def _self_test_spdx() -> None:
    mit = licenses_cdx("mypy", required=True)
    if mit != [{"license": {"id": "MIT"}}]:
        sys.exit(f"self-test failed: mypy SPDX {mit}")
    mixed = licenses_cdx("libfuse3-dev", required=True)
    if mixed != [{"expression": "GPL-2.0-only AND LGPL-2.1-or-later"}]:
        sys.exit(f"self-test failed: libfuse3-dev SPDX {mixed}")
    checkout = licenses_cdx("actions/checkout", required=True)
    if checkout != [{"license": {"id": "MIT"}}]:
        sys.exit(f"self-test failed: actions/checkout SPDX {checkout}")
    if licenses_cdx("nobody/not-an-action", required=False) != []:
        sys.exit("self-test failed: unknown action SPDX should be omitted")
    _must_exit(lambda: licenses_cdx("not-a-real-package", required=True), "has no SPDX entry")
    _must_exit(lambda: licenses_cdx("nobody/not-an-action", required=True), "has no SPDX entry")


def _bom_by_name(bom: dict[str, object]) -> dict[str, dict[str, object]]:
    raw_components = bom["components"]
    if not isinstance(raw_components, list):
        sys.exit("self-test failed: BOM components is not a list")
    by_name: dict[str, dict[str, object]] = {}
    for raw in raw_components:
        if not isinstance(raw, dict):
            sys.exit("self-test failed: BOM component is not an object")
        name = raw.get("name")
        if not isinstance(name, str):
            sys.exit("self-test failed: BOM component missing name")
        by_name[name] = raw
    return by_name


def _self_test_bom_pins(root: Path, wanted: set[str]) -> None:
    by_name = _bom_by_name(build_bom(root))
    min_zig = zon_string(
        (root / "build.zig.zon").read_text(encoding="utf-8"),
        "minimum_zig_version",
    )
    zig = by_name.get("zig")
    if zig is None or zig.get("version") != min_zig:
        sys.exit("self-test failed: BOM missing zig from minimum_zig_version")
    if "licenses" not in zig:
        sys.exit("self-test failed: zig component has no licenses")
    for name in wanted:
        entry = by_name.get(name)
        if entry is None:
            sys.exit(f"self-test failed: BOM missing {name}")
        if "hashes" not in entry or "licenses" not in entry:
            sys.exit(f"self-test failed: {name} missing hashes or licenses")


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
    _self_test_bom_pins(root, wanted)


def self_test(root: Path) -> None:
    _self_test_lock()
    _self_test_bounds()
    _self_test_zon()
    _self_test_sums()
    _self_test_actions()
    _self_test_spdx()
    _self_test_repo(root)
    print("ok: sbom self-test")


class _Parser(argparse.ArgumentParser):
    """argparse's usage line, capitalized to match the shell scripts."""

    @override
    def format_usage(self) -> str:
        return super().format_usage().replace("usage:", "Usage:", 1)

    @override
    def format_help(self) -> str:
        return super().format_help().replace("usage:", "Usage:", 1)


def main(argv: list[str]) -> int:
    parser = _Parser(
        description=(
            "Generate or verify sbom.cdx.json from the in-tree lock, SHA256SUMS, and CI workflows."
        ),
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
