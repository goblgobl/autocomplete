const std = @import("std");

const t = @import("t.zig");
const DB = @import("db.zig").DB;
const Config = @import("config.zig").Config;

const Allocator = std.mem.Allocator;

pub const Id = u32;
pub const WordIndex = u3;
pub const NgramIndex = u5;
pub const Index = @import("index.zig").Index;
pub const Context = @import("context.zig").Context;
pub const search = @import("search.zig").search;
pub const IdCollector = [MAX_RESULTS]Id;

pub const MAX_RESULTS = 10;
pub const MAX_WORDS = (1 << @bitSizeOf(WordIndex)) - 1;
pub const MAX_WORD_LENGTH = (1 << @bitSizeOf(NgramIndex)) - 1;

pub fn encodeId(buf: []u8, id: Id) void {
	@setRuntimeSafety(false);
	std.debug.assert(buf.len >= 4);
	buf[0] = @intCast(u8, (id >> 24) & 0xFF);
	buf[1] = @intCast(u8, (id >> 16) & 0xFF);
	buf[2] = @intCast(u8, (id >> 8) & 0xFF);
	buf[3] = @intCast(u8, id & 0xFF);
}

// Meant to be used with index.make_db_key_buf
// make_db_key_buf returns a buffer that contains the index prefix, and has
// extra bytes to encoded an id at the end.
pub fn encodePrefixedId(buf: []u8, id: Id) void {
	std.debug.assert(buf.len == 11);
	encodeId(buf[7..], id);
}

test "encodeId" {
	var buf: [4]u8 = undefined;
	{
		encodeId(&buf, 0);
		var expected = [_]u8{0, 0, 0, 0};
		try t.expectString(&expected, &buf);
	}

	{
		encodeId(&buf, 939292932);
		var expected = [_]u8{55, 252, 121, 4};
		try t.expectString(&expected, &buf);
	}
}

test "encodePrefixedId" {
	var buf = [_]u8{0, 1, 2, 3, 4, 5, 6, 1, 1, 1, 1};
	{
		encodePrefixedId(&buf, 0);
		var expected = [_]u8{0, 1, 2, 3, 4, 5, 6, 0, 0, 0, 0};
		try t.expectString(&expected, &buf);
	}

	{
		encodePrefixedId(&buf, 939292932);
		var expected = [_]u8{0, 1, 2, 3, 4, 5, 6, 55, 252, 121, 4};
		try t.expectString(&expected, &buf);
	}
}
