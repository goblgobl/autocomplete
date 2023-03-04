const std = @import("std");
pub const Index = @import("./src/index.zig").Index;

comptime {
	std.testing.refAllDecls(@This());
}
