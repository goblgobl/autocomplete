const std = @import("std");

const t = @import("t.zig");
const DB = @import("db.zig").DB;
const Index = @import("index.zig").Index;

const Allocator = std.mem.Allocator;

pub const Id = u32;
pub const WordIndex = u3;
pub const NgramIndex = u5;

pub const MAX_RESULTS = 10;
pub const MAX_WORDS = (1 << @bitSizeOf(WordIndex)) - 1;
pub const MAX_WORD_LENGTH = (1 << @bitSizeOf(NgramIndex)) - 1;

pub var db: DB = undefined;
var indexes: std.AutoHashMap(Id, Index) = undefined;

// will only be called after setup has been successfully called
pub fn deinit(_: Allocator) void {
	db.deinit();
	var it = indexes.valueIterator();
	while (it.next()) |idx| {
		idx.deinit();
	}
	indexes.deinit();
}

pub fn setup(allocator: Allocator, config: Config) !void {
	db = try DB.init(config.db orelse "db");
	indexes = std.AutoHashMap(Id, Index).init(allocator);

	var it = try db.iterate("idx:");
	defer it.deinit();
	while (try it.next()) |entry| {
		const idx = try createIndex(allocator, entry.value);
		try indexes.put(idx.id, idx);
	}
}

fn createIndex(allocator: Allocator, json: []const u8) !Index {
	var stream = std.json.TokenStream.init(json);
	const index_config = try std.json.parse(Index.Config, &stream, .{});

	var idx = Index.init(allocator, index_config);
	try idx.populateFromDb(db);
	return idx;
}

pub const Config = struct {
	db: ?[:0]const u8 = null,
	listen: ?[]const u8 = null,

	const Self = @This();

	pub fn deinit(self: Self, allocator: Allocator) void {
		if (self.db) |db_path| {
			allocator.free(db_path);
		}
		if (self.listen) |listen| {
			allocator.free(listen);
		}
	}
};

test "setup no data (no error)" {
	t.cleanup();
	try setup(t.allocator, Config{.db = "tests/db"});
	defer deinit(t.allocator);
}

test "setup" {
	t.cleanup();

	var tmp = try DB.init("tests/db");
	try tmp.put("idx:33", "{\"id\":33}");
	try tmp.put(&[_]u8{0,0,0,33,':','i',':',0,0,0,5}, "silver needle");
	tmp.deinit();

	try setup(t.allocator, Config{.db = "tests/db"});
	defer deinit(t.allocator);

	// lol, this is stupid
	try t.expectEqual(@as(Id, 5), indexes.get(33).?.lookup.get("lve").?.items[0].entry_id);
}
