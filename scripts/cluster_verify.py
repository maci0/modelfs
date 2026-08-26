#!/usr/bin/env python3
"""Verify a running modelfs cluster over its peer HTTP protocol.

Pings every node, then reads /have bitfields round-robin across the nodes
(one per piece, cycling pieces over nodes) while timing the sweep for the
benchmark log. Exits nonzero on the first failure.
"""

import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ARGC = 7  # prog + ORIGIN_FILE REL PSK_FILE BASE_PORT NUM_NODES TOTAL_PIECES
MAX_PORT = 65535
READY_TIMEOUT_S = 30.0


def wait_until_peers_ready(base_port: int, num_nodes: int, headers: dict[str, str]) -> None:
    """Poll every node's /ping until all answer, or fail after a fixed budget.

    The caller's startup sleep is only a guess: nine concurrent FUSE mounts
    on a loaded host can bind later than any constant, and one refused
    connection would kill the whole verification run with ConnectionRefused.
    A node that answers but rejects (wrong PSK, server error) fails
    immediately; retrying cannot fix that.
    """
    pending = [base_port + i for i in range(1, num_nodes + 1)]
    deadline = time.monotonic() + READY_TIMEOUT_S
    while pending:
        port = pending[0]
        url = f"http://127.0.0.1:{port}/ping"
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
                    f"{READY_TIMEOUT_S:.0f}s (daemon failed to start or died)"
                )
            time.sleep(0.2)
        else:
            pending.pop(0)
    print(f"✓ All {num_nodes} peer nodes responding to HTTP /ping")


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

    # The PSK crosses to the daemon as raw bytes (main.zig loadPsk reads the
    # file undecoded and trims exactly b" \t\r\n"), so this side must too:
    # a locale-default read_text() would crash on a binary key file or
    # re-encode it under a legacy locale, and str.strip()'s wider
    # Unicode-whitespace set would drop bytes (\v, \f) the daemon keeps as
    # part of the secret, turning every request into a 401. latin-1 is the
    # HTTP/1.1 header codec (http.client re-encodes it verbatim), so the
    # token reaches the wire byte-exact.
    token = b"Bearer " + Path(psk_file).read_bytes().strip(b" \t\r\n")
    headers = {"Authorization": token.decode("latin-1")}

    # Read raw file from origin for verification
    with open(origin_file, "rb") as f:
        raw_data = f.read()

    print("✓ Origin file loaded into python verifier:", len(raw_data), "bytes")

    # Wait for every node's listener instead of assuming the spawner's
    # startup sleep was long enough, then start the timed sweep.
    wait_until_peers_ready(base_port, num_nodes, headers)

    # Query /have across the cluster
    t0 = time.monotonic()
    # Paths are bytes on the daemon side (relOk passes non-UTF-8 names
    # through byte-exact), so encode from the raw argv bytes: os.fsencode
    # reverses surrogateescape back to the original octets, and
    # quote_from_bytes percent-encodes each one. quote(rel) on the str
    # would raise UnicodeEncodeError on a legal non-UTF-8 file name.
    path_enc = urllib.parse.quote_from_bytes(os.fsencode(rel), safe="")

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
