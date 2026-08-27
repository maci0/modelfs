#!/usr/bin/env python3
"""Probe a modelfs peer /ping endpoint with a deliberately wrong bearer token.

Exits 0 (with a SKIP line) when no peer is listening, so a suite without a
running cluster is never counted as a pass or a failure; exits 1 when the
peer fails to reject the unauthenticated request.
"""

import sys
import urllib.error
import urllib.request

import peer_ping

HTTP_UNAUTHORIZED = 401
ARGC = 3  # prog + HOST PORT


def main(argv: list[str]) -> int:
    help_only = argv[1:] == ["-h"] or argv[1:] == ["--help"]
    if help_only or len(argv) != ARGC:
        print(
            f"usage: {argv[0]} HOST PORT",
            file=sys.stdout if help_only else sys.stderr,
        )
        return 0 if help_only else 2
    host, port = argv[1], argv[2]
    url = f"http://{host}:{port}/ping"
    headers = {"Authorization": "Bearer WRONG_TOKEN"}
    req = urllib.request.Request(url, headers=headers)
    try:
        # Same 30s budget as the other script probes: a peer that accepts but
        # never answers must fail the probe, not hang the suite.
        with peer_ping.open_http(req, timeout=30):
            pass
    except urllib.error.HTTPError as e:
        if e.code != HTTP_UNAUTHORIZED:
            print(f"Error: Expected 401, got {e.code}", file=sys.stderr)
            return 1
        print("✓ rejected invalid PSK with HTTP 401")
        return 0
    except urllib.error.URLError as e:
        reason = getattr(e, "reason", e)
        if isinstance(reason, ConnectionRefusedError) or "refused" in str(reason).lower():
            print(f"SKIP: no modelfs peer listening on {host}:{port}; start a cluster first")
            return 0
        print(f"Error: unexpected URL failure: {e}", file=sys.stderr)
        return 1
    else:
        print("Error: Unauthenticated request was allowed!", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
