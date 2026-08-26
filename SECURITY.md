# Security policy

## Supported versions

The `0.1.x` line is supported: security fixes land on `main` and ship in the
next `v0.1.x` tag matching `build.zig.zon`'s `.version`, which
`modelfs version` prints. `v0.1.0` is the first tag. If you build from an
intermediate revision rather than a tag, pin the commit hash it came from
(see the README) so you know exactly what you are running and can rebuild
from a fixed revision.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository (Security tab,
"Report a vulnerability"). Do not open a public issue for anything you suspect
is exploitable.

Please include what you can of:

* The commit hash you built from (`modelfs version` prints the declared
  version, but until a tag exists the hash is what identifies your binary).
* A minimal reproduction: mount flags, the peer request or lease file involved,
  and observed versus expected behavior.
* Your assessment of impact: origin exposure, peer spoofing, cache poisoning,
  cross-tenant read, denial of read.

## What happens next

Maintainers triage in the advisory thread, land the fix on `main`, and note it
in [CHANGELOG.md](CHANGELOG.md) with credit to the reporter unless asked not
to. The fix ships as the next `v0.1.x` tag; its changelog entry names the
fixed version.
