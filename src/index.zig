const std = @import("std");
const t = @import("t.zig");
const Input = @import("input.zig").Input;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

pub const Index = struct {
	allocator: Allocator,
	entries: ArrayList(*Entry),
	lookup: StringHashMap(ArrayList(NgramPosition)),

	const Self = @This();

	pub fn init(allocator: Allocator) !Index {
		return Index{
			.allocator = allocator,
			.entries = ArrayList(*Entry).init(allocator),
			.lookup = StringHashMap(ArrayList(NgramPosition)).init(allocator),
		};
	}

	pub fn add(self: *Self, id: u32, value: []const u8) !void {
		std.debug.assert(value.len < 255);

		const allocator = self.allocator;

		var entry = try allocator.create(Entry);
		entry.id = id;
		try self.entries.append(entry);

		var lookup = &self.lookup;
		var input = try Input.parse(allocator, value);
		while (input.next()) |result| {
			const np = NgramPosition{
				.entry = entry,
				.position = result.position,
				.word_index = result.word_index,
			};

			var gop = try lookup.getOrPut(result.ngram);
			if (gop.found_existing) {
				try gop.value_ptr.append(np);
			} else {
				var list = ArrayList(NgramPosition).init(allocator);
				try list.append(np);
				gop.value_ptr.* = list;
			}
		}
		entry.value = input.getNormalized();
		entry.word_count = input.word_count;
	}

	pub fn count(self: *Self) usize {
		return self.entries.items.len;
	}

	pub fn deinit(self: *Self) void {
		const allocator = self.allocator;

		for (self.entries.items) |entry| {
			entry.deinit(allocator);
			allocator.destroy(entry);
		}
		self.entries.deinit();

		var it = self.lookup.valueIterator();
		while (it.next()) |list| {
			list.deinit();
		}
		self.lookup.deinit();

		self.* = undefined;
	}
};

const Entry = struct {
	id: u32,
	value: []const u8,
	word_count: u8,

	const Self = @This();

	pub fn deinit(self: *Self, allocator: Allocator) void {
		allocator.free(self.value);
		self.* = undefined;
	}
};

const NgramPosition = struct {
	position: u8,
	word_index: u8,
	entry: *Entry,
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
		try t.expectEqual(hits.items[0].entry.id, 1);
		try t.expectEqual(hits.items[0].position, 3);
		try t.expectEqual(hits.items[0].word_index, 0);

		try t.expectEqual(hits.items[1].entry.id, 3);
		try t.expectEqual(hits.items[1].position, 2);
		try t.expectEqual(hits.items[1].word_index, 1);
	}
}
