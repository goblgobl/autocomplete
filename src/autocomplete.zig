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
