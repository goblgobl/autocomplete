const std = @import("std");
const t = @import("t.zig");
const Index = @import("index.zig").Index;
const Input = @import("input.zig").Input;

const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;

const MAX_RESULTS = 10;


const EntryTracker = struct {
	score: u16,
	word_index: Input.WordIndexType,
	ngram_index: Input.NgramIndexType,
};

pub fn search(a: Allocator, value: []const u8, index: Index, top_entries: [MAX_RESULTS]u32) !usize {
	var arena = std.heap.ArenaAllocator.init(a);
	defer arena.deinit();
  const allocator = arena.allocator();

	var input = Input.parse(allocator, value);

	// we're getting matches from here
	var lookup = index.lookups;

	// and we're accumulating scores here
	var accumulator = try AutoHashMap(u32, EntryTracker).init(allocator);

	// top scores/entries are mantained here
	var top = Top.init(allocator, top_entries);

	while (input.next()) |result| {
		const hits = lookup.get(result.value) orelse continue;
		for (hits) |hit| {
			const entry_id = hit.entry_id;
			var score : u16 = 0;
			var gop = try accumulator.getOrPut(entry_id);
			if (gop.found_existing) {
				score = gop.value_ptr.score + 1;
			} else {
				score = gop.value_ptr.score + 1;
			}

			gop.value_ptr.score = score;
			top.update(entry_id, score);
		}
	}
	return top.rank();
}

// Rather than constantly keeping our accumulator ordered, we instead
// just keep the N top scores and associated N top entries.
// We also keep the lowest of these top scores.
// If we get a score which is greater than the lowest top score (and which
// doesn't already belong to a top entry), we swap them out.

const Top = struct {
	low_index: u8,
	low_score: u16,
	scores: [MAX_RESULTS]u16,
	entries: [MAX_RESULTS]u32,
	entry_lookup: AutoHashMap(u32, u8),

	const Self = @This();

	fn init(allocator: Allocator, entries: [MAX_RESULTS]u32) !Top {
		var entry_lookup = AutoHashMap(u32, u8).init(allocator);
		try entry_lookup.ensureTotalCapacity(MAX_RESULTS);

		return Top{
			.low_score = 0,
			.low_index = 0,
			.entries = entries,
			.scores = [_]u16{0} ** MAX_RESULTS,
			.entry_lookup = entry_lookup,
		};
	}

	fn update(self: *Self, entry_id: u32, new_score: u16) void {
		var scores = &self.scores;
		var low_score = self.low_score;
		var low_index = self.low_index;
		var entry_lookup = &self.entry_lookup;

		var find_new_low = false;

		if (entry_lookup.get(entry_id)) |score_index| {
			// This entry is already a top entry, we need to update its score
			const existing_score = scores[score_index];
			scores[score_index] = new_score;

			if ( existing_score == low_score) {
				// if this entry had our lowest score, it might no longer, so we'll have
				// to find the new lowest score.
				low_score = new_score;
				find_new_low = true;
			}

		} else if (new_score > low_score) {
			var entries = &self.entries;

			// we have a score for an entry which IS not currently in the top entries
			// but which now has a score higher than our lowest top score

			// The first thing we'll do is swap out the old lowest score with this new score
			scores[low_index] = new_score;
			_ = entry_lookup.remove(entries[low_index]);
			entry_lookup.putAssumeCapacity(entry_id, low_index);
			entries[low_index] = entry_id;

			// there's no guarantee that this new score is the lowest, we'll have to
			// find the new lowest
			low_score = new_score;
			find_new_low = true;
		}

		if (find_new_low) {
			for (scores, 0..) |s, i| {
				if (s < low_score) {
					low_score = s;
					low_index = @intCast(u8, i);
				}
			}
			self.low_score = low_score;
			self.low_index = low_index;
		}
	}

	fn rank(self: *Self) usize {
		// we are going to sort this
		var entries = &self.entries;

		// based on this
		const scores = self.scores;
		const entry_count = self.entry_lookup.count();

		var i : usize = 1;
		while (i < entry_count) : (i += 1) {
			var j : usize = i;
			while (j > 0 and scores[j-1] < scores[j]) : (j -= 1) {
				const tmp = entries[j];
				entries[j] = entries[j-1];
				entries[j-1] = tmp;
			}
		}

		return entry_count;
	}
};


test "top" {
	var entries : [MAX_RESULTS]u32 = undefined;
	{
		// single result
		var top = try Top.init(t.allocator, entries);
		defer top.entry_lookup.deinit();

		top.update(1, 1);
		var expected = [_]u32{1};
		try assertTop(&top, expected[0..]);


		// update the same entry, nothing should change
		top.update(1, 3);
		try assertTop(&top, expected[0..]);
	}

	{
		// two resutls (baby steps!)
		var top = try Top.init(t.allocator, entries);
		defer top.entry_lookup.deinit();

		top.update(1, 1);
		top.update(2, 2);
		var expected = [_]u32{2, 1};
		try assertTop(&top, expected[0..]);

		top.update(1, 3);
		expected = [_]u32{1, 2};
		try assertTop(&top, expected[0..]);
	}

	{
		// many results
		var top = try Top.init(t.allocator, entries);
		defer top.entry_lookup.deinit();

		for (1..100) |i| {
			var b : u16 = @intCast(u16, i);
			top.update(b, b);
		}

		var expected = [_]u32{99, 98, 97, 96, 95, 94, 93, 92, 91, 90};
		try assertTop(&top, expected[0..]);

		for (10..30) |i| {
			var b : u16 = @intCast(u16, i);
			top.update(b, b + 100);
		}
		expected = [_]u32{29, 28, 27, 26, 25, 24, 23, 22, 21, 20};
		try assertTop(&top, expected[0..]);
	}
}


fn assertTop(top: *Top, expected: []u32) !void {
	const n = top.rank();
	const entries = top.entries[0..n];
	try t.expectEqual(expected.len, entries.len);
	for (expected, entries) |e, a| {
		try t.expectEqual(e, a);
	}

	// Once rank is called, top's internal state becomes inconsistent. Specifically
	// the indexes of scores no longer matches the indexes of entries (because
	// entries has been sorted).

	// But of testing, we'd like to make incremental changes to top and assert the
	// scores. So we'll very much hack this and re-set the internal state to be
	// correct for future calls.
	// We're able to do this because the entry_lookup keeps the entry -> index
	// which we can use to restore the entries array.
	var it = top.entry_lookup.iterator();
	while (it.next()) |entry| {
		top.entries[entry.value_ptr.*] = entry.key_ptr.*;
	}
}
