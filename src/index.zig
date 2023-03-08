const std = @import("std");
const t = @import("t.zig");

const ac = @import("autocomplete.zig");
const search = @import("search.zig");
const DB = @import("db.zig").DB;
const Input = @import("input.zig").Input;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const StringHashMap = std.StringHashMap;

pub const Index = struct {
	id: ac.Id,
	allocator: Allocator,
	entries: AutoHashMap(ac.Id, *Entry),
	lookup: StringHashMap(ArrayList(NgramInfo)),

	const Self = @This();

	pub const Config = struct {
		id: ac.Id,
	};

	pub fn init(allocator: Allocator, config: Config) Index {
		return Index{
			.id = config.id,
			.allocator = allocator,
			.entries = AutoHashMap(ac.Id, *Entry).init(allocator),
			.lookup = StringHashMap(ArrayList(NgramInfo)).init(allocator),
		};
	}

	pub fn populateFromDb(self: *Self, db: DB) !void {
		const index_id = self.id;

		// $index_id:i:
		const term_prefix = [_]u8 {
			@intCast(u8, (index_id >> 24) & 0xFF),
			@intCast(u8, (index_id >> 16) & 0xFF),
			@intCast(u8, (index_id >> 8) & 0xFF),
			@intCast(u8, index_id & 0xFF),
			':', 'i', ':'
		};

		var it = try db.iterate(term_prefix[0..]);
		defer it.deinit();
		while (try it.next()) |entry| {
			const k = entry.key[7..]; // strip out the $index_id:i:
			const entry_id : ac.Id = @intCast(u32, k[0])<<24 | @intCast(u32, k[1])<<16 | @intCast(u32, k[2])<<8 | @intCast(u32, k[3]);
			try self.add(entry_id, entry.value);
		}
	}

	pub fn find(self: Self, value: []const u8, entries: *[ac.MAX_RESULTS]ac.Id) ![]ac.Id {
		const found = try search.search(self.allocator, value, self, entries);
		return entries[0..found];
	}

	pub fn add(self: *Self, id: ac.Id, value: []const u8) !void {
		std.debug.assert(value.len < 255);

		const allocator = self.allocator;

		var entry = try allocator.create(Entry);
		entry.id = id;
		try self.entries.put(id, entry);

		var lookup = &self.lookup;
		var input = try Input.parse(allocator, value);
		while (input.next()) |result| {
			const word = result.value;
			for (0..word.len - 2) |ngram_index| {
				const np = NgramInfo{
					.entry_id = id,
					.word_index = result.index,
					.ngram_index = @intCast(ac.NgramIndex, ngram_index),
				};

				const ngram = word[ngram_index..ngram_index+3];
				var gop = try lookup.getOrPut(ngram);
				if (gop.found_existing) {
					try gop.value_ptr.append(np);
				} else {
					var list = ArrayList(NgramInfo).init(allocator);
					try list.append(np);
					gop.value_ptr.* = list;
				}
			}
		}
		entry.value = input.getNormalized();
		entry.word_count = input.word_count;
	}

	pub fn count(self: *Self) usize {
		return self.entries.count();
	}

	pub fn deinit(self: *Self) void {
		const allocator = self.allocator;

		// free up entries
		var it1 = self.entries.valueIterator();
		while (it1.next()) |entry| {
			const e = entry.*;
			allocator.free(e.value);
			allocator.destroy(e);
		}
		self.entries.deinit();

		// free up lookup
		var it2 = self.lookup.valueIterator();
		while (it2.next()) |list| {
			list.deinit();
		}
		self.lookup.deinit();

		self.* = undefined;
	}
};

const Entry = struct {
	id: ac.Id,
	word_count: u8,
	value: []const u8,
};

const NgramInfo = struct {
	entry_id: ac.Id,
	word_index: ac.WordIndex,
	ngram_index: ac.NgramIndex,
};

test "index.add" {
	{
		var idx = Index.init(t.allocator, Index.Config{.id = 0});
		defer idx.deinit();
		try t.expectEqual(idx.count(), 0);

		try idx.add(1, "silver needle");
		try t.expectEqual(@as(usize, 1), idx.count());
		try t.expectEqual(@as(usize, 8), idx.lookup.count());

		try idx.add(2, "white peony");
		try t.expectEqual(@as(usize, 2), idx.count());
		try t.expectEqual(@as(usize, 14), idx.lookup.count());

		try idx.add(3, "for never");
		try t.expectEqual(@as(usize, 3), idx.count());

		const hits = idx.lookup.get("ver").?;
		try t.expectEqual(@as(usize, 2), hits.items.len);
		try t.expectEqual(@as(ac.Id, 1), hits.items[0].entry_id);
		try t.expectEqual(@as(ac.WordIndex, 0), hits.items[0].word_index);
		try t.expectEqual(@as(ac.NgramIndex, 3), hits.items[0].ngram_index);

		try t.expectEqual(@as(ac.Id, 3), hits.items[1].entry_id);
		try t.expectEqual(@as(ac.WordIndex, 1), hits.items[1].word_index);
		try t.expectEqual(@as(ac.NgramIndex, 2), hits.items[1].ngram_index);
	}
}

test "index.populateFromDb empty" {
	t.cleanup();
	var db = try DB.init("tests/db");
	defer db.deinit();

	var idx = Index.init(t.allocator, Index.Config{.id = 0});
	defer idx.deinit();
	try idx.populateFromDb(db);
	try t.expectEqual(@as(usize, 0), idx.entries.count());
	try t.expectEqual(@as(usize, 0), idx.lookup.count());
}


test "index.populateFromDb input" {
	t.cleanup();
	var db = try DB.init("tests/db");
	defer db.deinit();
	try db.put(&[_]u8{0,0,0,45,':','i',':',0,0,0,5}, "silver");
	try db.put(&[_]u8{0,0,0,45,':','i',':',0,0,0,7}, "peanut");
	try db.put(&[_]u8{0,0,0,22,':','i',':',0,0,0,8}, "needle"); // different index

	var idx = Index.init(t.allocator, Index.Config{.id = 45});
	defer idx.deinit();
	try idx.populateFromDb(db);
	try t.expectEqual(@as(usize, 2), idx.entries.count());
	try t.expectString("silver", idx.entries.get(5).?.value);
	try t.expectString("peanut", idx.entries.get(7).?.value);
	try t.expectEqual(@as(usize, 8), idx.lookup.count());
}
