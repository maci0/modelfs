# modelfs

Single Zig binary: a FUSE mount at `/models` backed by a local NVMe piece
cache, peer-to-peer piece transfers over plaintext HTTP with one shared PSK,
and an NFS origin as the write authority. Linux only. Global rules apply;
this file holds what is specific to this tree.

## Layout

| Path | Contents |
|---|---|
| `src/*.zig` | The daemon. Tests live beside the code they cover; `root.zig` aggregates them into the test binary |
| `src/c.h`, `src/c.zig` | The only door to libfuse3 and libc. `build.zig` translates the header once into a module that `src/c.zig` re-exports; every module reaches libc only through it |
| `scripts/` | Gates and harnesses. `lib.sh` is sourced by every shell script for `ROOT_DIR`, `SCRIPTS_DIR`, `SCRATCH_DIR` |
| `docs/` | `README.md` indexes them. `architecture.md` is authoritative for shipped behavior |
| `.deps/fuse3-arm64/` | Vendored arm64 libfuse3 `.deb` files plus provenance. `build.zig` verifies both sha256 digests before compiling |

## Gates

`./scripts/check.sh` is the blocking gate: `zig fmt --check`, `zig build test`,
shellcheck with the extra option set the script names, ruff check, ruff format,
mypy. CI runs the same script plus a cross-aarch64 compile. Never loosen a
rule to pass it.

The end-to-end suites need `/dev/fuse` and a `fusermount` helper, so they run
locally rather than in CI: `run_e2e_tests.sh`, `run_cluster_e2e_9nodes.sh`,
`test_fault_tolerance.sh`. `dr_restore_drill.sh` runs on the NAS.

## Constraints

- **The PSK never reaches argv.** `--psk FILE` or `MODELFS_PSK_VALUE`; argv is
  world-readable through `/proc/<pid>/cmdline`.
- **Run artifacts go to `.scratch/`**, never `/tmp`: it is tmpfs here, and a
  piece cache written there is charged to RAM.
- **Every peer input is untrusted.** Request heads, lease JSON, and encoded
  paths pass a fuzzed parser and `relOk` before touching origin or cache.
- **No hot-path allocation.** Piece hydration and request parsing use stack
  buffers or one reusable piece-sized buffer; allocating functions take an
  explicit `gpa`.
- **`zig fmt` decides formatting.** `minimum_zig_version` in `build.zig.zon` is
  the single source of truth for the toolchain, including in CI.
- **Docs point at symbols, not line numbers.** Line references rot within a
  commit or two; name the function and the file.
