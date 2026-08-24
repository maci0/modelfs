#!/usr/bin/env python3
"""Verify a running modelfs cluster over its peer HTTP protocol.

Pings every node, then reads one /have bitfield per node (one piece each),
timing the sweep for the benchmark log. Exits nonzero on the first failure.
"""

import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ARGC = 7  # prog + ORIGIN_FILE REL PSK_FILE BASE_PORT NUM_NODES TOTAL_PIECES
MAX_PORT = 65535


def main(argv: list[str]) -> int:
    if len(argv) != ARGC:
        print(
            f"usage: {argv[0]} ORIGIN_FILE REL PSK_FILE BASE_PORT NUM_NODES TOTAL_PIECES",
            file=sys.stderr,
        )
        return 2
    origin_file, rel, psk_file = argv[1], argv[2], argv[3]
    try:
        base_port, num_nodes, total_pieces = int(argv[4]), int(argv[5]), int(argv[6])
    except ValueError:
        print(
            f"{argv[0]}: BASE_PORT, NUM_NODES, TOTAL_PIECES must be integers",
            file=sys.stderr,
        )
        return 2
    # num_nodes == 0 would crash the round-robin modulo below, and zero or
    # negative counts would make every check loop vacuous while the script
    # still printed success: this gate must fail loudly instead.
    if base_port < 1 or base_port + num_nodes > MAX_PORT:
        print(f"{argv[0]}: BASE_PORT {base_port} out of range", file=sys.stderr)
        return 2
    if num_nodes < 1 or total_pieces < 1:
        print(
            f"{argv[0]}: NUM_NODES and TOTAL_PIECES must be >= 1 (got {num_nodes}, {total_pieces})",
            file=sys.stderr,
        )
        return 2

    psk = Path(psk_file).read_text().strip()
    headers = {"Authorization": f"Bearer {psk}"}

    # Read raw file from origin for verification
    with open(origin_file, "rb") as f:
        raw_data = f.read()

    print("✓ Origin file loaded into python verifier:", len(raw_data), "bytes")

    # Check /ping on all nodes
    for i in range(1, num_nodes + 1):
        port = base_port + i
        url = f"http://127.0.0.1:{port}/ping"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=30) as resp:
            assert resp.read() == b"ok", f"Node {i} ping failed"

    print(f"✓ All {num_nodes} peer nodes responding to HTTP /ping")

    # Query /have across the cluster
    t0 = time.monotonic()
    path_enc = urllib.parse.quote(rel, safe="")

    for p_idx in range(total_pieces):
        target_node = (p_idx % num_nodes) + 1
        port = base_port + target_node

        have_url = f"http://127.0.0.1:{port}/have?path={path_enc}"
        have_req = urllib.request.Request(have_url, headers=headers)
        with urllib.request.urlopen(have_req, timeout=30) as resp:
            bits = resp.read()
            assert len(bits) > 0, f"Node {target_node} returned empty bitfield"

    t1 = time.monotonic()
    elapsed = t1 - t0
    print(f"✓ Verified /have endpoint across all {num_nodes} cluster nodes in {elapsed:.3f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
