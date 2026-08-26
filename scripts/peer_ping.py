#!/usr/bin/env python3
"""Shared /ping readiness probe for modelfs daemons' peer HTTP protocol.

The benchmark driver and the cluster verifier both poll daemons before they
measure or assert, and both need the same policy: a fixed startup sleep is a
guess nine concurrent FUSE mounts on a loaded host can outrun, an answered
rejection (wrong PSK, 5xx) fails immediately because retrying cannot fix it,
and only dial noise (nothing listening yet) is retried against one budget.
One module here owns that policy so the two callers cannot drift apart.
"""

import sys
import time
import urllib.error
import urllib.request

PING_BODY = b"ok"
REQUEST_TIMEOUT_S = 30.0
RETRY_INTERVAL_S = 0.2


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
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S) as resp:
            # urllib's response object types read() as Any; narrow by check,
            # not cast, so a non-bytes answer cannot ride into the comparison.
            body = resp.read()
            assert isinstance(body, bytes)
            return body
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
            assert body == PING_BODY, f"Node on port {port} answered /ping with an unexpected body"
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
