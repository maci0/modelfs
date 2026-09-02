# Zig best-practices review

| Field | Value |
|---|---|
| Guide | [zig-best-practices-review.md](../review-guides/zig-best-practices-review.md) |
| Scope | `src/` structure, naming, and builtin selection; `build.zig` module graph |
| Date | 2026-09-02, against `v0.7.0` (`f28e89b`) |
| Result | 3 P2, all fixed. No P0 or P1 |

## Import direction (item A): clean

Every edge points down the documented chain, with no cycles:

```
sys      -> c
piece    -> fuzzcorpus
proto    -> fuzzcorpus piece
rdma     -> piece fuzzcorpus
store    -> piece proto cull sys fuzzcorpus
discover -> proto sys fuzzcorpus
peer     -> piece proto sys store discover rdma fuzzcorpus
handover -> proto sys cull
hf       -> discover store sys
fuse_fs  -> piece proto sys store discover peer cull fuzzcorpus handover
main     -> piece proto sys store discover fuse_fs cull fuzzcorpus handover hf
```

`handover` and `hf`, both new in `v0.7.0`, sit where docs/architecture.md says: beside
`fuse_fs`/`main`, importing downward only, and neither speaks FUSE.

## Findings

| # | Location | Practice | Sev | Outcome |
|---|---|---|---|---|
| 1 | `src/hf.zig` `loadToken` | Bare `4096` as the token-file cap | P2 | **Fixed**: `max_token_bytes`, with a doc comment tying it to `proto.max_psk_bytes` |
| 2 | `src/handover.zig` `readStateFd` | Bare `1 << 20` as the state-blob cap | P2 | **Fixed**: `max_state_bytes`, documented as what bounds a planted fd's allocation |
| 3 | `src/handover.zig` `randomToken` | Raw `std.os.linux.getrandom` and `getpid` outside `sys.zig` | P2 | **Fixed**: moved behind `sys.randomBytes` |

Items 1 and 2 are caps on parsed input, which the house rule treats as more than style: the
value is a security bound and belongs where a reader looking for the bound will find it.

Item 3 was a genuine syscall-wrapper bypass. It is worth recording *why* the raw syscall stays:
`std.crypto.random` and `std.posix.getrandom` are both gone in Zig 0.16, so `std.os.linux` is
the only remaining primitive. The policy is not "never touch the syscall" but "the syscall lives
in `sys.zig`", and it now does.

## Builtin selection (item H): clean

No `@ptrCast` on a length or offset derived from peer bytes, a lease, or a manifest. Wire and
sidecar narrowing goes through `std.math.cast` or a checked range; `piece.zig` uses saturating
`+|` and `-|` where a hostile size would otherwise wrap. `@popCount`, `@clz`, and `@ctz` are
used where bits are counted or scanned rather than a bit-at-a-time loop.

The one offset-based read of a foreign struct is deliberate and documented: `fuse_file_info`
carries bitfields, so translate-c renders it opaque, and `fi_fh_off`/`fi_bits_off` name the
head layout verified identical on libfuse 3.14 (vendored arm64) and 3.18 (build host).

## The C door (item C): clean

One `@cImport` reference in the tree, and it is the comment in `src/c.zig` explaining that
`build.zig` translates `src/c.h` instead. `v0.7.0` removed hand-written libfuse prototypes in
favor of including `<fuse_lowlevel.h>` in that one header, which is the right direction.

`FuseInitMsg` in `src/fuse_fs.zig` is a hand-written struct, and is the documented exception:
it mirrors a kernel ABI (`linux/fuse.h`) the libfuse headers do not expose, and says so at its
definition.

## After

`./scripts/check.sh` green, 352 tests.
