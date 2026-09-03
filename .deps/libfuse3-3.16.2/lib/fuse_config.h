/* Private configuration for the vendored libfuse3 build, replacing the
 * fuse_config.h that upstream's meson generates. Every HAVE_ answer below is
 * a musl/libc property (not a build-host property), so the file is static:
 * fork, fstatat, openat, readlinkat, pipe2, splice, vmsplice,
 * posix_fallocate, fdatasync, utimensat, copy_file_range, fallocate, and
 * setxattr are all provided by both glibc and musl; struct stat::st_atim is
 * the Linux layout (st_atimespec is the BSD one). HAVE_ICONV stays undefined
 * on purpose: musl has iconv, but the lib's iconv option module is dead code
 * for this daemon, and leaving it out keeps one source file uncompiled.
 * FUSERMOUNT_DIR is not set here; build.zig passes it, because mount.c only
 * uses it as the first exec_fusermount guess before a PATH search.
 */
#ifndef FUSE_CONFIG_H_INCLUDED
#define FUSE_CONFIG_H_INCLUDED

#define PACKAGE_VERSION "3.16.2"

#define HAVE_FORK 1
#define HAVE_FSTATAT 1
#define HAVE_OPENAT 1
#define HAVE_READLINKAT 1
#define HAVE_PIPE2 1
#define HAVE_SPLICE 1
#define HAVE_VMSPLICE 1
#define HAVE_POSIX_FALLOCATE 1
#define HAVE_FDATASYNC 1
#define HAVE_UTIMENSAT 1
#define HAVE_COPY_FILE_RANGE 1
#define HAVE_FALLOCATE 1
#define HAVE_SETXATTR 1

#define HAVE_STRUCT_STAT_ST_ATIM 1

#endif /* FUSE_CONFIG_H_INCLUDED */
