const std = @import("std");

pub const Index = @import("src/index.zig").Index;
pub const MAX_RESULTS = @import("src/search.zig").MAX_RESULTS;

test {
	_ = @import("./src/search.zig");
	std.testing.refAllDecls(@This());
}
