/// Immutable byte sequence; interning and GC ownership arrive in later phases.
pub const String = struct {
    bytes: []const u8,
};
