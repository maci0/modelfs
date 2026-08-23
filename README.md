# ModelFS

POSIX `/models` filesystem for LLM weights. One Zig 0.16 binary per spark node. FUSE mount via `libfuse3`; peer transfers stream zero-copy through Linux `sendfile`. Designed for high-throughput model loading across GPU clusters running `llama.cpp`, `vLLM`, or `SGLang`.

```
/net/<nas>/models     NFS origin (read/write authority)
/models               FUSE mount point on GPU spark nodes
/var/cache/modelfs    Local NVMe cache (16 MiB default pieces)
:18080                Peer HTTP protocol (PSK bearer auth)
```

Read hierarchy: **Local NVMe Piece → Cluster Peer (`sendfile`) → NFS Origin**.
Write hierarchy: **NFS Origin first → Local NVMe Cache fill**.

---

## Key Performance Benchmarks

| Metric / Benchmark | Performance | Details |
| :--- | :--- | :--- |
| **Peak Zero-Copy Throughput** | **3.63 GB/s** | Direct NVMe page cache to TCP socket streaming via Linux `sendfile` |
| **9-Node Cluster Query Latency** | **1.13 ms** | O(1) bitfield scanning & lease lookup across 9 active nodes |
| **16MB Piece Transfer Latency** | **5.08 ms** | Single-pass pre-allocated direct socket read |
| **32MB Piece Transfer Latency** | **9.85 ms** | Single-pass pre-allocated direct socket read |
| **64MB Piece Transfer Latency** | **17.63 ms** | Single-pass pre-allocated direct socket read |

---

## Architectural Highlights

* **Zig 0.16.0 Standard Library Idioms**: Strictly typed error sets, zero-allocation stack-buffered directory scanning, and explicit memory allocators (`DebugAllocator` verified zero leaks).
* **Strict C Interop Isolation**: libfuse3 and libc declarations are translated once from [`src/c.h`](src/c.h) by `build.zig` (`@cImport` is deprecated in Zig 0.16). `src/c.zig` re-exports that module, and every other module (`sys.zig`, `peer.zig`, `proto.zig`, `discover.zig`, `store.zig`, `main.zig`, `piece.zig`, `fuse_fs.zig`, `cull.zig`) reaches C declarations only through it.
* **SIMD & Power-of-Two Optimizations**:
  * Bitfield scanning leverages 64-bit hardware `@popCount` SIMD instructions.
  * Piece index/offset arithmetic uses comptime bit-shifts (`<<`, `>>`) for power-of-two chunk sizes.
* **Comptime Lookup Tables**: $O(1)$ URL encoding via a comptime-generated 256-entry character class LUT in `src/proto.zig`.

---

## Dependencies

* **Runtime**: none beyond the platform. The binary links only `libfuse3` and libc/pthread; `build.zig.zon` declares zero package dependencies.
* **Cross builds**: aarch64 builds use the vendored Ubuntu noble libfuse3 under [`.deps/fuse3-arm64/`](.deps/fuse3-arm64/README.md) (provenance and sha256 digests recorded there).
* **Python tooling** (`scripts/`): declared in [`requirements-dev.txt`](requirements-dev.txt) (`matplotlib`, `mypy`, `ruff`); install with `uv pip install -r requirements-dev.txt`.

---

## Verification & Test Harnesses

```bash
# 1. Run full unit test suite (0 memory leaks)
zig build test --summary all

# 2. Run E2E CLI & Protocol integration suite
./scripts/run_e2e_tests.sh

# 3. Run 9-Node Cluster multi-peer block exchange benchmark
./scripts/run_cluster_e2e_9nodes.sh

# 4. Run Fault Tolerance & Lease Expiration test suite
./scripts/test_fault_tolerance.sh

# 5. Run full benchmark sweep & generate publication plots
python3 scripts/run_benchmarks_and_plots.py
```

---

## Review Reports & Documentation

* **[docs/peer-cache.md](docs/peer-cache.md)**: Peer discovery, caching hierarchy, and NVMe disk culling bounds.
* **[docs/reviews/](docs/reviews/)**: Codebase audit and refactoring reports:
  * `ZIG_REVIEW.md`: Core Zig implementation audit.
  * `ZIG_0_16_REVIEW.md`: Zig 0.16 std lib API updates.
  * `ZIG_PRACTICES_REVIEW.md`: Memory, error handling, and thread safety audit.
  * `ABSTRACTION_REVIEW.md`: Module decomposition and API boundaries.
  * `SIMD_REVIEW.md`: SIMD `@popCount` vectorization analysis.
  * `NET_SEND_REVIEW.md`: Network protocol and zero-copy `sendfile` architecture.
* **[outputs/benchmark_results.md](outputs/benchmark_results.md)**: Full benchmark performance report.
* **[outputs/figures/](outputs/figures/)**: High-resolution publication-quality benchmark plots.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
