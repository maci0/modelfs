# modelfs

Single Zig binary: a FUSE mount at `/models` backed by a local NVMe piece
cache, peer-to-peer piece transfers over plaintext HTTP with one shared PSK,
and an NFS origin as the write authority. Linux only. Global rules apply;
this file holds what is specific to this tree.

## Layout

| Path | Contents |
|---|---|
| `src/*.zig` | The daemon. Tests live beside the code they cover; `root.zig` aggregates them into the test binary |
| `src/c.h`, `src/c.zig` | Sole C-header door (libfuse3 + libc types). `build.zig` translates `c.h` once; import via `c.zig` / `sys.c`, never `@cImport` |
| `scripts/` | Gates and harnesses. `lib.sh` is sourced by every shell script for `ROOT_DIR`, `SCRIPTS_DIR`, `SCRATCH_DIR` |
| `docs/` | `README.md` indexes them. `architecture.md` is authoritative for shipped behavior |
| `.deps/fuse3-arm64/` | Vendored arm64 libfuse3 `.deb` files plus provenance. `build.zig` verifies both sha256 digests before compiling |

## Gates

`./scripts/check.sh` is the blocking gate: `zig fmt --check`, `zig build test`,
shellcheck (`-o` extras on `scripts/*.sh`), `test_dr_restore_drill.sh`,
`ruff check`, `ruff format --check`, mypy. CI runs that plus the aarch64
cross-compile and the reproducibility rebuild. Never loosen a rule to pass it.

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
- **Every peer input is untrusted.** Request heads, lease JSON, and encoded
  paths have fuzzed parsers; paths also pass `relOk` before origin or cache.
- **No hot-path allocation.** Piece hydration and request parsing use stack
  buffers or one reusable piece-sized buffer; allocating functions take an
  explicit `gpa`.
- **`zig fmt` decides formatting.** `minimum_zig_version` in `build.zig.zon` is
  the single source of truth for the toolchain, including in CI.
- **Docs point at symbols, not line numbers.** Line references rot within a
  commit or two; name the function and the file.
- **One rule file.** `CLAUDE.md` stays a symlink pointer to this file rather
  than a copy; edit rules here, never by replacing the pointer.
