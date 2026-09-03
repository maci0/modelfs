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
| `.deps/libfuse3-3.16.2/` | Vendored libfuse3 3.16.2 source for the static single-file release builds (`-Dfuse-static` compiles it in; `scripts/build_static.sh` drives it, `.github/workflows/release.yml` publishes the artifacts). `build.zig` and `check.sh` verify its `SHA256SUMS` too |

## Gates

`./scripts/check.sh` is the blocking gate. **Never loosen a gate to pass it.**
It runs:

- `zig fmt --check`, and `zig build test`
- every `src/*.zig` other than `c.zig` imported from `src/root.zig`
- CHANGELOG `##` headings: `[Unreleased]` first, dated semver matching
  `build.zig.zon`, `[name]:` footer links, and current-tag sentences in
  README/SECURITY.md/threat-model.md. Dated notes are `###`
- shellcheck (`.shellcheckrc` on every `scripts/**/*.sh`), and
  contributor-script `--help` handlers (`test_scripts_help.sh`)
- vendored libfuse3 digest and extract checks (both vendored dirs)
- `test_dr_restore_drill.sh`
- `ruff check`, `ruff format --check`, `mypy`, `scripts/sbom.py --self-test`,
  and `scripts/sbom.py --check`

The Python tools must come from `.venv/bin` with an interpreter matching
`.python-version`; an empty venv is not enough. CI runs that gate plus the
aarch64 glibc cross-compile, a native aarch64 runner running the same gate, and the reproducibility rebuild; `./scripts/ci.sh` runs
all three locally.

Suites outside the gate, because each needs hardware CI lacks:

| Script | Needs | Covers |
|---|---|---|
| `run_cluster_e2e_9nodes.sh` | `/dev/fuse`, `fusermount3` | 9 mounts exchanging pieces |
| `test_hot_reload.sh` | same | `modelfs update`: mounts, holds an fd open across two image swaps, then checks the pid, the peer port, the held fd's bytes, and the unmount on exit |
| `run_vm_cluster_e2e.sh` | libvirt/KVM | the real-NFS cluster, 4 VMs |
| `run_e2e_tests.sh` | nothing | CLI and protocol only, no FUSE |
| `test_fault_tolerance.sh` | a live peer | peer loss and lease expiry; skips loudly without one |
| `dr_restore_drill.sh` | the NAS | the monthly restore drill. `test_dr_restore_drill.sh` is the CI stand-in against a stub `zfs` |

## Constraints

- **No secret reaches argv.** The PSK comes from `--psk FILE` or
  `MODELFS_PSK_VALUE`, the Hugging Face token from `HF_TOKEN` or the token file;
  argv is world-readable through `/proc/<pid>/cmdline`. A handover passes both
  knobs and PSK on a sealed memfd for the same reason.
- **`hf.zig` is the only outbound reach.** The daemon talks to peers and the
  origin; `modelfs pull` is the one path that contacts a host outside the
  cluster, from the CLI, never from the mount.
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
