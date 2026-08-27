# Contributing

Everything here is the runnable path from a fresh clone; CI
([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs the same gate, so
what passes locally is what passes on push.

## Setup, once per clone

Requirements: Linux (x86_64 or aarch64), **Zig 0.16.0 or newer** from
https://ziglang.org/download/ (`minimum_zig_version` in
[build.zig.zon](build.zig.zon) is the floor and the version CI installs;
setup-zig reads that field so a bump updates every job), libfuse3 headers
(`libfuse3-dev` / `fuse3-devel`), shellcheck (`shellcheck` / `ShellCheck`
from the package manager), and **uv** (https://docs.astral.sh/uv/).
Python tooling is pinned and type-checked against 3.12
([.python-version](.python-version); CI reads that file into setup-uv, so
a bump updates the check job). uv itself is `[tool.uv] required-version`
in [pyproject.toml](pyproject.toml) (the field setup-uv installs from).
The 9-node cluster suite also needs the FUSE helper (`fuse3` / `fuse`,
providing `/dev/fuse` and `fusermount3`). Install the lock with uv:

```bash
uv venv .venv && uv pip install --require-hashes -r requirements-dev.lock.txt
```

`.python-version` selects 3.12; if uv cannot find an interpreter, run
`uv python install 3.12` first.

`scripts/check.sh` requires `.venv` and puts it on PATH, so you never
need to activate it. If `zig build` stops with "libfuse3 headers not found",
install the package it names (or point `-Dfuse-include=<dir>` at a
non-default location). `./scripts/check.sh --help` lists the contributor
commands; each listed script answers `--help` instead of starting work.
`zig build --help` lists the `check`/`ci`/`fmt`/`test` steps.

## The one command that matters

```bash
./scripts/check.sh
```

Formatting, CHANGELOG headings versus `build.zig.zon`, unit tests, the
restore-drill stub suite, vendored libfuse3 digest and extract checks,
shellcheck, ruff, mypy, and the CycloneDX inventory: exactly what the
`check` CI job runs. Every CI job (that gate, the
aarch64 cross-compile, and the reproducibility rebuild) as one local step:

```bash
./scripts/ci.sh
```

## Edit-test loop

```bash
zig build test --summary all           # full unit suite
zig build test -Dtest-filter=relOk     # only tests whose names contain this substring
zig build test --watch                 # rebuild and re-run on change
zig build fmt                          # apply zig fmt (check.sh only --checks)
```

Unit tests live next to the code they cover in `src/*.zig`. A new module's
tests only run once that file is imported from [src/root.zig](src/root.zig).
The filter matches test *names*, not file names: Zig collects tests from the
whole import graph, so `-Dtest-filter=store` would miss most of `store.zig`.
`zig build test` also links the shipped `modelfs` ELF and fails unless it is
a PIE with full RELRO, BIND_NOW, and a non-executable stack.

## End-to-end suites

```bash
./scripts/run_e2e_tests.sh             # CLI and peer protocol; no FUSE mount needed
./scripts/run_cluster_e2e_9nodes.sh    # mounts 9 FUSE filesystems: needs /dev/fuse and fusermount3 (fuse3 / fuse)
./scripts/test_fault_tolerance.sh      # peer loss and lease expiry; some checks skip loudly without a live peer
./scripts/test_dr_restore_drill.sh     # restore drill against stub zfs; also run by check.sh
./scripts/check_drill_log.sh           # fail if the monthly drill log is missing or stale
./scripts/install_nas_backup.sh        # copy NAS snapshot/replica/drill units (dry-run; --install writes)
```

## PR expectations

The blocking requirement is green CI: `./scripts/check.sh`, the
`cross-aarch64` compile job, and the `reproducibility` job
(`./scripts/ci.sh` runs all three). There is no sign-off gate and no
requirement that a PR add a changelog entry, but `scripts/check.sh`
requires CHANGELOG.md's `##` headings to be `[Unreleased]` or a semver
version matching build.zig.zon. Behavior changes belong in
[CHANGELOG.md](CHANGELOG.md) as a dated
`###` section under `[Unreleased]` (`## [Unreleased]` and `## [x.y.z] - date`
are the only `##` headings; a sibling `## [Name] - date` reads as a
release, so history that shipped in a version nests as `###` under it;
`scripts/check.sh` pins that against `.version` in build.zig.zon), and
changes to
[requirements-dev.txt](requirements-dev.txt) must be reflected in the
hash-pinned lock (regeneration command in the lock's header) and in
[sbom.cdx.json](sbom.cdx.json) (`python3 scripts/sbom.py --write`). A
new lock package also needs its SPDX id in `scripts/sbom.py` (`_SPDX`,
from the wheel `License-Expression`). GitHub Actions in
`.github/workflows` must be pinned to a 40- or 64-character commit SHA;
the inventory lists them and refuses a moving tag. A refresh of the
vendored arm64 libfuse3 `.deb`s must regenerate
`.deps/fuse3-arm64/SHA256SUMS` and the SBOM the same way.

## Cutting a release

`.version` in [build.zig.zon](build.zig.zon) is the single source: `build.zig`
extracts it into `build_options`, `modelfs version` prints it, and the
"embedded version parses as semver" unit test rejects a malformed value.
Nothing else carries a version, so a release is four steps that must stay in
sync:

1. Bump `.version` in [build.zig.zon](build.zig.zon).
2. Regroup [CHANGELOG.md](CHANGELOG.md): every entry under `[Unreleased]` is
   unreleased work (dated `###` sections sit there so they are not read as
   versions); move the sections this release covers under a heading named
   after the new version and today's date, leaving `[Unreleased]` empty at
   the top of the file. Point the `[Unreleased]` compare link at the new
   tag and add a `[x.y.z]` tag link beside it.
3. Tag `v<version>`, exactly matching the manifest (`v0.1.0` for
   `.version = "0.1.0"`), so a checkout can be matched to a version.
4. Confirm the built binary answers with the declared version before
   announcing:

   ```bash
   zig build -Doptimize=ReleaseFast && ./zig-out/bin/modelfs version
   ```

Release artifacts are reproducible: non-Debug builds are stripped of the debug
info that records absolute build paths, so building the same tree from a
different directory, host, locale, or timezone produces identical bytes. CI
enforces this on every PR with the `reproducibility` job; verify a release
candidate locally the same way CI does:

```bash
./scripts/repro_check.sh    # builds twice (path/TZ/locale varied), diffs the bytes
```

or by hand by building twice from two different paths and comparing
`sha256sum zig-out/bin/modelfs` output.

There is no publish step beyond the tag: consumers fetch this repository as a
Zig package (the tarball is whatever `.paths` lists) or build from the tagged
commit.
