# modelfs

Single Zig binary: a FUSE mount at `/models` backed by a local NVMe piece
cache, peer-to-peer piece transfers over plaintext HTTP with one shared PSK,
and an NFS origin as the write authority. Linux only. A correct change
respects this tree's layout, gates, and constraints, and is finished when
`./scripts/check.sh` passes with the change in it: a test beside the code
for every `src/` behavior added or changed, a `###` entry under
`## [Unreleased]` in `CHANGELOG.md` for a behavior change, and the same
edit to `docs/architecture.md` when shipped behavior moves.

## Layout

| Path | Contents |
|---|---|
| `src/*.zig` | The daemon. Tests live beside the code they cover; a new file is invisible to `zig build test` until `root.zig` imports it. `-Dtest-filter=` matches test names, not files |
| `src/c.h`, `src/c.zig` | Sole C-header door (libfuse3 + libc types). `build.zig` translates `c.h` once (through `src/c_musl.h` for musl). Change the maintained headers or `build.zig`, never the generated bindings; `src/c.zig` is a maintained re-export. Import via `c.zig` / `sys.zig`, never `@cImport` |
| `scripts/` | Gates and harnesses. `lib.sh` defines `ROOT_DIR`/`SCRATCH_DIR`/`SCRIPTS_DIR`; shell scripts source it before using those variables; scripts using none of them are exempt. `SCRIPTS_DIR` is the on-disk name; leave the spelling alone: every suite that sources `lib.sh` reads it |
| `docs/` | `README.md` indexes them. `architecture.md` is shipped behavior. `review-guides/` holds the per-subject review prompts, each with its own applicability gate |
| `.github/` | Workflows plus the composite actions in `.github/actions/` (the checkout-without-credentials and Zig setup every build job shares, and the gate toolchain both check jobs share) and `dependabot.yml`, which proposes the action-pin bumps in PRs. `scripts/sbom.py` reads the SHA pins out of both directories: an unpinned `uses:` fails generation, a bumped pin fails `--check` until `sbom.cdx.json` is regenerated |
| `.deps/fuse3-arm64/` | Vendored arm64 libfuse3 `.deb` files, `SHA256SUMS`, NOTICE, and copyright. `build.zig` and `scripts/extract_fuse3_arm64.sh` verify the digests; extract writes under `.scratch/fuse3-arm64/`; `check.sh` checks them too. Pinned input, not a place to patch: a fix goes in `build.zig`, `src/c.h`, or a version bump, and an edit here fails the digest checks |
| `.deps/libfuse3-3.16.2/` | Vendored libfuse3 3.16.2 source for the static single-file release builds (`-Dfuse-static` compiles it in; `scripts/build_static.sh` drives it, `.github/workflows/release.yml` publishes the artifacts). `build.zig` and `check.sh` verify its `SHA256SUMS` too, including that the sums list every file present. Pinned input, not a place to patch: same rule as `.deps/fuse3-arm64/` |

## Gates

`./scripts/check.sh` is the blocking gate. **Never loosen a gate to pass it.**
If prerequisites such as `.venv/bin` are unavailable, or session restrictions
prevent running the gate, stop verification and state the blocker; do not claim
it passed or bypass those restrictions to install tools or run commands.
It runs:

- `zig fmt --check`, and `zig build test`
- every `src/*.zig` other than `root.zig` and `c.zig` imported from `src/root.zig`
- CHANGELOG `##` headings: `[Unreleased]` first, dated semver matching
  `build.zig.zon`, `[name]:` footer links, and current-tag sentences in
  README.md, SECURITY.md, and docs/threat-model.md. Dated notes are `###`
- shellcheck (`.shellcheckrc` on every `scripts/**/*.sh`, whose optional
  check names `check.sh` verifies against `shellcheck --list-optional`, and
  on the `run:` steps `scripts/ci_run_steps.awk` extracts from
  `.github/workflows/` and `.github/actions/`),
  and contributor-script `--help` handlers (`test_scripts_help.sh`)
- vendored libfuse3 digest checks (both vendored dirs) and arm64 extract check
  (`test_extract_fuse3_arm64.sh`)
- `test_dr_restore_drill.sh`
- release packaging rerun (`test_package_release.sh`), because the release job
  is re-runnable
- harness policy checks no linter can see: every `mktemp` template names
  `SCRATCH_DIR`; a `scripts/**/*.sh` that reads `ROOT_DIR`, `SCRATCH_DIR`, or
  `SCRIPTS_DIR` sources `lib.sh`, and one that reads none of the three is on
  `check.sh`'s `no_lib_sh` exemption list; a `scripts/nas/*.service` exports
  no `MODELFS_` knob, no secret on `ExecStart`, and no `/tmp` path; and every
  `MF_` knob read under `scripts/` is listed in `lib.sh`'s member block
- one check per review guide under `docs/review-guides/`: each names its own
  applicability gate, so a prompt for another tree skips instead of reviewing
  code it does not own
- `ruff check`, `ruff format --check`, `mypy`, `scripts/sbom.py --self-test`,
  and `scripts/sbom.py --check`

The Python tools must come from `.venv/bin` with an interpreter matching
`.python-version`; an empty venv is not enough. CI runs that gate plus the
aarch64 glibc cross-compile, a native aarch64 runner running the same gate, the static
single-file musl smoke build (`scripts/build_static.sh`), and the reproducibility rebuild;
`./scripts/ci.sh` runs the x86_64 gate, the cross-compile, and the rebuild locally -- the
native aarch64 gate runs only on GitHub's runner.

Suites outside the gate (most need hardware CI lacks):

| Script | Needs | Covers |
|---|---|---|
| `run_cluster_e2e_9nodes.sh` | `/dev/fuse`, `fusermount3` | 9 mounts exchanging pieces |
| `test_hot_reload.sh` | same | `modelfs update`: mounts, holds an fd open across two image swaps, then checks the pid, the peer port, the held fd's bytes, and the unmount on exit |
| `run_vm_cluster_e2e.sh` | libvirt/KVM | the real-NFS cluster, 4 VMs |
| `run_e2e_tests.sh` | nothing | CLI and protocol only, no FUSE |
| `test_fault_tolerance.sh` | a live peer | peer loss and lease expiry; skips loudly without one |
| `dr_restore_drill.sh` | the NAS | the monthly restore drill. `test_dr_restore_drill.sh` is the CI stand-in against a stub `zfs` |
| `dr_pool_restore.sh`, `dr_point_restore.sh` | the NAS | recovery procedures C and B: replay a pool-loss copy, copy named paths back from a known-good snapshot. Both print the plan and write nothing without `--execute` |
| `check_drill_log.sh`, `check_offsite.sh` | a drill log, a mounted offsite copy | alarm when the monthly drill log or the site-loss copy is missing or stale |
| `repro_check.sh` | nothing | every shipped build recipe, two ReleaseFast builds, byte-identical or fail |
| `cross_aarch64.sh` | nothing beyond the vendored `.deb` | aarch64 ReleaseFast; `ci.sh` gives it a `--prefix` under `.scratch/` so a native `zig-out/` survives |

## Constraints

- **No secret reaches argv.** The PSK comes from `--psk FILE`, from the file
  path in `MODELFS_PSK`, or from the secret in `MODELFS_PSK_VALUE`, which the
  mount refuses to combine with either of the first two; the Hugging Face
  token from `HF_TOKEN`, else `$HF_HOME/token`, else
  `~/.cache/huggingface/token`. argv is world-readable through
  `/proc/<pid>/cmdline`. A handover passes both knobs and PSK on a sealed
  memfd for the same reason.
- **Only `src/hf.zig` may contact hosts outside the cluster.** The daemon
  talks to peers and the origin; `modelfs pull` is the one path that contacts
  a host outside the cluster, from the CLI, never from the mount.
- **Run artifacts go to the repo's `.scratch/`**, never `/tmp`: it is tmpfs here,
  and a piece cache written there is charged to RAM. Shell `mktemp` templates
  use `SCRATCH_DIR` from `scripts/lib.sh`; `check.sh` exempts two by name,
  `install_nas_backup.sh` staging beside its destination for an atomic rename
  and `run_vm_cluster_e2e.sh` writing qemu images under
  `/var/lib/libvirt/images`. Python temporary caches, mounts,
  origins, and logs set `dir=` to the repo's `.scratch/`, not the system default.
  `dr_restore_drill.sh` resolves its scratch in that order: `MF_DRILL_SCRATCH`
  when set, else the repo `.scratch/` while `lib.sh` sits beside it, else
  `/var/tmp/modelfs-drill` for the copy `install_nas_backup.sh` plants on
  the NAS, which has no checkout above it.
- **Harness knobs use `MF_`, never `MODELFS_`.** The daemon refuses unknown
  `MODELFS_*` as typo'd knobs.
- **Every external path is untrusted.** Request heads, lease JSON, and encoded
  paths have fuzzed parsers. FUSE handlers go through `resolveRel`; peer and
  CLI model paths require `store.relOk` to return true and
  `discover.relIsCluster` to return false before origin or cache access.
  Peer `/have` and `/data` paths first pass `decodePath` in `src/peer.zig`.
- **No hot-path allocation beyond the reusable hydration buffer.** Piece
  hydration and peer request parsing use stack buffers or one reusable
  piece-sized buffer; the per-request allocation in `hydrateRange`
  (`src/peer.zig`) is that permitted buffer, not an allocation per piece.
  Request parsing must not allocate; allocating functions take an explicit `gpa`.
- **`zig fmt` decides formatting.** `minimum_zig_version` in `build.zig.zon` is
  the single source of truth for the toolchain, including in CI.
- **Docs point at symbols, not line numbers.** Line references rot within a
  commit or two; name the function and the file.
- **One rule file.** `CLAUDE.md` stays a symlink pointer to this file rather
  than a copy; edit rules here, never by replacing the pointer.
