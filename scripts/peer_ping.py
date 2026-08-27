#!/usr/bin/env python3
"""Shared /ping readiness probe for modelfs daemons' peer HTTP protocol.

The benchmark driver and the cluster verifier both poll daemons before they
measure or assert, and both need the same policy: a fixed startup sleep is a
guess nine concurrent FUSE mounts on a loaded host can outrun, an answered
rejection (wrong PSK, 5xx) fails immediately because retrying cannot fix it,
and only dial noise (nothing listening yet) is retried against one budget.
open_http is the one urlopen: http(s) only, so a file: URL cannot sneak
through a probe. Callers share both so the policy cannot drift apart.
"""

import sys
import time
import urllib.error
import urllib.request
from http.client import HTTPResponse

PING_BODY = b"ok"
REQUEST_TIMEOUT_S = 30.0
RETRY_INTERVAL_S = 0.2


def open_http(req: urllib.request.Request, timeout: float) -> HTTPResponse:
    """urlopen restricted to http(s); file: and custom schemes are refused."""
    url = req.full_url
    if not url.startswith(("http://", "https://")):
        sys.exit(f"refusing non-http URL {url!r}")
    # Bandit S310 flags every urlopen; the scheme gate above is the audit.
    resp = urllib.request.urlopen(req, timeout=timeout)  # noqa: S310
    if not isinstance(resp, HTTPResponse):
        sys.exit(f"expected HTTPResponse, got {type(resp).__name__}")
    return resp


def _ping_once(port: int, headers: dict[str, str]) -> bytes | None:
    """One /ping request: the body when the node answers, else None.

    An HTTP-level answer is final either way -- a rejection exits here,
    naming the node and status, because no amount of retrying turns a wrong
    PSK or a server error into a ready node. Dial noise (refused connection,
    timeout before a listener exists) returns None for the caller's budget
    loop to decide on.
    """
    req = urllib.request.Request(f"http://127.0.0.1:{port}/ping", headers=headers)
    try:
        with open_http(req, timeout=REQUEST_TIMEOUT_S) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"node on port {port}: /ping rejected with HTTP {e.code}")
    except OSError:
        return None


def wait_for_ping(port: int, headers: dict[str, str], timeout_s: float) -> None:
    """Poll one node's /ping until it answers ok, or fail after timeout_s."""
    deadline = time.monotonic() + timeout_s
    while True:
        body = _ping_once(port, headers)
        if body is not None:
            if body != PING_BODY:
                sys.exit(f"node on port {port}: /ping answered with an unexpected body")
            return
        if time.monotonic() >= deadline:
            sys.exit(
                f"node on port {port}: no working listener within "
                f"{timeout_s:.0f}s (daemon failed to start or died)"
            )
        time.sleep(RETRY_INTERVAL_S)


def wait_for_peers_ready(ports: list[int], headers: dict[str, str], timeout_s: float) -> None:
    """Poll every node's /ping until all have answered, under one budget.

    The budget is shared across the whole list, so nodes that come up late
    shrink what the remaining ones may wait -- the total never exceeds
    timeout_s, whichever port ends up named in the failure.
    """
    deadline = time.monotonic() + timeout_s
    for port in ports:
        wait_for_ping(port, headers, max(deadline - time.monotonic(), 0.0))


def main(argv: list[str]) -> int:
    """Direct invocation is not a probe: this file is imported by the other CLIs."""
    help_only = argv[1:] == ["-h"] or argv[1:] == ["--help"]
    print(
        "Usage: import peer_ping from cluster_verify.py or "
        "run_benchmarks_and_plots.py (not a standalone command)",
        file=sys.stdout if help_only else sys.stderr,
    )
    return 0 if help_only else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
