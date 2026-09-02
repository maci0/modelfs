# modelfs

Single Zig binary: a FUSE mount at `/models` backed by a local NVMe piece
cache, peer-to-peer piece transfers over plaintext HTTP with one shared PSK,
and an NFS origin as the write authority. Linux only.

## Layout

| Path | Contents |
|---|---|
| `src/*.zig` | The daemon. Tests live beside the code they cover; a new file is invisible to `zig build test` until `root.zig` imports it |
| `src/c.h`, `src/c.zig` | Sole C-header door (libfuse3 + libc types). `build.zig` translates `c.h` once; import via `c.zig` / `sys.zig`, never `@cImport` |
| `scripts/` | Gates and harnesses. `lib.sh` defines `ROOT_DIR`/`SCRATCH_DIR`/`SCRIPTS_DIR`; harnesses source it |
| `docs/` | `README.md` indexes them. `architecture.md` is shipped behavior; `design.md` is history |
| `.deps/fuse3-arm64/` | Vendored arm64 libfuse3 `.deb` files, `SHA256SUMS`, NOTICE, and copyright. `build.zig` and `scripts/extract_fuse3_arm64.sh` verify the digests; extract writes under `.scratch/fuse3-arm64/`; `check.sh` checks them too |

## Gates

`./scripts/check.sh` is the blocking gate: `zig fmt --check`, CHANGELOG `##`
headings (`[Unreleased]` first, dated semver matching `build.zig.zon`,
`[name]:` footer links, and current-tag sentences in README/SECURITY.md/
THREAT_MODEL.md; dated notes are `###`), `zig build test`, shellcheck
(`.shellcheckrc` on every `scripts/**/*.sh`), `test_dr_restore_drill.sh`, vendored
libfuse3 digest and extract checks, contributor-script `--help` handlers
(`test_scripts_help.sh`), `ruff check`, `ruff format --check`,
`mypy`, `scripts/sbom.py --self-test`, and `scripts/sbom.py --check`.
CI runs that plus the aarch64 cross-compile and the reproducibility rebuild.
Never loosen a gate to pass it.

`run_cluster_e2e_9nodes.sh` needs `/dev/fuse` and `fusermount3`, so it runs
locally rather than in CI. `run_e2e_tests.sh` is CLI/protocol only (no FUSE).
`test_fault_tolerance.sh` needs a live peer or skips loudly.
`dr_restore_drill.sh` runs on the NAS; `test_dr_restore_drill.sh` is the CI
stand-in (stub `zfs`).

## Constraints

- **The PSK never reaches argv.** `--psk FILE` or `MODELFS_PSK_VALUE`; argv is
  world-readable through `/proc/<pid>/cmdline`.
- **Run artifacts go to `.scratch/`**, never `/tmp`: it is tmpfs here, and a
  piece cache written there is charged to RAM.
- **Harness knobs use `MF_`, never `MODELFS_`.** The daemon refuses unknown
  `MODELFS_*` as typo'd knobs.
- **Every external path is untrusted.** Request heads, lease JSON, and encoded
  paths have fuzzed parsers. FUSE handlers go through `resolveRel`; peer and
  CLI paths pass `relOk` (and `relIsCluster`) before origin or cache.
- **No hot-path allocation.** Piece hydration and request parsing use stack
  buffers or one reusable piece-sized buffer; allocating functions take an
  explicit `gpa`.
- **`zig fmt` decides formatting.** `minimum_zig_version` in `build.zig.zon` is
  the single source of truth for the toolchain, including in CI.
- **Docs point at symbols, not line numbers.** Line references rot within a
  commit or two; name the function and the file.
- **One rule file.** `CLAUDE.md` stays a symlink pointer to this file rather
  than a copy; edit rules here, never by replacing the pointer.
