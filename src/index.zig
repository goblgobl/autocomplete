const std = @import("std");
const t = @import("t.zig");
const Input = @import("input.zig").Input;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const StringHashMap = std.StringHashMap;

pub const Index = struct {
	allocator: Allocator,
	entries: AutoHashMap(u32, *Entry),
	lookup: StringHashMap(ArrayList(NgramInfo)),

	const Self = @This();

	pub fn init(allocator: Allocator) !Index {
		return Index{
			.allocator = allocator,
			.entries = AutoHashMap(u32, *Entry).init(allocator),
			.lookup = StringHashMap(ArrayList(NgramInfo)).init(allocator),
		};
	}

	pub fn add(self: *Self, id: u32, value: []const u8) !void {
		std.debug.assert(value.len < 255);

		const allocator = self.allocator;

		var entry = try allocator.create(Entry);
		entry.id = id;
		try self.entries.put(id, entry);

		var lookup = &self.lookup;
		var input = try Input.parse(allocator, value);
		while (input.next()) |result| {
			const ngram_index= result.ngram_index;
			const np = NgramInfo{
				.entry_id = id,
				.word_index = result.word_index,
				.ngram_index = ngram_index,
			};

			const ngram = result.word[ngram_index..ngram_index+3];
			var gop = try lookup.getOrPut(ngram);
			if (gop.found_existing) {
				try gop.value_ptr.append(np);
			} else {
				var list = ArrayList(NgramInfo).init(allocator);
				try list.append(np);
				gop.value_ptr.* = list;
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
	id: u32,
	word_count: u8,
	value: []const u8,
};

const NgramInfo = struct {
	entry_id: u32,
	word_index: Input.WordIndexType,
	ngram_index: Input.NgramIndexType,
};

test "index add" {
	{
		var db = try Index.init(t.allocator);
		defer db.deinit();
		try t.expectEqual(db.count(), 0);

		try db.add(1, "silver needle");
		try t.expectEqual(db.count(), 1);
		try t.expectEqual(db.lookup.count(), 8);

		try db.add(2, "white peony");
		try t.expectEqual(db.count(), 2);
		try t.expectEqual(db.lookup.count(), 14);

		try db.add(3, "for never");
		try t.expectEqual(db.count(), 3);

		const hits = db.lookup.get("ver").?;
		try t.expectEqual(hits.items.len, 2);
		try t.expectEqual(hits.items[0].entry_id, 1);
		try t.expectEqual(hits.items[0].word_index, 0);
		try t.expectEqual(hits.items[0].ngram_index, 3);

		try t.expectEqual(hits.items[1].entry_id, 3);
		try t.expectEqual(hits.items[1].word_index, 1);
		try t.expectEqual(hits.items[1].ngram_index, 2);
	}
}
