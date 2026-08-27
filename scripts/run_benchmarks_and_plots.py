#!/usr/bin/env python3
"""Run live latency, throughput, and cluster-scaling benchmarks and plot them.

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
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime
from html import escape
from pathlib import Path

# Sibling module (this directory is sys.path[0] when the script runs): the
# daemon-readiness policy shared with cluster_verify.py.
import peer_ping

BENCH_PSK = "bench_psk_key_123456789"


def bench_headers() -> dict[str, str]:
    """Bearer headers naming the benchmark PSK, for every probe and fetch."""
    return {"Authorization": f"Bearer {BENCH_PSK}"}


_SCRIPT = os.fspath(Path(__file__).resolve())


def project_root() -> Path:
    """Directory holding build.zig.zon, found by walking up from this file."""
    for d in Path(_SCRIPT).parents:
        if (d / "build.zig.zon").is_file():
            return d
    sys.exit(f"cannot find build.zig.zon above {_SCRIPT}")


_ROOT = project_root()

# Same convention as scripts/check.sh: when the pinned .venv exists, run under
# it, so benchmarks use the declared interpreter (.python-version) instead of
# whatever python3 is first on PATH.
_VENV_PYTHON = _ROOT / ".venv" / "bin" / "python3"

# Run artifacts stay on disk in the gitignored scratch dir. The default
# tempfile location is /tmp, which is tmpfs here: a benchmark that writes
# piece caches there is charged to RAM and competes with the thing measured.
_SCRATCH = _ROOT / ".scratch"


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
        cwd=_ROOT,
    )
    if res.returncode != 0:
        print("Build failed:", res.stderr)
        sys.exit(1)
    bin_path = _ROOT / "zig-out" / "bin" / "modelfs"
    if not bin_path.is_file():
        sys.exit(f"Binary missing at {bin_path}")
    return os.fspath(bin_path)


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
    print("=== Benchmark 1: /ping latency vs cluster size ===")
    _SCRATCH.mkdir(parents=True, exist_ok=True)
    temp_dir = tempfile.mkdtemp(prefix="bench-cluster-", dir=_SCRATCH)
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
            headers = bench_headers()
            for _, port, _ in procs:
                peer_ping.wait_for_ping(port, headers, 30.0)

            for num_nodes in node_counts:
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
    print("=== Benchmark 2: throughput vs piece size ===")
    _SCRATCH.mkdir(parents=True, exist_ok=True)
    temp_dir = tempfile.mkdtemp(prefix="bench-size-", dir=_SCRATCH)
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
                headers = bench_headers()
                peer_ping.wait_for_ping(port, headers, 30.0)

                mount_file_path = os.path.join(mount_dir, test_file)
                if os.path.exists(mount_file_path):
                    with open(mount_file_path, "rb") as mf:
                        _ = mf.read(1024)

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
                    f"  Piece size: {label:>4} ({size_mb:>5.2f} MB) -> "
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


_FONT = "DejaVu Sans, sans-serif"
_HEADROOM = 1.15
_Y_TICKS = 4
_BAR_FRACTION = 0.55
_LINE_BOX = (650, 400, 56, 20, 44, 52)
_BAR_BOX = (750, 420, 56, 20, 44, 64)
_TIER_BOX = (650, 420, 56, 20, 44, 64)


@dataclass(slots=True)
class _Box:
    width: int
    height: int
    left: int
    right: int
    top: int
    bottom: int

    @property
    def plot_w(self) -> int:
        return self.width - self.left - self.right

    @property
    def plot_h(self) -> int:
        return self.height - self.top - self.bottom


def _box(dims: tuple[int, int, int, int, int, int]) -> _Box:
    return _Box(*dims)


def _svg_escape(text: str) -> str:
    return escape(text, quote=True)


def _axis_max(values: list[float]) -> float:
    peak = max(values, default=0.0)
    if peak <= 0:
        return 1.0
    return peak * _HEADROOM


def _fmt_tick(value: float) -> str:
    text = f"{value:.2f}"
    if text.endswith(".00"):
        return text[:-3]
    return text


def _write_svg(path: Path, body: str, box: _Box) -> None:
    path.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{box.width}" height="{box.height}" '
        f'viewBox="0 0 {box.width} {box.height}">\n{body}</svg>\n',
        encoding="utf-8",
    )


def _chart_frame(box: _Box, title: str, xlabel: str, ylabel: str, y_max: float) -> str:
    plot_w = box.plot_w
    plot_h = box.plot_h
    y_mid = box.top + plot_h / 2
    parts: list[str] = [
        f'<rect width="{box.width}" height="{box.height}" fill="#ffffff"/>',
        (
            f'<text x="{box.width / 2:.1f}" y="24" text-anchor="middle" '
            f'font-family="{_FONT}" font-size="14" font-weight="bold">'
            f"{_svg_escape(title)}</text>"
        ),
        (
            f'<text x="{box.left + plot_w / 2:.1f}" y="{box.height - 10}" text-anchor="middle" '
            f'font-family="{_FONT}" font-size="11">{_svg_escape(xlabel)}</text>'
        ),
        (
            f'<text x="16" y="{y_mid:.1f}" text-anchor="middle" '
            f'transform="rotate(-90 16 {y_mid:.1f})" '
            f'font-family="{_FONT}" font-size="11">{_svg_escape(ylabel)}</text>'
        ),
        (
            f'<rect x="{box.left}" y="{box.top}" width="{plot_w}" height="{plot_h}" '
            f'fill="none" stroke="#333333" stroke-width="0.8"/>'
        ),
    ]
    for i in range(_Y_TICKS + 1):
        frac = i / _Y_TICKS
        y = box.top + plot_h * (1 - frac)
        value = y_max * frac
        parts.append(
            f'<line x1="{box.left}" y1="{y:.1f}" x2="{box.left + plot_w}" y2="{y:.1f}" '
            f'stroke="#333333" stroke-dasharray="4 4" stroke-opacity="0.35"/>'
        )
        parts.append(
            f'<text x="{box.left - 6}" y="{y + 3:.1f}" text-anchor="end" '
            f'font-family="{_FONT}" font-size="9">{_svg_escape(_fmt_tick(value))}</text>'
        )
    return "\n".join(parts) + "\n"


def _require_parallel(left: int, right: int, what: str) -> None:
    if left != right or left == 0:
        sys.exit(f"{what} must be non-empty and parallel")


def _write_line_chart(path: Path, ys: list[float], x_labels: list[str], title: str) -> None:
    _require_parallel(len(ys), len(x_labels), "line chart values and labels")
    box = _box(_LINE_BOX)
    y_max = _axis_max(ys)
    frame = _chart_frame(
        box, title, "Active Cluster Nodes (Count)", "Total Query Latency (ms)", y_max
    )
    n = len(ys)
    span = n - 1 if n > 1 else 1
    pts: list[str] = []
    extras: list[str] = []
    for i, y in enumerate(ys):
        px = box.left + (i / span) * box.plot_w
        py = box.top + box.plot_h * (1 - y / y_max)
        pts.append(f"{px:.1f},{py:.1f}")
        extras.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="4" fill="#1f77b4"/>')
        extras.append(
            f'<text x="{px:.1f}" y="{box.top + box.plot_h + 16}" text-anchor="middle" '
            f'font-family="{_FONT}" font-size="10">{_svg_escape(x_labels[i])}</text>'
        )
    body = (
        frame
        + f'<polyline fill="none" stroke="#1f77b4" stroke-width="2.2" points="{" ".join(pts)}"/>\n'
        + "\n".join(extras)
        + "\n"
    )
    _write_svg(path, body, box)


def _write_bar_chart(
    path: Path,
    labels: list[str],
    values: list[float],
    colors: list[str],
    title: str,
) -> None:
    _require_parallel(len(labels), len(values), "bar chart labels and values")
    _require_parallel(len(colors), len(values), "bar chart colors and values")
    box = _box(_TIER_BOX if path.name.startswith("fig3_") else _BAR_BOX)
    xlabel = "" if path.name.startswith("fig3_") else "Piece Chunk Size"
    ylabel = (
        "Fetch Latency per 4MB Block (ms)"
        if path.name.startswith("fig3_")
        else "Transfer Throughput (MB/s)"
    )
    value_fmt = "{:.2f} ms" if path.name.startswith("fig3_") else "{:.0f} MB/s"
    y_max = _axis_max(values)
    frame = _chart_frame(box, title, xlabel, ylabel, y_max)
    n = len(values)
    slot = box.plot_w / n
    bar_w = slot * _BAR_FRACTION
    extras: list[str] = []
    for i, (label, value, color) in enumerate(zip(labels, values, colors, strict=True)):
        bh = box.plot_h * (value / y_max)
        x = box.left + i * slot + (slot - bar_w) / 2
        y = box.top + box.plot_h - bh
        extras.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w:.1f}" height="{bh:.1f}" '
            f'fill="{_svg_escape(color)}" stroke="#333333" stroke-width="0.8"/>'
        )
        extras.append(
            f'<text x="{x + bar_w / 2:.1f}" y="{y - 6:.1f}" text-anchor="middle" '
            f'font-family="{_FONT}" font-size="8" font-weight="bold">'
            f"{_svg_escape(value_fmt.format(value))}</text>"
        )
        extras.append(
            f'<text x="{x + bar_w / 2:.1f}" y="{box.top + box.plot_h + 16}" text-anchor="middle" '
            f'font-family="{_FONT}" font-size="10">{_svg_escape(label)}</text>'
        )
    _write_svg(path, frame + "\n".join(extras) + "\n", box)


def plot_figures(
    node_counts: list[int],
    latencies_ms: list[float],
    chunk_labels: list[str],
    throughputs_mbps: list[float],
    out_dir: Path,
) -> None:
    print("=== Plotting figures ===")
    figures_dir = out_dir / "figures"
    figures_dir.mkdir(parents=True, exist_ok=True)

    fig1_path = figures_dir / "fig1_cluster_latency_scaling.svg"
    _write_line_chart(
        fig1_path,
        latencies_ms,
        [str(n) for n in node_counts],
        "modelfs Cluster Endpoint Query Latency Scaling",
    )
    print(f"Saved Figure 1: {fig1_path}")

    fig2_path = figures_dir / "fig2_throughput_vs_piece_size.svg"
    _write_bar_chart(
        fig2_path,
        chunk_labels,
        throughputs_mbps,
        ["#2ca02c"] * len(throughputs_mbps),
        "modelfs Zero-Copy HTTP Piece Throughput Across Chunk Sizes",
    )
    print(f"Saved Figure 2: {fig2_path}")

    # Illustrative design targets, not measured here; the report says so too.
    tiers = ["Local NVMe Cache", "Peer HTTP (Sendfile)", "NFS Origin Fallback"]
    tier_latencies = [0.15, 0.65, 8.5]
    fig3_path = figures_dir / "fig3_tier_latency_comparison.svg"
    _write_bar_chart(
        fig3_path,
        tiers,
        tier_latencies,
        ["#1f77b4", "#ff7f0e", "#d62728"],
        "modelfs Block Fetch Latency by Storage Tier (illustrative)",
    )
    print(f"Saved Figure 3: {fig3_path}")


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

![Query latency vs cluster size](figures/fig1_cluster_latency_scaling.svg)

## 2. Throughput vs piece size

Zero-copy `sendfile` streaming:

| Piece | Throughput |
|---|---|
{sweep_table}

Throughput climbs with piece size and then wobbles, which is per-request fixed
cost being amortised against page-cache and socket-buffer effects rather than a
clean curve. 16 MiB is the default piece: past it the gain is small, and a miss
costs the reader the whole piece before the read returns.

![Throughput vs piece size](figures/fig2_throughput_vs_piece_size.svg)

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

![Tier latency comparison](figures/fig3_tier_latency_comparison.svg)
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
    out_dir = _ROOT / "docs" if args.update_docs else _SCRATCH / "benchmarks"
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
    print("=== Benchmarks complete ===")


if __name__ == "__main__":
    main()
