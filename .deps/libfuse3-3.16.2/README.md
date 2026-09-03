# Vendored libfuse3 3.16.2 source

Vendored verbatim from upstream https://github.com/libfuse/libfuse at tag
`fuse-3.16.2` (tarball sha256 below), so `zig build -Dfuse-static` can compile
the library into the daemon instead of linking a system `libfuse3.so`. This is
what makes the release artifacts single-file static binaries
(`-Dtarget=x86_64-linux-musl -Dfuse-static` and the aarch64 twin): there is no
usable static `libfuse3.a` in any distro package set for musl, and the
glibc-built `.a` inside `fuse3-arm64/libfuse3-dev` is unusable for musl.

## Contents and provenance

- `include/*.h` — upstream `include/` (the eight public headers, bare layout,
  matching how `src/c.h` includes them and how distros install them under
  `/usr/include/fuse3/`).
- `lib/*.c`, `lib/*.h`, `lib/modules/subdir.c` — upstream `lib/`, exactly the
  source list of upstream `lib/meson.build` for Linux (`mount.c`, not
  `mount_bsd.c`; `modules/iconv.c` left out; see `lib/fuse_config.h`).
- `lib/fuse_config.h` — **the only non-upstream file**, a hand-written
  replacement for the header upstream's meson generates, pinned to musl/glibc
  properties that do not vary with the build host. Edit it only when a musl
  or glibc release changes those properties.
- `LICENSE`, `LGPL2.txt`, `GPL2.txt` — upstream license texts, verbatim.

## Verification

`SHA256SUMS` covers every file in this directory (including itself excluded;
`sha256sum -c` from inside the directory). `build.zig` re-verifies every
digest before any compile, the same gate as `fuse3-arm64/SHA256SUMS`, and
`scripts/check.sh` runs the check too.

## Refresh

1. Download the release tarball from upstream and check it against the
   upstream-signed digest.
2. Replace `include/` and `lib/` contents per the list above (re-derive the
   meson source list if upstream changed it), re-apply `fuse_config.h`.
3. Regenerate `SHA256SUMS` (it covers every file except itself):
   `cd .deps/libfuse3-3.16.2 && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS`.
4. Run `./scripts/check.sh`; bump the version note here and in the CHANGELOG.

Tarball sha256 at vendoring time:
`1bc306be1a1f4f6c8965fbdd79c9ccca021fdc4b277d501483a711cbd7dbcd6c`
(libfuse-3.16.2.tar.gz, tag fuse-3.16.2). The digests in `SHA256SUMS`, not
this line, are what the gates enforce.
