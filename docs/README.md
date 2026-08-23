# ModelFS documentation

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | **Start here.** Shipped behavior: the three cache layers, discovery and leases, path scoring, auth, culling, write races |
| [operations.md](operations.md) | The ZFS/NFS/FS-Cache layers underneath, per-host mount setup, Hugging Face downloads, failure modes |
| [benchmarks.md](benchmarks.md) | Measured latency and throughput, with the loopback caveat that qualifies them |
| [audits.md](audits.md) | Findings from the review passes and how each was fixed |
| [review-guides/](review-guides/) | The checklists those passes were run against: Zig idioms, 0.16 conformance, best practices, abstractions, SIMD, network send path |
| [design.md](design.md) | The original architecture sketch. History: it marks what shipped and what did not |

Setup and CLI usage are in the [top-level README](../README.md). Recent changes are in [CHANGELOG.md](../CHANGELOG.md).
