# Contributing

Everything here is the runnable path from a fresh clone; CI
([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs the same gate, so
what passes locally is what passes on push.

## Setup, once per clone

Requirements: Linux, **Zig 0.16.0 or newer** (`minimum_zig_version` in
[build.zig.zon](build.zig.zon) enforces this; CI builds with exactly
0.16.0), libfuse3 headers
(`libfuse3-dev` / `fuse3-devel`), shellcheck, and **uv**. Python tooling is
pinned and type-checked against 3.12 ([.python-version](.python-version));
install it with uv:

```bash
uv venv .venv && uv pip install --require-hashes -r requirements-dev.lock.txt
```

`scripts/check.sh` requires `.venv` and puts it on PATH, so you never
need to activate it. If `zig build` stops with "libfuse3 headers not found",
install the package it names (or point `-Dfuse-include=<dir>` at a
non-default location). `./scripts/check.sh --help` lists the contributor
commands; so does `zig build --help`.

## The one command that matters

```bash
./scripts/check.sh
```

Formatting, unit tests, the restore-drill stub suite, shellcheck, ruff, and
mypy: exactly what the `check` CI job runs. Every CI job (that gate, the
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

## End-to-end suites

```bash
./scripts/run_e2e_tests.sh             # CLI and peer protocol; no FUSE mount needed
./scripts/run_cluster_e2e_9nodes.sh    # mounts 9 FUSE filesystems: needs /dev/fuse and fusermount3
./scripts/test_fault_tolerance.sh      # peer loss and lease expiry; some checks skip loudly without a live peer
./scripts/test_dr_restore_drill.sh     # restore drill against stub zfs; also run by check.sh
```

## PR expectations

The blocking requirement is green CI: `./scripts/check.sh`, the
`cross-aarch64` compile job, and the `reproducibility` job
(`./scripts/ci.sh` runs all three). There are no
sign-off or changelog-entry gates,
but behavior changes belong in [CHANGELOG.md](CHANGELOG.md) as their own
dated section under `[Unreleased]` (everything outside a version heading is
unreleased work toward the next one; see Cutting a release below), and
changes to
[requirements-dev.txt](requirements-dev.txt) must be reflected in the
hash-pinned lock (regeneration command in the lock's header).

## Cutting a release

`.version` in [build.zig.zon](build.zig.zon) is the single source: `build.zig`
extracts it into `build_options`, `modelfs version` prints it, and the
"embedded version parses as semver" unit test rejects a malformed value.
Nothing else carries a version, so a release is four steps that must stay in
sync:

1. Bump `.version` in [build.zig.zon](build.zig.zon).
2. Regroup [CHANGELOG.md](CHANGELOG.md): every entry under `[Unreleased]` is
   unreleased work; move the sections this release covers under a heading
   named after the new version and today's date, leaving `[Unreleased]`
   empty at the top of the file.
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
