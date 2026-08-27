# ModelFS documentation

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | **Start here.** Shipped behavior: the three cache layers, discovery and leases, path scoring, auth, culling, write races |
| [operations.md](operations.md) | The ZFS/NFS/FS-Cache layers underneath, per-host mount setup, Hugging Face downloads, failure modes |
| [recovery.md](recovery.md) | Durability posture: state inventory, snapshot/replica schedule, per-disaster restore steps, RPO/RTO, monthly restore drill |
| [benchmarks.md](benchmarks.md) | Measured latency and throughput, with the loopback caveat that qualifies them |
| [audits.md](audits.md) | Findings from the review passes and how each was fixed |
| [THREAT_MODEL.md](THREAT_MODEL.md) | Attack surface, trust boundaries, risk-ranked threats, and which controls exist versus which are missing |
| [review-guides/](review-guides/) | Agent review prompts: Zig idioms, 0.16 conformance, best practices, abstractions, SIMD, and network send path are written for the modelfs game-server tree (an unrelated codebase sharing the name) and their applicability gates skip other trees; [zig-src-review.md](review-guides/zig-src-review.md) reviews this tree's own Zig source for safety and structure defects its static gate cannot see, [docs-drift-review.md](review-guides/docs-drift-review.md) reviews this tree's documentation against `src/`, and [scripts-review.md](review-guides/scripts-review.md) reviews shell and Python under `scripts/` for defects those lint gates cannot see |
| [design.md](design.md) | The original architecture sketch. History: it marks what shipped and what did not |

Setup and CLI usage are in the [top-level README](../README.md). Recent changes are in [CHANGELOG.md](../CHANGELOG.md).
