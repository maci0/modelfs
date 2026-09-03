/* Translate-c entry point for musl targets; included by nothing. build.zig
 * translates src/c_musl.h instead of src/c.h when the build target's libc is
 * musl, and this file exists only to work around one translate-c defect:
 * musl's bits/alltypes.h defines struct timespec with an anonymous bitfield
 * (`int :8*(sizeof(time_t)-sizeof(long))*(__BYTE_ORDER==4321);`), and
 * translate-c demotes any struct holding an anonymous bitfield to an opaque
 * type. struct timespec goes opaque, and every consumer in the same
 * translation unit follows -- struct stat, struct statvfs -- which the
 * daemon cannot even declare a variable of. Defining __DEFINED_struct_
 * timespec makes alltypes.h skip its guarded definition, and the plain
 * definition below takes its place: the bitfield expressions are zero-width
 * on both release targets (LP64, little-endian: 8*(sizeof(time_t)-
 * sizeof(long)) == 0), so { long tv_sec; long tv_nsec; } is byte-for-byte
 * what musl itself would have produced. Anything but x86_64 or aarch64 must
 * re-derive that here before it may use the musl path.
 *
 * glibc builds must not route through this file: glibc guards struct
 * timespec with __timespec_defined, not __DEFINED_struct_timespec, so the
 * definition below would collide with time.h's instead of replacing it.
 */
#if !defined(__x86_64__) && !defined(__aarch64__)
#error "c_musl.h pins struct timespec to the LP64 little-endian layout; \
derive the musl struct for this architecture before adding it"
#endif

#define __DEFINED_struct_timespec
struct timespec {
	long tv_sec;
	long tv_nsec;
};

/* glibc declares the RENAME_* flags in <stdio.h> under _GNU_SOURCE; musl
 * only names the syscall number in bits/syscall.h. The values are the
 * kernel ABI from linux/fs.h, which every libc agrees on. The renameat2
 * wrapper itself is declared nowhere reachable on musl, and zig's musl
 * libc.a ships no symbol for it either, so sys.renameAt2 issues the raw
 * syscall and no declaration appears here.
 */
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif
#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE (1 << 1)
#endif
#ifndef RENAME_WHITEOUT
#define RENAME_WHITEOUT (1 << 2)
#endif

#include "c.h"
