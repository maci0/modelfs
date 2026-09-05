# Contributing

Everything here is the runnable path from a fresh clone; CI
([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs the same gate, so
what passes locally is what passes on push.

## Setup, once per clone

Every version below is pinned in a file CI also reads, so a bump updates
both at once:

| Tool | Floor | Pinned in |
|---|---|---|
| Zig | 0.16.0 | `minimum_zig_version` in [build.zig.zon](build.zig.zon) (setup-zig reads it) |
| Python | 3.12 | [.python-version](.python-version) (setup-uv reads it) |
| uv | see manifest | `[tool.uv] required-version` in [pyproject.toml](pyproject.toml) |
| ruff, mypy | exact | [requirements-dev.lock.txt](requirements-dev.lock.txt) |

Also needed from the package manager: libfuse3 headers (`libfuse3-dev` /
`fuse3-devel`) and shellcheck. Then:

```bash
uv venv .venv && uv pip install --require-hashes -r requirements-dev.lock.txt
```

If uv cannot find an interpreter, run `uv python install 3.12` first.
`scripts/check.sh` puts `.venv/bin` on PATH itself, so you never activate it,
but it refuses anything other than that lock's `python3`, `ruff`, and `mypy`:
an empty `uv venv` or the OS copies disagree with CI and fail either here or
only after push.

If `zig build` stops with "libfuse3 headers not found", install the package it
names, or point `-Dfuse-include=<dir>` at a non-default location. On
Debian/Ubuntu `./scripts/install_libfuse3_dev.sh` runs that apt install exactly
as CI does (needs passwordless `sudo -n`).

The end-to-end suites want more: `/dev/fuse` and `fusermount3` (`fuse3` /
`fuse`) for the FUSE ones, and libvirt + KVM + sudo for the 4-VM suite, which
boots an NFS server and three clients to exercise a real origin and real
network piece exchange.

`./scripts/check.sh --help` lists every contributor command and `zig build --help`
the `check`/`ci`/`fmt`/`test` steps; each script answers `--help` instead of
starting work.

## The one command that matters

```bash
./scripts/check.sh
```

Formatting, CHANGELOG headings and tag links versus `build.zig.zon`, unit tests, the
restore-drill stub suite, vendored libfuse3 digest and extract checks,
contributor-script `--help` handlers, shellcheck, `ruff check`,
`ruff format --check`, mypy, and the CycloneDX inventory: exactly what
the `check` CI job runs. The CI jobs (that gate, the native aarch64
gate, the aarch64 cross-compile, the static musl smoke build, and the
reproducibility rebuild -- the first three also as one local step):

```bash
./scripts/ci.sh
```

## Edit-test loop

```bash
zig build test --summary all           # full unit suite
zig build test -Dtest-filter=relOk     # only tests whose names contain this substring
zig build test --watch                 # rebuild and re-run on change
zig build fmt                          # apply zig fmt (check.sh only --checks)
ruff format                            # apply ruff format (check.sh only --checks)
```

Unit tests live next to the code they cover in `src/*.zig`. A new module's
tests only run once that file is imported from [src/root.zig](src/root.zig).
The filter matches test *names*, not file names: Zig collects tests from the
whole import graph, so `-Dtest-filter=store` would miss most of `store.zig`.
`zig build test` also links the shipped `modelfs` ELF and fails unless it is
a PIE with full RELRO, BIND_NOW, a non-executable stack, and no
DT_RPATH/DT_RUNPATH.

## End-to-end suites

Not in the gate: each needs hardware or a daemon CI does not have. Every one
answers `--help` without starting work.

```bash
./scripts/run_e2e_tests.sh             # CLI and peer protocol; no FUSE mount needed
./scripts/run_cluster_e2e_9nodes.sh    # mounts 9 FUSE filesystems: needs /dev/fuse and fusermount3 (fuse3 / fuse)
./scripts/test_hot_reload.sh           # `modelfs update` on a live mount: same FUSE requirement
./scripts/run_vm_cluster_e2e.sh        # 4 VMs (NFS server + 3 clients) on libvirt/KVM: needs sudo, /dev/kvm, cloud-image-utils
./scripts/test_fault_tolerance.sh      # peer loss and lease expiry; some checks skip loudly without a live peer
```

## Build and release checks

```bash
./scripts/cross_aarch64.sh             # aarch64 ReleaseFast against the vendored libfuse3
./scripts/repro_check.sh               # two ReleaseFast builds from different paths, byte-compared
./scripts/install_libfuse3_dev.sh      # the apt install CI does (needs passwordless sudo -n)
python3 scripts/run_benchmarks_and_plots.py   # live benchmarks into .scratch/benchmarks/
```

The benchmark script measures the machine it runs on and writes to gitignored
`.scratch/benchmarks/`; `--update-docs` is what regenerates
[docs/benchmarks.md](docs/benchmarks.md) and its figures, and should only be run
on representative hardware.

## NAS backup and restore scripts

These run on the NAS or the replica host, not in a clone. [docs/recovery.md](docs/recovery.md)
is the runbook they belong to.

```bash
./scripts/install_nas_backup.sh        # copy snapshot/replica/drill units (dry-run; --install writes)
./scripts/dr_restore_drill.sh          # monthly restore drill
./scripts/dr_restore_drill.sh --age-only  # fail if newest snapshot is older than 25 h
./scripts/check_drill_log.sh           # fail if the monthly drill log is missing or stale
./scripts/check_offsite.sh             # fail if the site-loss copy is missing or older than 8 days
./scripts/dr_pool_restore.sh           # pool-loss recv (dry-run; --execute pulls from the replica)
./scripts/hold_monthlies.sh            # hold monthly snapshots on the replica (syncoid ExecStartPost)
./scripts/test_dr_restore_drill.sh     # all of the above against a stub zfs; also run by check.sh
```

## PR expectations

The only blocking requirement is green CI: `./scripts/check.sh`, the
`cross-aarch64` compile job, the two `static-linux` musl builds, and the
`reproducibility` job. `./scripts/ci.sh` runs the gate, the cross-compile,
and the reproducibility rebuild locally; the native aarch64 gate and the
static smoke build run only on GitHub's runners. There is no sign-off gate.

**Behavior changes belong in [CHANGELOG.md](CHANGELOG.md)**, as a dated `###`
section under `[Unreleased]`. Adding one is not itself gated, but the file's
shape is: `## [Unreleased]` first, then dated semver versions in strictly
descending order with one matching `build.zig.zon`, each with a `[name]:`
footer link, and `v<version>` named in README.md, SECURITY.md, and
docs/threat-model.md. `##` is reserved for those two forms, so history that
shipped in a version nests as `###` under it: a sibling `## [Name] - date`
reads as a release.

**Dependency changes carry inventory work.** [sbom.cdx.json](sbom.cdx.json) is
the CycloneDX record and `python3 scripts/sbom.py --check` holds the tree to it:

* A [requirements-dev.txt](requirements-dev.txt) edit must be reflected in the
  hash-pinned lock (regeneration command is in the lock's header) and in the
  SBOM (`python3 scripts/sbom.py --write`). A new package also needs its SPDX
  id in `_SPDX` in `scripts/sbom.py`, taken from the wheel's
  `License-Expression`.
* GitHub Actions in `.github/workflows` must be pinned to a 40- or 64-character
  commit SHA and listed in `_SPDX` with the LICENSE at that commit. The
  inventory records the digest as a hash and refuses a moving tag.
* Zig's `minimum_zig_version` and a refresh of the vendored arm64 libfuse3
  `.deb`s (which also regenerates `.deps/fuse3-arm64/SHA256SUMS`) go through
  the same `--write`.

## Cutting a release

`.version` in [build.zig.zon](build.zig.zon) is the single source the binary
prints: `build.zig` extracts it into `build_options`, `modelfs version`
prints it, and the "embedded version parses as semver" unit test rejects a
malformed value. README.md, SECURITY.md, docs/threat-model.md, CHANGELOG
headings, and the `v<version>` tag must name that same value;
`scripts/check.sh` pins the headings, the compare/tag footer links, and
that those three docs mention `v<version>`.

Choose the next version with SemVer against the last tag. This tree is still
`0.y.z`: a change that breaks the CLI, peer HTTP, on-disk sidecar, or a
default operators already rely on is a minor bump (`0.1.0` → `0.2.0`); a
compatible feature is also a minor; a bugfix is a patch. Do not ship a
break in a patch tag.

A release is these steps, kept in sync:

1. Bump `.version` in [build.zig.zon](build.zig.zon).
2. Regroup [CHANGELOG.md](CHANGELOG.md): every entry under `[Unreleased]` is
   unreleased work (dated `###` sections sit there so they are not read as
   versions); move the sections this release covers under a heading named
   after the new version and today's date, leaving `[Unreleased]` empty at
   the top of the file. Point the `[Unreleased]` compare link at the new
   tag and add a `[x.y.z]` tag link beside it.
3. Update the current-tag sentences in [README.md](README.md),
   [SECURITY.md](SECURITY.md), and [docs/threat-model.md](docs/threat-model.md)
   so they name the new `v<version>`.
4. Tag `v<version>`, exactly matching the manifest (`v0.1.0` for
   `.version = "0.1.0"`), so a checkout can be matched to a version.
5. Confirm the built binary answers with the declared version before
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

Publishing is the tag itself: pushing `v<version>` runs the `release`
workflow (`.github/workflows/release.yml`), which builds the static
single-file binaries for `x86_64-linux-musl` and `aarch64-linux-musl`
(`scripts/build_static.sh`: vendored libfuse3 compiled in, no interpreter,
no shared libraries), refuses a tag that does not name `build.zig.zon`'s
version, and attaches the two musl static binaries, the
`aarch64-linux-gnu` spark build (from `scripts/cross_aarch64.sh`), and a
`SHA256SUMS` to a GitHub release named after the tag. Re-tagging buys nothing: the workflow fires on
tag creation, and a mismatched tag fails the build. The repository itself
stays the source of truth for package consumers (the Zig package tarball is
whatever `.paths` lists) and for anyone building from the tagged commit.
