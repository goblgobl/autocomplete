const std = @import("std");
const builtin = @import("builtin");

const DB = @import("db.zig").DB;
const ac = @import("autocomplete.zig");

const Id = ac.Id;
const Index = ac.Index;
const Context = ac.Context;

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

// std.testing.expectEqual won't coerce expected to actual, which is a problem
// when expected is frequently a comptime.
// https://github.com/ziglang/zig/issues/4437
pub fn expectEqual(expected: anytype, actual: anytype) !void {
	try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

pub const expectError = std.testing.expectError;
pub const expectSlice = std.testing.expectEqualSlices;
pub const expectString = std.testing.expectEqualStrings;


pub fn cleanup() void {
	const cwd = std.fs.cwd();
	cwd.deleteFile("tests/db") catch {};
	cwd.deleteFile("tests/db-lock") catch {};
}

pub fn buildContext() ContextBuilder {
	return ContextBuilder.init() catch unreachable;
}

pub const ContextBuilder = struct {
	ctx: Context,

	pub fn init() !ContextBuilder{
		return .{
			.ctx = try Context.init(allocator, .{.db = "tests/db"}),
		};
	}

	pub fn deinit(self: ContextBuilder) void {
		self.ctx.deinit();
	}

	pub fn addIndex(self: *ContextBuilder, idx: Index) void {
		self.ctx.indexes.put(idx.id, idx) catch unreachable;
	}


	pub fn buildIndex(self: ContextBuilder, id: Id) IndexBuilder {
		return IndexBuilder.init(self.ctx.db, .{.id = id});
	}
};


pub const IndexBuilder = struct {
	db : DB,
	index: Index,

	pub fn init(db: DB, config: Index.Config) IndexBuilder{
		return .{
			.db = db,
			.index = Index.init(allocator, config),
		};
	}

	pub fn add(self: *IndexBuilder, id: ac.Id, term: []const u8, payload: []const u8) void {
		self.index.add(id, term) catch unreachable;
		var buf = self.index.make_db_key_buf('p');
		ac.encodePrefixedId(&buf, id);
		self.db.put(&buf, payload) catch unreachable;
	}
};
