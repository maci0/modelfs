# Vendored libfuse3 (aarch64)

Target-root libfuse3 for cross-building modelfs on aarch64 spark nodes
(Ubuntu 24.04 "noble"). The host build uses the system libfuse3; point a
cross build at this tree instead. On a fresh clone only the two `.deb`
files and [SHA256SUMS](SHA256SUMS) exist, so extract them before
building. [scripts/cross_aarch64.sh](../../scripts/cross_aarch64.sh) does
that itself via
[scripts/extract_fuse3_arm64.sh](../../scripts/extract_fuse3_arm64.sh)
(the same pair CI's cross-aarch64 job runs). The extractor prefers
`dpkg-deb`, which ships with Debian-family systems; other distros:
[extracting without dpkg-deb](#extracting-without-dpkg-deb):

```
./scripts/cross_aarch64.sh
```

Output lands at `.scratch/fuse3-arm64/{root,lib}`, not next to these
`.deb` files, so a previous extract cannot leave stale headers in the
source tree.

## Extracting without dpkg-deb

[scripts/extract_fuse3_arm64.sh](../../scripts/extract_fuse3_arm64.sh) handles
this itself: a `.deb` is an `ar` archive whose `data.tar.zst` holds the
filesystem, so where `dpkg-deb` is absent the script unpacks each `.deb` with
binutils `ar` plus `zstd` or a zstd-capable `tar` into the output `root/`, then
recreates the `lib/` symlinks. The only requirements are `ar` and `zstd` or
`tar --zstd`; there is no manual recipe to follow.

## Provenance

Downloaded from the Ubuntu noble archive (main/f/fuse3 pool):

- `libfuse3-3_3.14.0-5build1_arm64.deb`
  http://archive.ubuntu.com/ubuntu/pool/main/f/fuse3/libfuse3-3_3.14.0-5build1_arm64.deb
  sha256: d84990ee2b8e6a079ed6f77d7e5fa1fe70e2462bcf9aecd43f4a65a9ae1486c9
- `libfuse3-dev_3.14.0-5build1_arm64.deb`
  http://archive.ubuntu.com/ubuntu/pool/main/f/fuse3/libfuse3-dev_3.14.0-5build1_arm64.deb
  sha256: 9a32e4ed3fe950417074d534207d399c5a80ad06843e265ae75a06ba703feafb

License: LGPL-2.1 (upstream fuse3, same for both packages). The authoritative
text and copyright list ship inside each `.deb` and land under
`root/usr/share/doc/libfuse3-3/copyright` after extraction; consult that file
for the grant covering the exact vendored artifact. This repo is
GPL-3.0-or-later and links the shared library dynamically.

Verify before use: `sha256sum -c SHA256SUMS` in this directory, then compare
with `Release` file hashes from archive.ubuntu.com. The extractor and
`build.zig` both enforce [SHA256SUMS](SHA256SUMS) and fail if either `.deb`
drifted; after a legitimate refresh, update both digests here and in
SHA256SUMS.

## Layout

- `*.deb`: pristine downloads; keep as the provenance/integrity source.
- `SHA256SUMS`: digest list for those `.deb` files; the one input the
  extractor and `build.zig` check.
- Extracted tree (gitignored, default `.scratch/fuse3-arm64/`):
  - `root/`: extraction of both debs (headers under `usr/include/fuse3`,
    static lib + linker symlink + pkgconfig under `usr/lib/aarch64-linux-gnu`,
    runtime shared lib under `lib/aarch64-linux-gnu`, license/copyright under
    `usr/share/doc`).
  - `lib/`: convenience symlinks so `-Dfuse-lib` resolves `libfuse3.so`.

## Refreshing

Bump to a newer noble security update by replacing both `.deb`s with the
same-versioned builds from the pool, updating [SHA256SUMS](SHA256SUMS) and
the digests above, then re-running
[scripts/extract_fuse3_arm64.sh](../../scripts/extract_fuse3_arm64.sh) (or
just [scripts/cross_aarch64.sh](../../scripts/cross_aarch64.sh)), which
wipes the output tree, re-extracts, and refreshes the `lib/` symlinks.
