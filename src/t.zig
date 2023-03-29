const std = @import("std");
const builtin = @import("builtin");

const DB = @import("db.zig").DB;
const ac = @import("autocomplete.zig");

const Id = ac.Id;
const Index = ac.Index;
const Context = ac.Context;

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub fn cleanup() void {
	const cwd = std.fs.cwd();
	cwd.deleteFile("tests/db") catch {};
	cwd.deleteFile("tests/db-lock") catch {};
}

pub fn buildContext() ContextBuilder {
	return ContextBuilder.init(allocator) catch unreachable;
}

pub const ContextBuilder = struct {
	context: Context,

	const Self = @This();

	pub fn init(a: std.mem.Allocator) !ContextBuilder{
		return .{
			.context = try Context.init(a, .{.db = "tests/db"}),
		};
	}

	pub fn addIndex(self: *Self, idx: Index) *Self {
		self.context.indexes.put(idx.id, idx) catch unreachable;
		return self;
	}
};

pub fn buildIndex(id: Id) IndexBuilder {
	return IndexBuilder.init(allocator, .{.id = id});
}

pub const IndexBuilder = struct {
	index: Index,

	const Self = @This();

	pub fn init(a: std.mem.Allocator, config: Index.Config) IndexBuilder{
		return .{
			.index = Index.init(a, config),
		};
	}
};
