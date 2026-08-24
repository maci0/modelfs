//! Single door to libfuse3/libc: re-exports the translate-c module that
//! build.zig generates from c.h (Zig 0.16 removed @cImport).
pub const c = @import("c");
