const std = @import("std");
const ac = @import("lib.zig");

const Allocator = std.mem.Allocator;

const DB = ac.DB;
const Id = ac.Id;
const Index = ac.Index;
const Config = ac.Config;
const ConcurrentMap = ac.ConcurrentMap

pub const Context = struct {
	db: DB,
	indexes: ConcurrentMap(Id, Index),

	pub fn init(allocator: Allocator, config: Config) !Context {
		const db = try DB.init(config.db orelse "db");
		var indexes = ConcurrentMap(Id, Index).init(allocator);

		var it = try db.iterate("idx:");
		defer it.deinit();
		while (try it.next()) |entry| {
			const idx = try createIndex(allocator, db, entry.value);
			try indexes.put(idx.id, idx);
		}

		return .{
			.db = db,
			.indexes = indexes,
		};
	}

	pub fn deinit(self: Context) void {
		self.db.deinit();

		// don't need to be thread safe anymore, so use the underlying map directly
		var it = self.indexes.map.valueIterator();
		while (it.next()) |idx| {
			idx.deinit();
		}
		self.indexes.deinit();
	}

	pub fn getIndex(self: *Self, id: Id) ?*Index {
		return self.indexes.getPtr(id);
	}
};

fn createIndex(allocator: Allocator, db: DB, json: []const u8) !ac.Index {
	var stream = std.json.TokenStream.init(json);
	const index_config = try std.json.parse(Index.Config, &stream, .{});
	var idx = Index.init(allocator, index_config);
	try idx.populateFromDb(db);
	return idx;
}

test "setup: no data (no error)" {
	t.cleanup();
	var ctx = try Context.init(t.allocator, .{.db = "tests/db"});
	ctx.deinit();
}

test "setup: loads DBs" {
	t.cleanup();

	var tmp = try DB.init("tests/db");
	try tmp.put("idx:33", "{\"id\":33}");
	try tmp.put(&[_]u8{0,0,0,33,':','i',':',0,0,0,5}, "silver needle");
	try tmp.put("idx:996", "{\"id\":996}");
	try tmp.put(&[_]u8{0,0,3,228,':','i',':',0,0,3,254}, "keemun");
	tmp.deinit();

	var ctx = try Context.init(t.allocator, .{.db = "tests/db"});
	defer ctx.deinit();

	// lol, this is stupid
	try t.expectEqual(5, ctx.getIndex(33).?.lookup.get("lve").?.items[0].entry_id);
	try t.expectEqual(1022, ctx.getIndex(996).?.lookup.get("eem").?.items[0].entry_id);
}
