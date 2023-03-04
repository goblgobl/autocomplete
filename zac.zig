const std = @import("std");
pub const Index = @import("./src/index.zig").Index;

test {
	_ = @import("./src/search.zig");
	std.testing.refAllDecls(@This());
}
