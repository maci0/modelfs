# modelfs

Single Zig binary: a FUSE mount at `/models` backed by a local NVMe piece
cache, peer-to-peer piece transfers over plaintext HTTP with one shared PSK,
and an NFS origin as the write authority. Linux only.

## Layout

| Path | Contents |
|---|---|
| `src/*.zig` | The daemon. Tests live beside the code they cover; a new file is invisible to `zig build test` until `root.zig` imports it. `-Dtest-filter=` matches test names, not files |
| `src/c.h`, `src/c.zig` | Sole C-header door (libfuse3 + libc types). `build.zig` translates `c.h` once; import via `c.zig` / `sys.zig`, never `@cImport` |
| `scripts/` | Gates and harnesses. `lib.sh` defines `ROOT_DIR`/`SCRATCH_DIR`/`SCRIPTS_DIR`; harnesses source it |
| `docs/` | `README.md` indexes them. `architecture.md` is shipped behavior; `design.md` is history |
| `.deps/fuse3-arm64/` | Vendored arm64 libfuse3 `.deb` files, `SHA256SUMS`, NOTICE, and copyright. `build.zig` and `scripts/extract_fuse3_arm64.sh` verify the digests; extract writes under `.scratch/fuse3-arm64/`; `check.sh` checks them too |

## Gates

`./scripts/check.sh` is the blocking gate (fmt, changelog, tests, drill stub,
fuse3 digests, script `--help`, shellcheck, ruff, mypy, sbom). Never loosen it
to pass. CHANGELOG `##` headings: `[Unreleased]` first, dated `x.y.z` including
the `build.zig.zon` version, `[name]:` footer links; `v<version>` in README,
SECURITY.md, and `docs/THREAT_MODEL.md`; notes are `###`. CI adds aarch64
cross-compile and a reproducibility rebuild (`./scripts/ci.sh` runs all three).

`run_cluster_e2e_9nodes.sh` needs `/dev/fuse` and `fusermount3`, so it runs
locally rather than in CI. `run_vm_cluster_e2e.sh` is the real-NFS cluster
(4 VMs, libvirt/KVM); also local. `run_e2e_tests.sh` is CLI/protocol only
(no FUSE). `test_fault_tolerance.sh` skips the live-peer check loudly if none
is listening. `dr_restore_drill.sh` runs on the NAS; `test_dr_restore_drill.sh`
is the CI stand-in (stub `zfs`).

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
