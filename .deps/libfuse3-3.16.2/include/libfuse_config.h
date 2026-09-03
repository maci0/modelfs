/* Public build configuration for the vendored libfuse3, replacing the
 * libfuse_config.h that upstream's meson generates and installs next to the
 * headers (fuse_common.h includes it unconditionally). Upstream only ever
 * defines LIBFUSE_BUILT_WITH_VERSIONED_SYMBOLS here, and only when meson
 * enabled versioned libc symbols; this build disables them (no
 * -Wl,--version-script), so the file deliberately defines nothing and every
 * consumer takes the plain, non-symver branch.
 */
#ifndef LIBFUSE_CONFIG_H_INCLUDED
#define LIBFUSE_CONFIG_H_INCLUDED

#endif /* LIBFUSE_CONFIG_H_INCLUDED */
