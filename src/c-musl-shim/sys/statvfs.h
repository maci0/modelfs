/* Translate-c shim for musl's <sys/statvfs.h>; mirrors the musl header
 * byte-for-byte in layout. build.zig puts this directory first on the
 * include path of the musl translate-c step only (musl targets, and for now
 * only that step), because musl pads struct statvfs with an ANONYMOUS
 * zero-width bitfield, which translate-c demotes to an opaque type -- and
 * the daemon must be able to declare one to answer FUSE statfs. The bitfield
 * expressions are zero-width on every LP64 target (8*(2*sizeof(int)-
 * sizeof(long)) == 0), so dropping them changes no offsets: the layout below
 * is what musl's own header produces. A big-endian port must re-derive this
 * shim before use, as src/c_musl.h already demands for struct timespec.
 *
 * The C side (the vendored libfuse3) never sees this shim: it compiles
 * against the real musl headers, where a native compiler handles the
 * bitfield fine -- and lands on the identical layout.
 */
#ifndef _SYS_STATVFS_H
#define _SYS_STATVFS_H

#ifdef __cplusplus
extern "C" {
#endif

#define __NEED_fsblkcnt_t
#define __NEED_fsfilcnt_t
#include <bits/alltypes.h>

#if __BYTE_ORDER != __LITTLE_ENDIAN
#error "c-musl-shim/sys/statvfs.h pins struct statvfs to the LP64 \
little-endian layout; derive the big-endian one before adding it"
#endif

struct statvfs {
	unsigned long f_bsize, f_frsize;
	fsblkcnt_t f_blocks, f_bfree, f_bavail;
	fsfilcnt_t f_files, f_ffree, f_favail;
	unsigned long f_fsid;
	unsigned long f_flag, f_namemax;
	unsigned int f_type;
	int __reserved[5];
};

int statvfs(const char *__restrict, struct statvfs *__restrict);
int fstatvfs(int, struct statvfs *);

#define ST_RDONLY 1
#define ST_NOSUID 2
#define ST_NODEV 4
#define ST_NOEXEC 8
#define ST_SYNCHRONOUS 16
#define ST_MANDLOCK 64
#define ST_WRITE 128
#define ST_APPEND 256
#define ST_IMMUTABLE 512
#define ST_NOATIME 1024
#define ST_NODIRATIME 2048
#define ST_RELATIME 4096

#ifdef __cplusplus
}
#endif

#endif
