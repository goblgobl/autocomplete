const std = @import("std");

const Kv = @import("kv.zig").Kv;
const Index = @import("index.zig").Index;

const Allocator = std.mem.Allocator;

pub const Id = u32;
pub const WordIndex = u3;
pub const NgramIndex = u5;

pub const MAX_RESULTS = 10;
pub const MAX_WORDS = (1 << @bitSizeOf(WordIndex)) - 1;
pub const MAX_WORD_LENGTH = (1 << @bitSizeOf(NgramIndex)) - 1;

pub var kv: Kv = undefined;
var indexes: std.AutoHashMap(Id, Index) = undefined;

pub fn setup(allocator: Allocator, config: Config) !void {
	_ = allocator;
	kv = try Kv.init(config.db orelse "db");
	defer kv.deinit();
}

pub const Config = struct {
	db: ?[]const u8 = null,
	admin: ?[]const u8 = null,
	listen: ?[]const u8 = null,

	const Self = @This();

	pub fn deinit(self: Self, allocator: Allocator) void {
		if (self.db) |db| {
			allocator.free(db);
		}
		if (self.admin) |admin| {
			allocator.free(admin);
		}
		if (self.listen) |listen| {
			allocator.free(listen);
		}
	}
};
