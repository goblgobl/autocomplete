const std = @import("std");

pub const testing = @import("t.zig");
pub const DB = @import("db.zig").DB;

pub const Index = @import("index.zig").Index;
pub const Input = @import("input.zig").Input;
pub const ConcurrentMap = @import("concurrent_map.zig").ConcurrentMap;

pub const Id = u32;
pub const WordIndex = u3;
pub const NgramIndex = u5;
pub const IdCollector = [MAX_RESULTS]Id;

pub const MAX_RESULTS = 16;
pub const MAX_WORDS = (1 << @bitSizeOf(WordIndex)) - 1;
pub const MAX_WORD_LENGTH = (1 << @bitSizeOf(NgramIndex)) - 1;

test {
	std.testing.refAllDecls(@This());
}
