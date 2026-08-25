# Vendored libfuse3 (aarch64)

Target-root libfuse3 for cross-building modelfs on aarch64 spark nodes
(Ubuntu 24.04 "noble"). The host build uses the system libfuse3; point a
cross build at this tree instead. On a fresh clone only the two `.deb`
files exist (`root/` and `lib/` are gitignored), so extract them before
building by running [scripts/extract_fuse3_arm64.sh](../../scripts/extract_fuse3_arm64.sh),
the same extractor CI's cross-aarch64 job runs (it prefers `dpkg-deb`,
which ships with Debian-family systems; other distros:
[extracting without dpkg-deb](#extracting-without-dpkg-deb)):

```
zig build -Dtarget=aarch64-linux-gnu.2.39 -Dfuse-include=<repo>/.deps/fuse3-arm64/root/usr/include/fuse3 \
  -Dfuse-lib=<repo>/.deps/fuse3-arm64/lib
```

## Extracting without dpkg-deb

[scripts/extract_fuse3_arm64.sh](../../scripts/extract_fuse3_arm64.sh) handles
this itself: a `.deb` is an `ar` archive whose `data.tar.zst` holds the
filesystem, so where `dpkg-deb` is absent the script unpacks each `.deb` with
binutils `ar` plus a zstd-capable `tar` into `root/`, then recreates the
`lib/` symlinks. The only requirements are `ar` and `tar --zstd`; there is no
manual recipe to follow.

## Provenance

Downloaded from the Ubuntu noble archive (main/f/fuse3 pool):

- `libfuse3-3_3.14.0-5build1_arm64.deb`
  http://archive.ubuntu.com/ubuntu/pool/main/f/fuse3/libfuse3-3_3.14.0-5build1_arm64.deb
  sha256: d84990ee2b8e6a079ed6f77d7e5fa1fe70e2462bcf9aecd43f4a65a9ae1486c9
- `libfuse3-dev_3.14.0-5build1_arm64.deb`
  http://archive.ubuntu.com/ubuntu/pool/main/f/fuse3/libfuse3-dev_3.14.0-5build1_arm64.deb
  sha256: 9a32e4ed3fe950417074d534207d399c5a80ad06843e265ae75a06ba703feafb

Verify before use: `sha256sum -c` against the digests above, then compare
with `Release` file hashes from archive.ubuntu.com. `build.zig` enforces
these digests on every build and fails with a mismatch message if either
`.deb` drifted; after a legitimate refresh, update both digests here and
in `build.zig`.

## Layout

- `*.deb`: pristine downloads; keep as the provenance/integrity source.
- `root/`: extraction of both debs (headers under `usr/include/fuse3`,
  static lib + linker symlink + pkgconfig under `usr/lib/aarch64-linux-gnu`,
  runtime shared lib under `lib/aarch64-linux-gnu`, license/copyright under
  `usr/share/doc`). Upstream example programs were dropped as unused.
- `lib/`: convenience symlinks so `-Dfuse-lib` resolves `libfuse3.so`.

## Refreshing

Bump to a newer noble security update by replacing both `.deb`s with the
same-versioned builds from the pool and re-running
[scripts/extract_fuse3_arm64.sh](../../scripts/extract_fuse3_arm64.sh), which
re-extracts into `root/` and refreshes the `lib/` symlinks in place, then
updating the digests above in this README and in `build.zig`.
