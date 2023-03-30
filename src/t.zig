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
	return ContextBuilder.init() catch unreachable;
}

pub const ContextBuilder = struct {
	ctx: Context,

	const Self = @This();

	pub fn init() !ContextBuilder{
		return .{
			.ctx = try Context.init(allocator, .{.db = "tests/db"}),
		};
	}

	pub fn deinit(self: *Self) void {
		self.ctx.deinit();
	}

	pub fn addIndex(self: *Self, idx: Index) void {
		self.ctx.indexes.put(idx.id, idx) catch unreachable;
	}


	pub fn buildIndex(self: Self, id: Id) IndexBuilder {
		return IndexBuilder.init(self.ctx.db, .{.id = id});
	}
};


pub const IndexBuilder = struct {
	db : DB,
	index: Index,

	const Self = @This();

	pub fn init(db: DB, config: Index.Config) IndexBuilder{
		return .{
			.db = db,
			.index = Index.init(allocator, config),
		};
	}

	pub fn add(self: *Self, id: ac.Id, term: []const u8, payload: []const u8) void {
		self.index.add(id, term) catch unreachable;
		var buf = self.index.make_db_key_buf('p');
		ac.encodePrefixedId(&buf, id);
		self.db.put(&buf, payload) catch unreachable;
	}
};
