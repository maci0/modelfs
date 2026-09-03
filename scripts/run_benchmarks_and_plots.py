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
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from html import escape
from pathlib import Path
from typing import override

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
    # Absolute path of this tree's pinned interpreter; argv is that path plus
    # this script. os.execv is the no-shell form (S605 would be the risk).
    os.execv(  # noqa: S606 -- argv is the absolute venv interpreter path
        os.fspath(_VENV_PYTHON), [os.fspath(_VENV_PYTHON), _SCRIPT, *sys.argv[1:]]
    )


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
    helper = shutil.which("fusermount3") or shutil.which("fusermount") or shutil.which("umount")
    if helper is None:
        return
    # argv is a resolved helper plus fixed -u; no shell, no user input.
    subprocess.run([helper, "-u", mount_dir], capture_output=True, check=False)  # noqa: S603 -- resolved helper path, fixed args, no shell


def stop_mount(p: subprocess.Popen[bytes], mount_dir: str) -> None:
    """Tear down one benchmark mount daemon on every exit path.

    terminate() without wait() would leave an unreaped child holding its peer
    port and FUSE mount until interpreter exit; a skipped teardown (benchmark
    mismatch or HTTP failure) would orphan the daemon across runs.
    """
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
    unmount(mount_dir)


@dataclass(slots=True)
class _MountSpec:
    mount_dir: str
    cache_dir: str
    node_id: str
    port: int
    piece: str


def start_mount(
    bin_path: str, origin_dir: str, psk_file: str, spec: _MountSpec
) -> subprocess.Popen[bytes]:
    # argv is this tree's zig-out binary plus fixed mount flags.
    return subprocess.Popen(  # noqa: S603 -- resolved binary path, fixed mount flags, no shell
        [
            bin_path,
            "mount",
            spec.mount_dir,
            "--origin",
            origin_dir,
            "--cache",
            spec.cache_dir,
            "--id",
            spec.node_id,
            "--listen",
            f"127.0.0.1:{spec.port}",
            "--psk",
            psk_file,
            "--piece",
            spec.piece,
        ]
    )


def build_modelfs() -> str:
    print("=== Building modelfs binary ===")
    # ReleaseFast: these figures document the daemon operators run (README
    # builds -Doptimize=ReleaseFast). A Debug build carries full safety checks
    # and no optimization, inflating per-request fixed cost and understating
    # sendfile throughput; the piece-size sweep's shape depends on exactly
    # that fixed cost.
    zig = shutil.which("zig")
    if zig is None:
        sys.exit("zig not found on PATH -- see CONTRIBUTING.md")
    # argv is the resolved zig binary plus fixed build flags; no shell.
    res = subprocess.run(  # noqa: S603 -- resolved zig binary, fixed build flags, no shell
        [zig, "build", "-Doptimize=ReleaseFast"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        cwd=_ROOT,
    )
    if res.returncode != 0:
        print("Build failed:", res.stderr, file=sys.stderr)
        sys.exit(1)
    bin_path = _ROOT / "zig-out" / "bin" / "modelfs"
    if not bin_path.is_file():
        sys.exit(f"Binary missing at {bin_path}")
    return os.fspath(bin_path)


def make_origin_and_psk(temp_dir: str) -> tuple[str, str]:
    """Fresh empty origin dir plus a 0600 PSK file for one benchmark run."""
    origin_dir = Path(temp_dir) / "origin"
    psk_file = Path(temp_dir) / "modelfs.psk"
    origin_dir.mkdir(parents=True, exist_ok=True)
    # UTF-8 named: this file is the daemon's --psk input, read back byte-exact
    # by the verifier and trimmed to " \t\r\n" on both sides.
    with psk_file.open("w", encoding="utf-8") as f:
        f.write(BENCH_PSK + "\n")
    psk_file.chmod(0o600)
    return os.fspath(origin_dir), os.fspath(psk_file)


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
        # through the loop (mkdir/Popen raising) must still tear down every
        # daemon already started, not orphan it with its FUSE mount and port.
        try:
            for i in range(1, 10):
                cache_dir = Path(temp_dir) / f"cache_{i}"
                mount_dir = Path(temp_dir) / f"mount_{i}"
                cache_dir.mkdir(parents=True, exist_ok=True)
                mount_dir.mkdir(parents=True, exist_ok=True)
                port = 19100 + i
                p = start_mount(
                    bin_path,
                    origin_dir,
                    psk_file,
                    _MountSpec(
                        os.fspath(mount_dir),
                        os.fspath(cache_dir),
                        f"node_{i}",
                        port,
                        "4M",
                    ),
                )
                procs.append((p, port, os.fspath(mount_dir)))

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
                    with peer_ping.open_http(req, timeout=30) as resp:
                        body = resp.read()
                    if body != b"ok":
                        sys.exit(f"node on port {port}: /ping answered with an unexpected body")
                t1 = time.monotonic()
                elapsed_ms = round((t1 - t0) * 1000.0, 2)
                latencies_ms.append(elapsed_ms)
                print(f"  Nodes: {num_nodes} -> Total Latency: {elapsed_ms} ms")
        finally:
            # Every spawned mount daemon must die even when a spawn or probe
            # raises; otherwise orphans hold ports and stale FUSE mounts.
            for p, _, mount_dir_str in procs:
                stop_mount(p, mount_dir_str)

        return node_counts, latencies_ms
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def run_throughput_vs_piece_size_benchmark(bin_path: str) -> tuple[list[str], list[float]]:
    print("=== Benchmark 2: throughput vs piece size ===")
    _SCRATCH.mkdir(parents=True, exist_ok=True)
    temp_dir = tempfile.mkdtemp(prefix="bench-size-", dir=_SCRATCH)
    try:
        origin_dir, psk_file = make_origin_and_psk(temp_dir)

        chunk_configs = _PIECE_CONFIGS

        chunk_labels = [c[0] for c in chunk_configs]
        throughputs_mbps = []

        for idx, (label, bytes_len) in enumerate(chunk_configs):
            test_file = f"test_{label}.bin"
            file_path = Path(origin_dir) / test_file

            data = os.urandom(bytes_len)
            with file_path.open("wb") as f:
                f.write(data)

            cache_dir = Path(temp_dir) / f"cache_{idx}"
            mount_dir = Path(temp_dir) / f"mount_{idx}"
            cache_dir.mkdir(parents=True, exist_ok=True)
            mount_dir.mkdir(parents=True, exist_ok=True)
            port = 19600 + idx
            p = start_mount(
                bin_path,
                origin_dir,
                psk_file,
                _MountSpec(
                    os.fspath(mount_dir),
                    os.fspath(cache_dir),
                    f"node_size_{label}",
                    port,
                    label,
                ),
            )
            try:
                # The daemon must be serving before hydration and the timed
                # fetch; poll its /ping instead of sleeping a constant.
                headers = bench_headers()
                peer_ping.wait_for_ping(port, headers, 30.0)

                mount_file_path = mount_dir / test_file
                if mount_file_path.exists():
                    with mount_file_path.open("rb") as mf:
                        _ = mf.read(1024)

                path_enc = urllib.parse.quote(test_file, safe="")
                data_url = f"http://127.0.0.1:{port}/data?path={path_enc}"
                req = urllib.request.Request(
                    data_url,
                    headers={**headers, "Range": f"bytes=0-{len(data) - 1}"},
                )

                t0 = time.monotonic()
                with peer_ping.open_http(req, timeout=30) as resp:
                    got_data = resp.read()
                t1 = time.monotonic()

                if len(got_data) != len(data):
                    sys.exit(
                        f"Data size mismatch for {label}: got {len(got_data)}, want {len(data)}"
                    )
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
                stop_mount(p, os.fspath(mount_dir))

        return chunk_labels, throughputs_mbps
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def _best_of(reps: int, fn: Callable[[], None]) -> float:
    """Smallest elapsed wall time of `reps` runs: one-shot timing on a
    shared host records warmup noise as a real slowdown, so every timed
    benchmark here takes the best of a few identical passes."""
    best = float("inf")
    for _ in range(reps):
        t0 = time.monotonic()
        fn()
        best = min(best, time.monotonic() - t0)
    return best


def _drain_read(path: Path, chunk: int = 1024 * 1024) -> None:
    with path.open("rb") as f:
        while f.read(chunk):
            pass


def _copy_through(src: Path, dst: Path, chunk: int = 1024 * 1024) -> None:
    with src.open("rb") as src_f, dst.open("wb") as dst_f:
        while True:
            block = src_f.read(chunk)
            if not block:
                break
            dst_f.write(block)


def _fetch_span(port: int, headers: dict[str, str], span_bytes: int, label: str) -> None:
    """One peer-style range fetch of the first `span_bytes` of big.bin."""
    path_enc = urllib.parse.quote("big.bin", safe="")
    data_url = f"http://127.0.0.1:{port}/data?path={path_enc}"
    req = urllib.request.Request(
        data_url, headers={**headers, "Range": f"bytes=0-{span_bytes - 1}"}
    )
    with peer_ping.open_http(req, timeout=60) as resp:
        got = 0
        while True:
            block = resp.read(1024 * 1024)
            if not block:
                break
            got += len(block)
    if got != span_bytes:
        sys.exit(f"span size mismatch for {label}: {got}")


@dataclass(slots=True)
class _EngineSweep:
    """Everything one engine-sweep config needs beyond its piece size."""

    bin_path: str
    origin_dir: str
    psk_file: str
    temp_dir: str
    file_mib: int
    span_bytes: int


def _measure_engine_config(
    sweep: _EngineSweep,
    idx: int,
    cfg: tuple[str, int],
) -> tuple[float, float, float]:
    label = cfg[0]
    """One piece-size point of the engine sweep: mount a fresh daemon, warm
    the cache with one full read, then time (read, write-through, HTTP span)
    as best-of-N MB/s. Fresh cache per point: a sidecar written under a
    different piece grid is discarded on load."""
    cache_dir = Path(sweep.temp_dir) / f"cache_{idx}"
    mount_dir = Path(sweep.temp_dir) / f"mount_{idx}"
    cache_dir.mkdir(parents=True, exist_ok=True)
    mount_dir.mkdir(parents=True, exist_ok=True)
    port = 19700 + idx
    p = start_mount(
        sweep.bin_path,
        sweep.origin_dir,
        sweep.psk_file,
        _MountSpec(
            os.fspath(mount_dir),
            os.fspath(cache_dir),
            f"node_engine_{label}",
            port,
            label,
        ),
    )
    try:
        headers = bench_headers()
        peer_ping.wait_for_ping(port, headers, 30.0)

        mounted_big = mount_dir / "big.bin"
        # Cold pass: hydrate every piece once so the timed read is the warm
        # NVMe path, not the origin fill.
        _drain_read(mounted_big)
        r_sec = _best_of(2, lambda: _drain_read(mounted_big))

        out = mount_dir / "written.bin"
        big = Path(sweep.origin_dir) / "big.bin"
        w_sec = _best_of(2, lambda: _copy_through(big, out))
        out.unlink(missing_ok=True)

        h_sec = _best_of(3, lambda: _fetch_span(port, headers, sweep.span_bytes, label))

        return (
            round(sweep.file_mib / max(r_sec, 0.0001), 2),
            round(sweep.file_mib / max(w_sec, 0.0001), 2),
            round((sweep.span_bytes / (1024.0 * 1024.0)) / max(h_sec, 0.0001), 2),
        )
    finally:
        stop_mount(p, os.fspath(mount_dir))


def run_engine_io_vs_piece_size_benchmark(
    bin_path: str,
) -> tuple[list[str], list[float], list[float], list[float]]:
    """Engine-shaped I/O against a real multi-piece file, across piece
    sizes: warm read and write-through through the FUSE mount (what
    llama.cpp and vLLM actually do), plus a peer-style HTTP range fetch of
    a 64 MiB span. The file is a fixed 256 MiB, decoupled from the piece
    size, so the sweep measures grid granularity rather than file size --
    the single-piece-per-file shape of Benchmark 2 cannot show that."""
    print("=== Benchmark 3: engine I/O vs piece size (256 MiB file) ===")
    _SCRATCH.mkdir(parents=True, exist_ok=True)
    temp_dir = tempfile.mkdtemp(prefix="bench-engine-", dir=_SCRATCH)
    sweep = _EngineSweep(
        bin_path=bin_path,
        origin_dir="",
        psk_file="",
        temp_dir=temp_dir,
        file_mib=256,
        span_bytes=64 * 1024 * 1024,
    )
    try:
        origin_dir, psk_file = make_origin_and_psk(temp_dir)
        sweep.origin_dir = origin_dir
        sweep.psk_file = psk_file
        # One 256 MiB incompressible file shared by every config: the origin
        # does not care about the piece grid, and regenerating 256 MiB of
        # urandom per point would only burn wall time.
        big_src = Path(origin_dir) / "big.bin"
        seed = os.urandom(4 * 1024 * 1024)
        with big_src.open("wb") as f:
            for _ in range(sweep.file_mib // 4):
                f.write(seed)

        labels = [c[0] for c in _PIECE_CONFIGS]
        read_mbps: list[float] = []
        write_mbps: list[float] = []
        http_mbps: list[float] = []

        for idx, cfg in enumerate(_PIECE_CONFIGS):
            label = cfg[0]
            r, w, h = _measure_engine_config(sweep, idx, cfg)
            read_mbps.append(r)
            write_mbps.append(w)
            http_mbps.append(h)
            print(
                f"  Piece size: {label:>4} -> warm read {r:>7.2f} MB/s, "
                f"write-through {w:>7.2f} MB/s, HTTP span {h:>7.2f} MB/s"
            )

        return labels, read_mbps, write_mbps, http_mbps
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


# The piece-size sweep both measured sweeps walk. 128M and 256M sit past the
# 16M default to show where bigger chunks stop paying; every entry is a legal
# --piece value (parseSize accepts 1024-based K/M/G up to u32 max bytes).
_PIECE_CONFIGS = [
    ("256K", 256 * 1024),
    ("512K", 512 * 1024),
    ("1M", 1 * 1024 * 1024),
    ("2M", 2 * 1024 * 1024),
    ("4M", 4 * 1024 * 1024),
    ("8M", 8 * 1024 * 1024),
    ("16M", 16 * 1024 * 1024),
    ("32M", 32 * 1024 * 1024),
    ("64M", 64 * 1024 * 1024),
    ("128M", 128 * 1024 * 1024),
    ("256M", 256 * 1024 * 1024),
]

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


@dataclass(slots=True)
class _BarSpec:
    title: str
    box: _Box
    xlabel: str
    ylabel: str
    value_fmt: str


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
    box = _Box(*_LINE_BOX)
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


@dataclass(slots=True)
class _TwoSeriesSpec:
    """Labels and layout for _write_two_line_chart, mirroring _BarSpec."""

    title: str
    xlabel: str
    ylabel: str
    legend_a: str
    legend_b: str


def _write_two_line_chart(
    path: Path,
    ys_a: list[float],
    ys_b: list[float],
    x_labels: list[str],
    spec: _TwoSeriesSpec,
) -> None:
    """Two series over the same x positions, blue and green with a small
    legend, in the same hand-rendered style as the other charts."""
    _require_parallel(len(ys_a), len(x_labels), "line chart series A and labels")
    _require_parallel(len(ys_b), len(x_labels), "line chart series B and labels")
    box = _Box(*_LINE_BOX)
    y_max = _axis_max(ys_a + ys_b)
    frame = _chart_frame(box, spec.title, spec.xlabel, spec.ylabel, y_max)
    n = len(x_labels)
    span = n - 1 if n > 1 else 1

    def pts_of(ys: list[float]) -> list[str]:
        out: list[str] = []
        for i, y in enumerate(ys):
            px = box.left + (i / span) * box.plot_w
            py = box.top + box.plot_h * (1 - y / y_max)
            out.append(f"{px:.1f},{py:.1f}")
        return out

    dots_a: list[str] = []
    dots_b: list[str] = []
    for i, (ya, yb) in enumerate(zip(ys_a, ys_b, strict=True)):
        px = box.left + (i / span) * box.plot_w
        pa = box.top + box.plot_h * (1 - ya / y_max)
        pb = box.top + box.plot_h * (1 - yb / y_max)
        dots_a.append(f'<circle cx="{px:.1f}" cy="{pa:.1f}" r="4" fill="#1f77b4"/>')
        dots_b.append(f'<circle cx="{px:.1f}" cy="{pb:.1f}" r="4" fill="#2ca02c"/>')
        dots_b.append(
            f'<text x="{px:.1f}" y="{box.top + box.plot_h + 16}" text-anchor="middle" '
            f'font-family="{_FONT}" font-size="10">{_svg_escape(x_labels[i])}</text>'
        )
    # Legend top-right inside the plot: two swatch lines and labels.
    lx = box.left + box.plot_w - 220
    legend_a_svg = _svg_escape(spec.legend_a)
    legend_b_svg = _svg_escape(spec.legend_b)
    legend = (
        f'<line x1="{lx}" y1="{box.top + 14}" x2="{lx + 28}" y2="{box.top + 14}" '
        f'stroke="#1f77b4" stroke-width="2.2"/>'
        f'<text x="{lx + 34}" y="{box.top + 18}" font-family="{_FONT}" '
        f'font-size="10">{legend_a_svg}</text>'
        f'<line x1="{lx}" y1="{box.top + 32}" x2="{lx + 28}" y2="{box.top + 32}" '
        f'stroke="#2ca02c" stroke-width="2.2"/>'
        f'<text x="{lx + 34}" y="{box.top + 36}" font-family="{_FONT}" '
        f'font-size="10">{legend_b_svg}</text>'
    )
    nl = chr(10)
    pts_a = " ".join(pts_of(ys_a))
    pts_b = " ".join(pts_of(ys_b))
    dots = nl.join(dots_a + dots_b)
    body = (
        frame
        + f'<polyline fill="none" stroke="#1f77b4" stroke-width="2.2" points="{pts_a}"/>'
        + nl
        + f'<polyline fill="none" stroke="#2ca02c" stroke-width="2.2" points="{pts_b}"/>'
        + nl
        + dots
        + nl
        + legend
        + nl
    )
    _write_svg(path, body, box)


def _write_bar_chart(
    path: Path,
    labels: list[str],
    values: list[float],
    colors: list[str],
    spec: _BarSpec,
) -> None:
    _require_parallel(len(labels), len(values), "bar chart labels and values")
    _require_parallel(len(colors), len(values), "bar chart colors and values")
    box = spec.box
    y_max = _axis_max(values)
    frame = _chart_frame(box, spec.title, spec.xlabel, spec.ylabel, y_max)
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
            f"{_svg_escape(spec.value_fmt.format(value))}</text>"
        )
        extras.append(
            f'<text x="{x + bar_w / 2:.1f}" y="{box.top + box.plot_h + 16}" text-anchor="middle" '
            f'font-family="{_FONT}" font-size="10">{_svg_escape(label)}</text>'
        )
    _write_svg(path, frame + "\n".join(extras) + "\n", box)


@dataclass(slots=True)
class BenchmarkResults:
    """Everything one full run measured, handed to the plotter and report."""

    node_counts: list[int]
    latencies_ms: list[float]
    chunk_labels: list[str]
    chunk_throughputs_mbps: list[float]
    engine_labels: list[str]
    engine_read_mbps: list[float]
    engine_write_mbps: list[float]
    engine_http_mbps: list[float]


def plot_figures(results: BenchmarkResults, out_dir: Path) -> None:
    print("=== Plotting figures ===")
    figures_dir = out_dir / "figures"
    figures_dir.mkdir(parents=True, exist_ok=True)

    fig1_path = figures_dir / "fig1_cluster_latency_scaling.svg"
    _write_line_chart(
        fig1_path,
        results.latencies_ms,
        [str(n) for n in results.node_counts],
        "modelfs Cluster Endpoint Query Latency Scaling",
    )
    print(f"Saved Figure 1: {fig1_path}")

    fig2_path = figures_dir / "fig2_throughput_vs_piece_size.svg"
    _write_bar_chart(
        fig2_path,
        results.chunk_labels,
        results.chunk_throughputs_mbps,
        ["#2ca02c"] * len(results.chunk_throughputs_mbps),
        _BarSpec(
            "modelfs Zero-Copy HTTP Piece Throughput Across Chunk Sizes",
            _Box(*_BAR_BOX),
            "Piece Chunk Size",
            "Transfer Throughput (MB/s)",
            "{:.0f} MB/s",
        ),
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
        _BarSpec(
            "modelfs Block Fetch Latency by Storage Tier (illustrative)",
            _Box(*_TIER_BOX),
            "",
            "Fetch Latency per 4MB Block (ms)",
            "{:.2f} ms",
        ),
    )
    print(f"Saved Figure 3: {fig3_path}")

    fig4_path = figures_dir / "fig4_engine_io_vs_piece_size.svg"
    _write_two_line_chart(
        fig4_path,
        results.engine_read_mbps,
        results.engine_write_mbps,
        results.engine_labels,
        _TwoSeriesSpec(
            "modelfs Warm Read and Write-Through vs Piece Size (256 MiB File)",
            "Piece Chunk Size",
            "Throughput (MB/s)",
            "Warm FUSE read",
            "Write-through",
        ),
    )
    print(f"Saved Figure 4: {fig4_path}")

    fig5_path = figures_dir / "fig5_http_span_vs_piece_size.svg"
    _write_bar_chart(
        fig5_path,
        results.engine_labels,
        results.engine_http_mbps,
        ["#ff7f0e"] * len(results.engine_http_mbps),
        _BarSpec(
            "modelfs Peer-Style HTTP 64 MiB Range Fetch vs Piece Size (256 MiB File)",
            _Box(*_BAR_BOX),
            "Piece Chunk Size",
            "Transfer Throughput (MB/s)",
            "{:.0f} MB/s",
        ),
    )
    print(f"Saved Figure 5: {fig5_path}")


def generate_report(results: BenchmarkResults, out_dir: Path) -> None:
    latency_table = "\n".join(
        f"| {n} | {ms} ms |"
        for n, ms in zip(results.node_counts, results.latencies_ms, strict=True)
    )
    sweep_table = "\n".join(
        f"| {label} | {mbps:.0f} MB/s |"
        for label, mbps in zip(results.chunk_labels, results.chunk_throughputs_mbps, strict=True)
    )
    engine_table = "\n".join(
        f"| {label} | {read:.0f} MB/s | {write:.0f} MB/s |"
        for label, read, write in zip(
            results.engine_labels,
            results.engine_read_mbps,
            results.engine_write_mbps,
            strict=True,
        )
    )
    span_table = "\n".join(
        f"| {label} | {mbps:.0f} MB/s |"
        for label, mbps in zip(results.engine_labels, results.engine_http_mbps, strict=True)
    )
    report_date = datetime.now(UTC).date().isoformat()
    report_content = f"""# Benchmarks

| Field | Value |
|---|---|
| Status | Generated by `scripts/run_benchmarks_and_plots.py`; edit that, not this file |
| Date | {report_date} |
| Topology | **{max(results.node_counts)} instances on one host, TCP loopback.** Not a cluster |

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

## 3. Engine I/O vs piece size

The shape engines actually produce: a fixed 256 MiB file (decoupled from the
piece size, so this sweep measures grid granularity rather than file size),
read warm through the FUSE mount after one hydrating pass, and rewritten
through the mount, timed per pass with the best of a few runs:

| Piece | Warm FUSE read | Write-through |
|---|---|---|
{engine_table}

Warm reads ride the host page cache and memory bandwidth, so they bound this
software rather than the disk and they wobble run to run. Write-through is the
stable line: the origin pwrite plus the cache copy dominate, and the piece
grid barely moves them at this file size.

![Engine I/O vs piece size](figures/fig4_engine_io_vs_piece_size.svg)

## 4. Peer-style HTTP range fetch vs piece size

A 64 MiB `Range` against the same 256 MiB file -- the transfer a fetching
peer issues -- across the same piece sizes:

| Piece | Throughput |
|---|---|
{span_table}

One file, many pieces. On this host the span slows as the piece grows -- the
opposite corner from Benchmark 2, where bigger single-piece files fetched
faster. Read the two sweeps together: piece size trades one-piece fetch speed
against streaming across a real file's grid, and the 16 MiB default is a
mid-curve choice, not a corner-case optimum.

![HTTP span vs piece size](figures/fig5_http_span_vs_piece_size.svg)

## 5. Tier comparison

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
    with report_path.open("w", encoding="utf-8") as f:
        f.write(report_content)
    print(f"✓ Generated Benchmark Report: {report_path}")


class _Parser(argparse.ArgumentParser):
    """argparse's usage line, capitalized to match the shell scripts."""

    @override
    def format_usage(self) -> str:
        return super().format_usage().replace("usage:", "Usage:", 1)

    @override
    def format_help(self) -> str:
        return super().format_help().replace("usage:", "Usage:", 1)


def main() -> None:
    reexec_under_venv()
    parser = _Parser(
        description="Run the modelfs benchmarks and render report + figures.",
    )
    parser.add_argument(
        "--update-docs",
        action="store_true",
        help="overwrite the tracked docs/benchmarks.md and docs/figures/ "
        "(default: write to .scratch/benchmarks/, since every run records "
        "the local machine's numbers)",
    )
    # Parse before the FUSE preflight so --help and unknown flags never
    # die as "cannot run benchmarks: /dev/fuse is missing".
    args = parser.parse_args()
    require_fuse()
    out_dir = _ROOT / "docs" if args.update_docs else _SCRATCH / "benchmarks"
    bin_path = build_modelfs()
    node_counts, latencies_ms = run_cluster_latency_benchmark(bin_path)
    chunk_labels, chunk_throughputs = run_throughput_vs_piece_size_benchmark(bin_path)
    e_labels, e_read, e_write, e_http = run_engine_io_vs_piece_size_benchmark(bin_path)
    results = BenchmarkResults(
        node_counts=node_counts,
        latencies_ms=latencies_ms,
        chunk_labels=chunk_labels,
        chunk_throughputs_mbps=chunk_throughputs,
        engine_labels=e_labels,
        engine_read_mbps=e_read,
        engine_write_mbps=e_write,
        engine_http_mbps=e_http,
    )
    plot_figures(results, out_dir)
    generate_report(results, out_dir)
    if not args.update_docs:
        print(
            f"Outputs in {out_dir} (gitignored): these are this machine's numbers. "
            "To regenerate the tracked docs/benchmarks.md and docs/figures/, rerun "
            "with --update-docs from representative hardware."
        )
    print("=== Benchmarks complete ===")


if __name__ == "__main__":
    main()
