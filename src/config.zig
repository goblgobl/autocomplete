const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
	db: ?[:0]const u8 = null,
	port: ?u16 = null,
	address: ?[]const u8 = null,

	const Self = @This();

	pub fn deinit(self: Self, allocator: Allocator) void {
		if (self.db) |db_path| {
			allocator.free(db_path);
		}
		if (self.address) |address| {
			allocator.free(address);
		}
	}
};
