# Security policy

Reports about the recovery plane this repository ships alongside the binary, the systemd units
under `scripts/nas/` and the restore, drill, and alarm wrappers they install, are in scope for
this policy as well; the model for that plane is
[docs/threat-model.md](docs/threat-model.md), boundary B8.

## Supported versions

`v0.21.0` is the current release: tag `v0.21.0`, matching `.version = "0.21.0"` in
[build.zig.zon](build.zig.zon), which `modelfs version` prints.

Fixes land on `main` only. One concerning a released line is noted in
[CHANGELOG.md](CHANGELOG.md) with the affected and fixed versions named, and ships
as the next `v<version>` tag per the release procedure in
[CONTRIBUTING.md](CONTRIBUTING.md). No older line receives backported fixes, so the
remedy for a deployment is to move to the current tag; every release before
`v0.14.1`, `v0.1.0` included, predates the peer request-line and `Content-Length`
validation, the cluster-id bound, and the secret-handling hardening recorded under
`## [0.15.0]` and `## [0.14.1]` in [CHANGELOG.md](CHANGELOG.md).

If you build from an intermediate revision rather than a tag, pin the commit hash it
came from, so you know exactly what you are running and can rebuild from a fixed
revision.

## Reporting a vulnerability

Do not open a public issue for anything you suspect is exploitable.

Email the maintainer at `maci.stgn@gmail.com` for private vulnerability reports.
Do not include exploit details or credentials in a public issue. GitHub private
vulnerability reporting is not currently enabled on this repository.

Please include what you can of:

* The commit hash you built from (`modelfs version` prints the declared
  version, which names the `v<version>` tag for a tagged build; a `main`
  build is identified by its hash alone).
* A minimal reproduction: mount flags, the peer request or lease file involved,
  and observed versus expected behavior.
* Your assessment of impact: origin exposure, peer spoofing, cache poisoning,
  cross-tenant read, denial of read.

## What happens next

Maintainers triage privately, land the fix on `main`, and note it
in [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]` with credit to the
reporter unless asked not to. When a released line is affected, the entry
names the affected and fixed versions so users can tell whether they must
upgrade.
