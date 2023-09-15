const std = @import("std");
const ac = @import("lib.zig");

const DB = ac.DB;
const Input = ac.Input;

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

	pub fn deinit(self: *Self) void {
		const allocator = self.allocator;

		// free up entries
		var it1 = self.entries.valueIterator();
		while (it1.next()) |entry| {
			const e = entry.*;
			allocator.free(e._normalized_buffer);
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

	pub fn populateFromDb(self: *Self, db: DB) !void {
		// $index_id:i:entry_id(4)
		const key = self.make_db_key_buf('i');
		// strip out the entry_id part, since we want to iterate through the prefix
		const term_prefix = key[0..key.len - 4];

		var it = try db.iterate(term_prefix[0..]);
		defer it.deinit();
		while (try it.next()) |entry| {
			const k = entry.key[7..]; // strip out the $index_id:i:
			const entry_id = @as(u32, @intCast(k[0]))<<24 | @as(u32, @intCast(k[1]))<<16 | @as(u32, @intCast(k[2]))<<8 | @as(u32, @intCast(k[3]));
			try self.add(entry_id, entry.value);
		}
	}

	// index_id(4):TYPE(1):item_id(4)
	pub fn make_db_key_buf(self: *Self, data_type: u8) [11]u8 {
		var buf = [11]u8{0, 0, 0, 0, ':', data_type, ':', 0, 0, 0, 0};
		std.mem.writeIntNative(u32, buf[0..4], self.id);
		return buf;
	}

	pub fn add(self: *Self, id: ac.Id, value: []const u8) !void {
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
					.ngram_index = @intCast(ngram_index),
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
		entry.word_count = input.word_count;
		entry.normalized = input.normalized();
		entry._normalized_buffer = input.normalized_buffer;
	}

	pub fn count(self: *Self) usize {
		return self.entries.count();
	}
};

const Entry = struct {
	id: ac.Id,
	word_count: u8,
	normalized: []const u8, // TODO: remove
	_normalized_buffer: []const u8,
};

const NgramInfo = struct {
	entry_id: ac.Id,
	word_index: ac.WordIndex,
	ngram_index: ac.NgramIndex,
};

const t = ac.testing;
test "index: add" {
	{
		var idx = Index.init(t.allocator, .{.id = 0});
		defer idx.deinit();
		try t.expectEqual(0, idx.count());

		try idx.add(1, "silver needle");
		try t.expectEqual(1, idx.count());
		try t.expectEqual(8, idx.lookup.count());

		try idx.add(2, "white peony");
		try t.expectEqual(2, idx.count());
		try t.expectEqual(14, idx.lookup.count());

		try idx.add(3, "for never");
		try t.expectEqual(3, idx.count());

		const hits = idx.lookup.get("ver").?;
		try t.expectEqual(2, hits.items.len);
		try t.expectEqual(1, hits.items[0].entry_id);
		try t.expectEqual(0, hits.items[0].word_index);
		try t.expectEqual(3, hits.items[0].ngram_index);

		try t.expectEqual(3, hits.items[1].entry_id);
		try t.expectEqual(1, hits.items[1].word_index);
		try t.expectEqual(2, hits.items[1].ngram_index);
	}
}

test "index: populateFromDb empty" {
	t.cleanup();
	var db = try DB.init("tests/db");
	defer db.deinit();

	var idx = Index.init(t.allocator, .{.id = 0});
	defer idx.deinit();
	try idx.populateFromDb(db);
	try t.expectEqual(0, idx.entries.count());
	try t.expectEqual(0, idx.lookup.count());
}

test "index: populateFromDb input" {
	t.cleanup();
	var db = try DB.init("tests/db");
	defer db.deinit();
	try db.put(&[_]u8{45,0,0,0,':','i',':',0,0,0,5}, "silver");
	try db.put(&[_]u8{45,0,0,0,':','i',':',0,0,0,7}, "peanut");
	try db.put(&[_]u8{22,0,0,0,':','i',':',0,0,0,8}, "needle"); // different index

	var idx = Index.init(t.allocator, .{.id = 45});
	defer idx.deinit();
	try idx.populateFromDb(db);
	try t.expectEqual(2, idx.entries.count());
	try t.expectString("silver", idx.entries.get(5).?._normalized_buffer);
	try t.expectString("peanut", idx.entries.get(7).?._normalized_buffer);
	try t.expectEqual(8, idx.lookup.count());
}

test "index: make_db_key_buf" {
	var idx = Index.init(t.allocator, .{.id = 8291});
	defer idx.deinit();

	var buf = idx.make_db_key_buf('i');
	var expected = [_]u8{99, 32, 0, 0, ':', 'i', ':', 0, 0, 0, 0};
	try t.expectSlice(u8, &expected, &buf);

	buf = idx.make_db_key_buf('p');
	expected = [_]u8{99, 32, 0, 0, ':', 'p', ':', 0, 0, 0, 0};
	try t.expectSlice(u8, &expected, &buf);
}


