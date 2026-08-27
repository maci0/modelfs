# ModelFS documentation

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | **Start here.** Shipped behavior: the three cache layers, discovery and leases, path scoring, auth, culling, write races |
| [operations.md](operations.md) | The ZFS/NFS/FS-Cache layers underneath, per-host mount setup, Hugging Face downloads, failure modes |
| [recovery.md](recovery.md) | Durability posture: state inventory, snapshot/replica schedule, per-disaster restore steps, RPO/RTO, monthly restore drill |
| [benchmarks.md](benchmarks.md) | Measured latency and throughput, with the loopback caveat that qualifies them |
| [audits.md](audits.md) | Findings from the review passes and how each was fixed |
| [THREAT_MODEL.md](THREAT_MODEL.md) | Attack surface, trust boundaries, risk-ranked threats, and which controls exist versus which are missing |
| [review-guides/](review-guides/) | Agent review prompts. Zig idiom, 0.16, practices, abstractions, SIMD, and net-send guides target an unrelated game-server of the same name and skip this tree; [zig-src-review.md](review-guides/zig-src-review.md), [docs-drift-review.md](review-guides/docs-drift-review.md), and [scripts-review.md](review-guides/scripts-review.md) apply here |
| [design.md](design.md) | Original architecture sketch, requirements G1–G10, and key decisions (section 13), each with ship status. Current behavior is architecture.md |

Setup and CLI usage are in the [top-level README](../README.md). Recent changes are in [CHANGELOG.md](../CHANGELOG.md).
