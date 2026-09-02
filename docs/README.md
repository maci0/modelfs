# ModelFS documentation

Setup and CLI usage are in the [top-level README](../README.md). Recent changes are in
[CHANGELOG.md](../CHANGELOG.md).

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | **Start here.** Shipped behavior: the three cache layers, discovery and leases, path scoring, auth, culling, write races |
| [operations.md](operations.md) | The ZFS/NFS/FS-Cache layers underneath, per-host mount setup, Hugging Face downloads, failure modes |
| [recovery.md](recovery.md) | Durability: state inventory, snapshot/replica schedule, per-disaster restore steps, RPO/RTO, the monthly restore drill and its alarms |
| [benchmarks.md](benchmarks.md) | Measured latency and throughput, with the loopback caveat that qualifies them |
| [THREAT_MODEL.md](THREAT_MODEL.md) | Attack surface, trust boundaries, risk-ranked threats, and which controls exist versus which are missing |
| [audits.md](audits.md) | Findings from the 2026-08-22 review passes and how each was fixed |
| [design.md](design.md) | The original architecture sketch, goals G1-G10, and key decisions, each with ship status. Kept for history; current behavior is architecture.md |

## review-guides/

Prompts for agent review passes, one subject each, with no overlapping verdicts. Each states an
applicability gate, a checklist naming real symbols in this tree, a severity scale, and the
`docs/reviews/` file it writes.

| Guide | Subject | Owns the verdict on |
|---|---|---|
| [zig-src-review.md](review-guides/zig-src-review.md) | `src/` defects | auth escapes, path escapes, crashes, leaks, cache poisoning |
| [net-send-review.md](review-guides/net-send-review.md) | the peer transfer path | source selection, the fallback ladder, deadlines, saturation, counter coverage |
| [abstractions-review.md](review-guides/abstractions-review.md) | whether a type earns its keep | delete, inline, move layer, or introduce |
| [zig-idiomatic-review.md](review-guides/zig-idiomatic-review.md) | code shape inside a function | allocators, ownership, error sets, comptime, slices |
| [zig-best-practices-review.md](review-guides/zig-best-practices-review.md) | structure and naming | import direction, concern ownership, `@builtin` choice |
| [zig-0.16-changelog-review.md](review-guides/zig-0.16-changelog-review.md) | stdlib migration | removed, deprecated, and renamed APIs against the 0.16 notes |
| [simd-review.md](review-guides/simd-review.md) | vectorization | ship or reject, with a measured baseline |
| [scripts-review.md](review-guides/scripts-review.md) | `scripts/` | harness defects the lint gates cannot see |
| [docs-drift-review.md](review-guides/docs-drift-review.md) | these documents | claims that no longer match the code |
| [agentrules-review.md](review-guides/agentrules-review.md) | `AGENTS.md` | whether the rules work as agent instructions |
