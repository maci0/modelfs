# Security policy

## Supported versions

`v0.7.0` is the current release: tag `v0.7.0`, matching `.version = "0.7.0"` in
[build.zig.zon](build.zig.zon), which `modelfs version` prints. The `0.7.x` line
receives security fixes.

Fixes land on `main`. One concerning a released line is noted in
[CHANGELOG.md](CHANGELOG.md) with the affected and fixed versions named, and ships
as the next `v<version>` tag per the release procedure in
[CONTRIBUTING.md](CONTRIBUTING.md).

If you build from an intermediate revision rather than a tag, pin the commit hash it
came from, so you know exactly what you are running and can rebuild from a fixed
revision.

## Reporting a vulnerability

Do not open a public issue for anything you suspect is exploitable.

The intended intake is GitHub private vulnerability reporting (Security tab,
"Report a vulnerability"), which feeds the advisory-thread path under
"What happens next". That feature is not enabled on this repository, so
there is no private inbox until a repository admin turns it on. There is
no other disclosed contact.

Please include what you can of:

* The commit hash you built from (`modelfs version` prints the declared
  version, which names the `v<version>` tag for a tagged build; a `main`
  build is identified by its hash alone).
* A minimal reproduction: mount flags, the peer request or lease file involved,
  and observed versus expected behavior.
* Your assessment of impact: origin exposure, peer spoofing, cache poisoning,
  cross-tenant read, denial of read.

## What happens next

Maintainers triage in the advisory thread, land the fix on `main`, and note it
in [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]` with credit to the
reporter unless asked not to. When a released line is affected, the entry
names the affected and fixed versions so users can tell whether they must
upgrade.
