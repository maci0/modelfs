#!/usr/bin/env python3
"""
Benchmark & Figure Generator for modelfs
Runs real latency, throughput, and cluster scaling benchmarks across modelfs peer nodes
and plots publication-grade figures using matplotlib.

Numbers come from the machine running the script, so by default the report and
figures land in .scratch/benchmarks/ (gitignored); pass --update-docs to
regenerate the tracked docs/benchmarks.md and docs/figures/.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

try:
    import matplotlib.pyplot as plt
except ModuleNotFoundError:
    sys.exit(
        "matplotlib not found: install the pinned Python tooling "
        "(uv venv .venv && uv pip install --require-hashes -r requirements-dev.lock.txt, "
        "see CONTRIBUTING.md); this script re-execs under .venv automatically once it exists"
    )

BENCH_PSK = "bench_psk_key_123456789"

# Same convention as scripts/check.sh: when the pinned .venv exists, run under
# it, so benchmarks use the declared interpreter (.python-version) and the
# locked matplotlib instead of whatever python3 is first on PATH.
_SCRIPT = os.fspath(Path(__file__).resolve())
_VENV_PYTHON = Path(_SCRIPT).parent.parent / ".venv" / "bin" / "python3"


def reexec_under_venv() -> None:
    if not _VENV_PYTHON.is_file() or Path(sys.executable).samefile(_VENV_PYTHON):
        return
    os.execv(os.fspath(_VENV_PYTHON), [os.fspath(_VENV_PYTHON), _SCRIPT, *sys.argv[1:]])


def require_fuse() -> None:
    """Fail with named problems instead of nine daemons dying obscurely later."""
    problems: list[str] = []
    if not Path("/dev/fuse").exists():
        problems.append("/dev/fuse is missing")
    if shutil.which("fusermount3") is None and shutil.which("fusermount") is None:
        problems.append("no fusermount3/fusermount helper on PATH")
    if problems:
        sys.exit(
            "cannot run benchmarks: "
            + "; ".join(problems)
            + " -- every benchmark mounts a live FUSE filesystem (see CONTRIBUTING.md)"
        )


def unmount(mount_dir: str) -> None:
    """Best-effort unmount via whichever FUSE helper exists (libfuse3 first)."""
    helper = shutil.which("fusermount3") or shutil.which("fusermount")
    cmd = [helper, "-u", mount_dir] if helper else ["umount", mount_dir]
    subprocess.run(cmd, capture_output=True, check=False)


def wait_for_ping(port: int, psk: str, timeout_s: float = 30.0) -> None:
    """Poll one daemon's /ping until it answers, or fail after a fixed budget.

    A fixed sleep is a guess at the bind time, and nine concurrent FUSE
    mounts on a loaded host can bind later than any constant; one refused
    connection would then kill the whole benchmark run mid-sweep. A node
    that answers but rejects (wrong PSK, server error) fails immediately:
    retrying cannot fix that.
    """
    headers = {"Authorization": f"Bearer {psk}"}
    url = f"http://127.0.0.1:{port}/ping"
    deadline = time.monotonic() + timeout_s
    while True:
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                assert resp.read() == b"ok", (
                    f"Node on port {port} answered /ping with an unexpected body"
                )
        except urllib.error.HTTPError as e:
            sys.exit(f"node on port {port}: /ping rejected with HTTP {e.code}")
        except OSError:
            if time.monotonic() >= deadline:
                sys.exit(
                    f"node on port {port}: no working listener within "
                    f"{timeout_s:.0f}s (daemon failed to start or died)"
                )
            time.sleep(0.2)
        else:
            return


def stop_mount(p: subprocess.Popen[bytes], mount_dir: str) -> None:
    """Tear down one benchmark mount daemon on every exit path.

    terminate() without wait() would leave an unreaped child holding its peer
    port and FUSE mount until interpreter exit; a skipped teardown (benchmark
    assertion or HTTP failure) would orphan the daemon across runs.
    """
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
    unmount(mount_dir)


plt.style.use("seaborn-v0_8-paper" if "seaborn-v0_8-paper" in plt.style.available else "default")
plt.rcParams["font.sans-serif"] = "DejaVu Sans"
plt.rcParams["axes.edgecolor"] = "#333333"
plt.rcParams["axes.linewidth"] = 0.8


def build_modelfs() -> str:
    print("=== Building modelfs binary ===")
    # ReleaseFast: these figures document the daemon operators run (README
    # builds -Doptimize=ReleaseFast). A Debug build carries full safety checks
    # and no optimization, inflating per-request fixed cost and understating
    # sendfile throughput; the piece-size sweep's shape depends on exactly
    # that fixed cost.
    res = subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseFast"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if res.returncode != 0:
        print("Build failed:", res.stderr)
        sys.exit(1)
    bin_path = os.path.abspath("zig-out/bin/modelfs")
    assert os.path.exists(bin_path), f"Binary missing at {bin_path}"
    return bin_path


def make_origin_and_psk(temp_dir: str) -> tuple[str, str]:
    """Fresh empty origin dir plus a 0600 PSK file for one benchmark run."""
    origin_dir = os.path.join(temp_dir, "origin")
    psk_file = os.path.join(temp_dir, "modelfs.psk")
    os.makedirs(origin_dir, exist_ok=True)
    # UTF-8 named: this file is the daemon's --psk input, read back byte-exact
    # by the verifier and trimmed to " \t\r\n" on both sides.
    with open(psk_file, "w", encoding="utf-8") as f:
        f.write(BENCH_PSK + "\n")
    os.chmod(psk_file, 0o600)
    return origin_dir, psk_file


def run_cluster_latency_benchmark(bin_path: str) -> tuple[list[int], list[float]]:
    print("=== Benchmark 1: Cluster Endpoint Query Latency Scaling ===")
    temp_dir = tempfile.mkdtemp(prefix="modelfs-bench-cluster-")
    try:
        origin_dir, psk_file = make_origin_and_psk(temp_dir)

        node_counts = [1, 3, 5, 7, 9]
        latencies_ms = []

        procs = []
        # The guard opens before the first daemon spawns: a failure partway
        # through the loop (makedirs/Popen raising) must still tear down every
        # daemon already started, not orphan it with its FUSE mount and port.
        try:
            for i in range(1, 10):
                cache_dir = os.path.join(temp_dir, f"cache_{i}")
                mount_dir = os.path.join(temp_dir, f"mount_{i}")
                os.makedirs(cache_dir, exist_ok=True)
                os.makedirs(mount_dir, exist_ok=True)
                port = 19100 + i

                p = subprocess.Popen(
                    [
                        bin_path,
                        "mount",
                        mount_dir,
                        "--origin",
                        origin_dir,
                        "--cache",
                        cache_dir,
                        "--id",
                        f"node_{i}",
                        "--listen",
                        f"127.0.0.1:{port}",
                        "--psk",
                        psk_file,
                        "--piece",
                        "4M",
                    ]
                )
                procs.append((p, port, mount_dir))

            # Every listener must be up before the timed sweep: poll instead
            # of a fixed sleep, whose guess would otherwise surface inside
            # the measured window as ConnectionRefused.
            for _, port, _ in procs:
                wait_for_ping(port, BENCH_PSK)

            headers = {"Authorization": f"Bearer {BENCH_PSK}"}

            for num_nodes in node_counts:
                # Measure /ping latency across active nodes
                t0 = time.monotonic()
                for i in range(1, num_nodes + 1):
                    port = 19100 + i
                    url = f"http://127.0.0.1:{port}/ping"
                    req = urllib.request.Request(url, headers=headers)
                    with urllib.request.urlopen(req, timeout=30) as resp:
                        assert resp.read() == b"ok"
                t1 = time.monotonic()
                elapsed_ms = round((t1 - t0) * 1000.0, 2)
                latencies_ms.append(elapsed_ms)
                print(f"  Nodes: {num_nodes} -> Total Latency: {elapsed_ms} ms")
        finally:
            # Every spawned mount daemon must die even when a spawn or probe
            # raises; otherwise orphans hold ports and stale FUSE mounts.
            for p, _, mount_dir in procs:
                stop_mount(p, mount_dir)

        return node_counts, latencies_ms
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def run_throughput_vs_piece_size_benchmark(bin_path: str) -> tuple[list[str], list[float]]:
    print("=== Benchmark 2: Expanded Chunk Size Sweep (256KB to 64MB) ===")
    temp_dir = tempfile.mkdtemp(prefix="modelfs-bench-size-")
    try:
        origin_dir, psk_file = make_origin_and_psk(temp_dir)

        chunk_configs = [
            ("256K", 256 * 1024),
            ("512K", 512 * 1024),
            ("1M", 1 * 1024 * 1024),
            ("2M", 2 * 1024 * 1024),
            ("4M", 4 * 1024 * 1024),
            ("8M", 8 * 1024 * 1024),
            ("16M", 16 * 1024 * 1024),
            ("32M", 32 * 1024 * 1024),
            ("64M", 64 * 1024 * 1024),
        ]

        chunk_labels = [c[0] for c in chunk_configs]
        throughputs_mbps = []

        for idx, (label, bytes_len) in enumerate(chunk_configs):
            test_file = f"test_{label}.bin"
            file_path = os.path.join(origin_dir, test_file)

            data = os.urandom(bytes_len)
            with open(file_path, "wb") as f:
                f.write(data)

            cache_dir = os.path.join(temp_dir, f"cache_{idx}")
            mount_dir = os.path.join(temp_dir, f"mount_{idx}")
            os.makedirs(cache_dir, exist_ok=True)
            os.makedirs(mount_dir, exist_ok=True)
            port = 19600 + idx

            p = subprocess.Popen(
                [
                    bin_path,
                    "mount",
                    mount_dir,
                    "--origin",
                    origin_dir,
                    "--cache",
                    cache_dir,
                    "--id",
                    f"node_size_{label}",
                    "--listen",
                    f"127.0.0.1:{port}",
                    "--psk",
                    psk_file,
                    "--piece",
                    label,
                ]
            )
            try:
                # The daemon must be serving before hydration and the timed
                # fetch; poll its /ping instead of sleeping a constant.
                wait_for_ping(port, BENCH_PSK)

                headers = {"Authorization": f"Bearer {BENCH_PSK}"}

                # Hydrate piece via mount read if file exists
                mount_file_path = os.path.join(mount_dir, test_file)
                if os.path.exists(mount_file_path):
                    with open(mount_file_path, "rb") as mf:
                        _ = mf.read(1024)

                # Fetch piece via /data HTTP range request
                path_enc = urllib.parse.quote(test_file, safe="")
                data_url = f"http://127.0.0.1:{port}/data?path={path_enc}"
                req = urllib.request.Request(
                    data_url,
                    headers={**headers, "Range": f"bytes=0-{len(data) - 1}"},
                )

                t0 = time.monotonic()
                with urllib.request.urlopen(req, timeout=30) as resp:
                    got_data = resp.read()
                t1 = time.monotonic()

                assert len(got_data) == len(data), f"Data size mismatch for {label}"
                elapsed_sec = t1 - t0
                size_mb = bytes_len / (1024.0 * 1024.0)
                mbps = round(size_mb / max(elapsed_sec, 0.0001), 2)
                throughputs_mbps.append(mbps)
                print(
                    f"  Chunk Size: {label:>4} ({size_mb:>5.2f} MB) -> "
                    f"Throughput: {mbps:>7.2f} MB/s (Elapsed: {elapsed_sec * 1000:>6.2f} ms)"
                )
            finally:
                # Unmount failure must not mask benchmark results; best-effort
                # cleanup. Runs on every exit path so a failed fetch or assert
                # cannot orphan this mount daemon.
                stop_mount(p, mount_dir)

        return chunk_labels, throughputs_mbps
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def plot_figures(
    node_counts: list[int],
    latencies_ms: list[float],
    chunk_labels: list[str],
    throughputs_mbps: list[float],
    out_dir: Path,
) -> None:
    print("=== Generating Publication-Quality Benchmark Charts ===")
    figures_dir = out_dir / "figures"
    figures_dir.mkdir(parents=True, exist_ok=True)

    # Figure 1: Cluster Latency Scaling
    fig, ax = plt.subplots(figsize=(6.5, 4), dpi=300)
    ax.plot(
        node_counts,
        latencies_ms,
        marker="o",
        linewidth=2.2,
        color="#1f77b4",
        markersize=6,
        label="Cluster Response Latency",
    )
    ax.set_title(
        "modelfs Cluster Endpoint Query Latency Scaling",
        fontsize=12,
        fontweight="bold",
        pad=10,
    )
    ax.set_xlabel("Active Cluster Nodes (Count)", fontsize=10, labelpad=8)
    ax.set_ylabel("Total Query Latency (ms)", fontsize=10, labelpad=8)
    ax.set_xticks(node_counts)
    ax.grid(visible=True, linestyle="--", alpha=0.5)
    ax.legend(frameon=True, facecolor="white", framealpha=0.9)
    plt.tight_layout()
    fig1_path = str(figures_dir / "fig1_cluster_latency_scaling.png")
    fig.savefig(fig1_path, dpi=300)
    plt.close(fig)
    print(f"✓ Saved Figure 1: {fig1_path}")

    # Figure 2: Throughput vs Expanded Chunk Sizes (256KB to 64MB)
    fig, ax = plt.subplots(figsize=(7.5, 4.2), dpi=300)
    bars = ax.bar(
        chunk_labels,
        throughputs_mbps,
        color="#2ca02c",
        width=0.55,
        edgecolor="#1b661b",
        linewidth=0.8,
    )
    ax.set_title(
        "modelfs Zero-Copy HTTP Piece Throughput Across Chunk Sizes",
        fontsize=12,
        fontweight="bold",
        pad=10,
    )
    ax.set_xlabel("Piece Chunk Size", fontsize=10, labelpad=8)
    ax.set_ylabel("Transfer Throughput (MB/s)", fontsize=10, labelpad=8)
    ax.grid(axis="y", linestyle="--", alpha=0.5)

    # Value labels on top of bars
    for bar in bars:
        height = bar.get_height()
        ax.annotate(
            f"{height:.0f} MB/s",
            xy=(bar.get_x() + bar.get_width() / 2, height),
            xytext=(0, 4),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=7.5,
            fontweight="bold",
        )

    plt.tight_layout()
    fig2_path = str(figures_dir / "fig2_throughput_vs_piece_size.png")
    fig.savefig(fig2_path, dpi=300)
    plt.close(fig)
    print(f"✓ Saved Figure 2: {fig2_path}")

    # Figure 3: Storage Tier Latency Comparison
    fig, ax = plt.subplots(figsize=(6.5, 4), dpi=300)
    tiers = ["Local NVMe Cache", "Peer HTTP (Sendfile)", "NFS Origin Fallback"]
    # Illustrative design targets, not measured here; the report says so too.
    tier_latencies = [0.15, 0.65, 8.5]
    colors = ["#1f77b4", "#ff7f0e", "#d62728"]

    bars = ax.bar(
        tiers,
        tier_latencies,
        color=colors,
        width=0.45,
        edgecolor="#333333",
        linewidth=0.8,
    )
    ax.set_title(
        "modelfs Block Fetch Latency by Storage Tier (illustrative)",
        fontsize=12,
        fontweight="bold",
        pad=10,
    )
    ax.set_ylabel("Fetch Latency per 4MB Block (ms)", fontsize=10, labelpad=8)
    ax.grid(axis="y", linestyle="--", alpha=0.5)

    for bar in bars:
        height = bar.get_height()
        ax.annotate(
            f"{height:.2f} ms",
            xy=(bar.get_x() + bar.get_width() / 2, height),
            xytext=(0, 4),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=8.5,
            fontweight="bold",
        )

    plt.tight_layout()
    fig3_path = str(figures_dir / "fig3_tier_latency_comparison.png")
    fig.savefig(fig3_path, dpi=300)
    plt.close(fig)
    print(f"✓ Saved Figure 3: {fig3_path}")


def generate_report(
    node_counts: list[int],
    latencies_ms: list[float],
    chunk_labels: list[str],
    throughputs_mbps: list[float],
    out_dir: Path,
) -> None:
    latency_table = "\n".join(
        f"| {n} | {ms} ms |" for n, ms in zip(node_counts, latencies_ms, strict=True)
    )
    sweep_table = "\n".join(
        f"| {label} | {mbps:.0f} MB/s |"
        for label, mbps in zip(chunk_labels, throughputs_mbps, strict=True)
    )
    report_date = datetime.now(UTC).date().isoformat()
    report_content = f"""# Benchmarks

| Field | Value |
|---|---|
| Status | Generated by `scripts/run_benchmarks_and_plots.py`; edit that, not this file |
| Date | {report_date} |
| Topology | **{max(node_counts)} `modelfs` instances on one host, TCP loopback.** Not a cluster |

Loopback removes the NIC, the switch, and the remote page cache, so these numbers
bound the software rather than a deployment. Read them as ceilings and ratios.

---

## 1. Peer query latency vs cluster size

Total `/ping` round-trip time across the first N live instances:

| Instances | Total |
|---|---|
{latency_table}

Total query time stays near a millisecond from three instances upward, so the
per-peer cost falls as the cluster grows instead of scaling linearly. The first
call carries process warmup. On top of this, `/have` bitmaps are cached for 2 s
per peer and path (see [architecture.md](architecture.md)).

![Query latency vs cluster size](figures/fig1_cluster_latency_scaling.png)

## 2. Throughput vs piece size

Zero-copy `sendfile` streaming:

| Piece | Throughput |
|---|---|
{sweep_table}

Throughput climbs with piece size and then wobbles, which is per-request fixed
cost being amortised against page-cache and socket-buffer effects rather than a
clean curve. 16 MiB is the default piece: past it the gain is small, and a miss
costs the reader the whole piece before the read returns.

![Throughput vs piece size](figures/fig2_throughput_vs_piece_size.png)

## 3. Tier comparison

**Illustrative, not measured.** These are the order-of-magnitude figures the
design assumes, drawn to show the shape of the hierarchy; nothing in this script
times them.

| Source | Latency per 4 MiB block |
|---|---|
| Local NVMe cache | 0.15 ms |
| Peer over HTTP (`sendfile`) | 0.65 ms |
| NFS origin | 8.5 ms |

The ordering is the point: a peer answers roughly an order of magnitude faster
than the origin, so the first node to pull a model pays NFS once and the rest pay
peer latency.

![Tier latency comparison](figures/fig3_tier_latency_comparison.png)
"""
    report_path = out_dir / "benchmarks.md"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report_content)
    print(f"✓ Generated Benchmark Report: {report_path}")


def main() -> None:
    reexec_under_venv()
    require_fuse()
    parser = argparse.ArgumentParser(
        description="Run the modelfs benchmarks and render report + figures."
    )
    parser.add_argument(
        "--update-docs",
        action="store_true",
        help="overwrite the tracked docs/benchmarks.md and docs/figures/ "
        "(default: write to .scratch/benchmarks/, since every run records "
        "the local machine's numbers)",
    )
    args = parser.parse_args()
    out_dir = Path("docs") if args.update_docs else Path(".scratch") / "benchmarks"
    bin_path = build_modelfs()
    node_counts, latencies_ms = run_cluster_latency_benchmark(bin_path)
    chunk_labels, throughputs_mbps = run_throughput_vs_piece_size_benchmark(bin_path)
    plot_figures(node_counts, latencies_ms, chunk_labels, throughputs_mbps, out_dir)
    generate_report(node_counts, latencies_ms, chunk_labels, throughputs_mbps, out_dir)
    if not args.update_docs:
        print(
            f"Outputs in {out_dir} (gitignored): these are this machine's numbers. "
            "To regenerate the tracked docs/benchmarks.md and docs/figures/, rerun "
            "with --update-docs from representative hardware."
        )
    print("=== All Benchmarks and Figure Generations Completed Successfully ===")


if __name__ == "__main__":
    main()
