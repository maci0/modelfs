#!/usr/bin/env python3
"""Probe a modelfs peer /ping endpoint with a deliberately wrong bearer token.

Exits 0 (with a SKIP line) when no peer is listening, so a suite without a
running cluster is never counted as a pass or a failure; exits 1 when the
peer fails to reject the unauthenticated request.
"""

import sys
import urllib.error
import urllib.request

HTTP_UNAUTHORIZED = 401
ARGC = 3  # prog + HOST PORT


def main(argv: list[str]) -> int:
    if len(argv) != ARGC:
        print(f"usage: {argv[0]} HOST PORT", file=sys.stderr)
        return 2
    host, port = argv[1], argv[2]
    url = f"http://{host}:{port}/ping"
    headers = {"Authorization": "Bearer WRONG_TOKEN"}
    req = urllib.request.Request(url, headers=headers)
    try:
        urllib.request.urlopen(req)
        print("Error: Unauthenticated request was allowed!")
        return 1
    except urllib.error.HTTPError as e:
        if e.code != HTTP_UNAUTHORIZED:
            print(f"Error: Expected 401, got {e.code}")
            return 1
        print("✓ Correctly rejected invalid PSK with HTTP 401")
        return 0
    except urllib.error.URLError as e:
        reason = getattr(e, "reason", e)
        if isinstance(reason, ConnectionRefusedError) or "refused" in str(reason).lower():
            print(f"SKIP: no modelfs peer listening on {host}:{port}; start a cluster first")
            return 0
        print(f"Error: unexpected URL failure: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
