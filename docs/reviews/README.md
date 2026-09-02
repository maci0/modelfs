# Review reports

Output of the prompts in [../review-guides/](../review-guides/), one file per guide. Each
records scope, findings with severity, and what was fixed in the same pass.

| Report | Guide | Date | Verdict |
|---|---|---|---|
| [ZIG_SRC_REVIEW.md](ZIG_SRC_REVIEW.md) | zig-src | 2026-09-02 | no P0/P1 |
| [PEER_TRANSFER_REVIEW.md](PEER_TRANSFER_REVIEW.md) | net-send | 2026-09-02 | no P0/P1 |
| [ABSTRACTIONS_REVIEW.md](ABSTRACTIONS_REVIEW.md) | abstractions | 2026-09-02 | 1 P2 accepted |
| [ZIG_IDIOM_REVIEW.md](ZIG_IDIOM_REVIEW.md) | zig-idiomatic | 2026-09-02 | 1 P1 fixed, 1 P1 deferred |
| [ZIG_PRACTICES_REVIEW.md](ZIG_PRACTICES_REVIEW.md) | zig-best-practices | 2026-09-02 | 3 P2 fixed |
| [ZIG_016_REVIEW.md](ZIG_016_REVIEW.md) | zig-0.16-changelog | 2026-09-02 | 1 P2 deferred |
| [SIMD_REVIEW.md](SIMD_REVIEW.md) | simd | 2026-09-02 | all rejected, as expected |

All seven ran against `v0.7.0` (commit `f28e89b`). `scripts/check.sh` and
`scripts/test_hot_reload.sh` were green after the fixes.
