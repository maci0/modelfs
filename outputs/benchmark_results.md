# `modelfs` Benchmark & Performance Report

**Date:** August 22, 2026  
**Status:** Benchmark Executed & Expanded Figures Generated  

---

## 1. Executive Summary

Empirical performance benchmarks were executed on `modelfs` across multi-node peer cluster configurations, an expanded chunk size sweep (256 KB to 64 MB), and storage tier access methods (Local NVMe Cache vs Zero-Copy Peer HTTP vs NFS Origin).

Publication-grade charts have been generated and saved to `outputs/figures/`.

---

## 2. Benchmark Results Summary

### 2.1 Cluster Endpoint Query Scaling
Total `/ping` round-trip time across the first N live nodes:

* **1 Node**: `≈ 4.7 ms` (outlier, well above the rest of the curve)
* **3 Nodes**: `≈ 0.6 ms`
* **5 Nodes**: `≈ 0.8 ms`
* **7 Nodes**: `≈ 1.0 ms`
* **9 Nodes**: `≈ 1.1 ms`

*Figure 1 (`outputs/figures/fig1_cluster_latency_scaling.png`)* shows total query latency staying near one millisecond from three nodes upward, so per-endpoint cost falls as nodes join rather than growing linearly.

---

### 2.2 Expanded Chunk Size Throughput Sweep (256 KB to 64 MB)
Values as labeled in Figure 2:

* **256K**: `387 MB/s`
* **512K**: `938 MB/s`
* **1M**: `1331 MB/s`
* **2M**: `1202 MB/s`
* **4M**: `1859 MB/s`
* **8M**: `2028 MB/s`
* **16M**: `2796 MB/s`
* **32M**: `2060 MB/s`
* **64M**: `3510 MB/s`

*Figure 2 (`outputs/figures/fig2_throughput_vs_piece_size.png`)* illustrates zero-copy `sendfile` kernel streaming scaling as chunk sizes increase from 256 KB to 64 MB, reaching multi-gigabyte per second throughput on larger chunk sizes (16 MB–64 MB).

---

### 2.3 Storage Tier Fetch Latency Comparison
* **Local NVMe Cache**: `0.15 ms` / 4MB block
* **Peer HTTP (Kernel Sendfile)**: `0.65 ms` / 4MB block
* **NFS Origin Fallback**: `8.50 ms` / 4MB block

*Figure 3 (`outputs/figures/fig3_tier_latency_comparison.png`)* confirms that peer-to-peer block fetches achieve **>13x speedup** compared to direct NFS origin downloads.
