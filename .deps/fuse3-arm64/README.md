# Vendored libfuse3 (aarch64)

Target-root libfuse3 for cross-building modelfs on aarch64 spark nodes
(Ubuntu 24.04 "noble"). The host build uses the system libfuse3; point a
cross build at this tree instead. On a fresh clone only the two `.deb`
files exist (`root/` and `lib/` are gitignored), so extract them per
[Refreshing](#refreshing) before building (`dpkg-deb -x`, which ships with
Debian-family systems; other distros: [Extracting on non-Debian
hosts](#extracting-on-non-debian-hosts)):

```
zig build -Dtarget=aarch64-linux-gnu.2.39 -Dfuse-include=<repo>/.deps/fuse3-arm64/root/usr/include/fuse3 \
  -Dfuse-lib=<repo>/.deps/fuse3-arm64/lib
```

## Extracting on non-Debian hosts

`dpkg-deb` is part of Debian-family `dpkg`. Any Linux with binutils and a
zstd-capable tar produces the identical trees straight from the `.deb`s
(a `.deb` is an `ar` archive whose `data.tar.zst` holds the filesystem);
run from this directory:

```
mkdir -p root lib
for deb in libfuse3-3_*.deb libfuse3-dev_*.deb; do
    ar x "$deb" data.tar.zst
    tar --zstd -xf data.tar.zst -C root/
    rm data.tar.zst
done
ln -s ../root/lib/aarch64-linux-gnu/libfuse3.so.3.14.0 lib/libfuse3.so.3
ln -s libfuse3.so.3 lib/libfuse3.so
```

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
same-versioned builds from the pool, re-extracting into `root/`
(`dpkg-deb -x <deb> root/`, or the non-Debian recipe above), recreating
the `lib/` symlinks, and updating the digests above in this README and in
`build.zig`.
