//! Single door to libfuse3/libc: re-exports the translate-c module that
//! build.zig generates from c.h (@cImport is deprecated in Zig 0.16).
pub const c = @import("c");
