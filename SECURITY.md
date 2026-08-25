# Security policy

## Supported versions

Nothing has been released yet: `build.zig.zon` declares `0.1.0`, no tag exists,
and there are no published artifacts to patch. Fixes land on `main`. If you run
a build, pin the commit hash it came from (see the README) so you know exactly
what you are running and can rebuild from a fixed revision. This section will
name the release lines that receive security fixes once a first tag exists.

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
to. Until the first tagged release, that changelog entry plus `main` is the
whole fix delivery; once releases exist, the fixed versions will be named
there.
