const std = @import("std");
const t = @import("t.zig");

const Index = @import("index.zig").Index;
const Input = @import("input.zig").Input;

const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;

pub const MAX_RESULTS = 10;
const abs = std.math.abs;

// the entry_id is the key in our map
const EntryScore = struct {
	// the running score for this entry
	score: u16,

	// the word_index of our last match
	word_index: Input.WordIndexType,

	// the ngram_index of our last match
	ngram_index: Input.NgramIndexType,
};

pub fn search(a: Allocator, value: []const u8, index: Index, top_entries: *[MAX_RESULTS]u32) !usize {
	var arena = std.heap.ArenaAllocator.init(a);
	defer arena.deinit();
  const allocator = arena.allocator();

	var input = try Input.parse(allocator, value);

	// we're getting matches from here
	var lookup = index.lookup;

	// and we're accumulating scores here
	var accumulator = AutoHashMap(u32, EntryScore).init(allocator);

	// top scores/entries are mantained here
	var top = try Top.init(allocator, top_entries);

	while (input.next()) |result| {
		const word = result.value;
		for (0..word.len - 2) |ngram_index| {
			const ngram = result.value[ngram_index..ngram_index+3];
			const hits = lookup.get(ngram) orelse continue;

			const word_index = result.index;

			// this can't all be necessary, can it?
			const word_index_i32 = @as(i32, word_index);
			const ngram_index_i32 = @intCast(i32, ngram_index);
			const ngram_typed = @intCast(Input.NgramIndexType, ngram_index);

			var last_entry_id: u32 = 0;
			for (hits.items) |hit| {
				const entry_id = hit.entry_id;

				if (entry_id == last_entry_id) {
					// TODO:
					// An entry can have the same ngram multiple times. When we're indexing,
					// we keep them all. Ideally, when we're here, we want to find the best
					// possible match.
					// What we 100% don't wan to to do though is score the same ngram for
					// an entry mutliple times. So for now, we'll just pick the first one
					// we find and skip any subsequent ones. But we should see if we can
					// come up with a better option.
					// This skipping only works because we're sure all ngrams for an entry
					// are groupped together, so we only need to consider last_entry_id
					continue;
				}

				last_entry_id = entry_id;

				// any hit gets a minimum score of 1
				// (we can always filter out low scores as a final pass, but for now we
				// want to collect everything)
				var score : u16 = 1;


				// word_index and ngram_indexes are the positions within the provided input
				// entry_word_index and entry_ngram_indexes are the positions within the
				// indexes entries. The closer word_index is to entry_word_index, the better.
				// More importantly, the closer ngram_index is to entry_ngram_indexes, the better.
				const entry_word_index = hit.word_index;
				const entry_ngram_index = hit.ngram_index;


				score += switch (word_index_i32 - entry_word_index) {
					0 => 6,   // words are in the same position, quite meaningful
					1, -1 => 3, // words are off by 1, not very meangful
					2, -2 => 1, // words are off by 2, which isn't great, but still a slight boost
					else => 0,
				};

				switch (ngram_index_i32 - entry_ngram_index) {
					0 => {
						// ngrams at the right position are super important, especially early
						// in the input, like the prefix.
						if (ngram_index == 0) {
							score += 30;
						} else if (ngram_index == 1) {
							score += 15;
						} else {
							score += 10;
						}

					},
					1, -1 => score += 8, // ngram position is off by 1, pretty good, common for spelling errors
					2, -2 => score += 5, // ngram position is off by 2, still quite likely with spelling errors
					3, -3 => score += 1,
					else => {},
				}

				var gop = try accumulator.getOrPut(entry_id);
				if (gop.found_existing) {
					// We've matched this entry before
					const es = gop.value_ptr.*;
					if (es.word_index == word_index) {
						const previous_ngram_index = es.ngram_index;

						// It's possible for ngram_index == previous_ngram_index in the same

						if (ngram_index > previous_ngram_index) {
							// the -1 is because es.ngram_index was the last match, so even in the
							// best case (where we're matching the next ngram), we'll always be
							// 1 off
							const boost = 30 - (ngram_typed - previous_ngram_index - 1) * 5;
							if (boost > 0) {
								score += boost;
							}
						}
					}

					// score is cumulative, so add the score we had before
					score += es.score;
				}

				gop.value_ptr.* = EntryScore{
					.score = score,
					.word_index = word_index,
					.ngram_index = ngram_typed,
				};

				top.update(entry_id, score);
			}
		}
	}
	return top.rank();
}

// Rather than constantly keeping our full accumulator ordered, we instead
// just keep the N top scores and associated N top entries.
// We also keep the lowest of these top scores.
// If we get a score which is greater than the lowest top score (and which
// doesn't already belong to a top entry), we swap them out.
const Top = struct {
	// The lowest score in our top scores, this is the min(scores) value
	low_score: u16,

	// The index in scores where low_scores is found
	low_index: u8,

	// The list of top scores. This is not sorted
	scores: [MAX_RESULTS]u16,

	// The entry_ids corresponding to each score. Say entry_id 32 has a top score
	// at index 4, so: entries[4] == 32. Then its score is at scores[4].
	// Once rank() is called the scores and entries indexes are no longer consistent.
	entries: *[MAX_RESULTS]u32,

	// entry => index lookup. Following the above example, entra_lookup[32] == 4
	entry_lookup: AutoHashMap(u32, u8),

	const Self = @This();

	fn init(allocator: Allocator, entries: *[MAX_RESULTS]u32) !Top {
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
			var entries = self.entries;

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

	// After this is called, top should not be used, as we sort self.entries
	// based on the scores VALUE, and thus the entries indexes are no longer
	// consistent with the score.
	fn rank(self: *Self) usize {
		// we are going to sort this
		var entries = self.entries;

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

test "search" {
	var found : usize = 0;
	var entries : [MAX_RESULTS]u32 = undefined;

	{
		// empty index
		var index = try Index.init(t.allocator);
		defer index.deinit();
		found = try search(t.allocator, "anything", index, &entries);
		try t.expectEqual(@as(usize, 0), found);
	}

	{
		// index with 1 entry
		var index = try Index.init(t.allocator);
		defer index.deinit();
		try index.add(99, "silver needle");

		found = try search(t.allocator, "nope", index, &entries);
		try t.expectEqual(@as(usize, 0), found);

		const inputs = [_][]const u8 {"silver needle", "silver", "needle", "  SilVER", "silvar", "need"};
		for (inputs) |input| {
			found = try search(t.allocator, input, index, &entries);
			try t.expectEqual(found, 1);
			try t.expectEqual(@as(u32, 99), entries[0]);
		}
	}

	{
		// index with multiple entries
		var index = try Index.init(t.allocator);
		defer index.deinit();
		try index.add(50, "silver needle");
		try index.add(60, "keemun");
		try index.add(70, "iron goddess");
		try index.add(80, "dragon well");
		try index.add(90, "yellow mountain");

		found = try search(t.allocator, "nope", index, &entries);
		try t.expectEqual(@as(usize, 0), found);

		found = try search(t.allocator, "kee", index, &entries);
		try t.expectEqual(found, 1);
		try t.expectEqual(@as(u32, 60), entries[0]);

		found = try search(t.allocator, "yellow", index, &entries);
		try t.expectEqual(found, 2);
		try t.expectEqual(@as(u32, 90), entries[0]);
		try t.expectEqual(@as(u32, 80), entries[1]);

		found = try search(t.allocator, "ell dragon", index, &entries);
		try t.expectEqual(found, 2);
		try t.expectEqual(@as(u32, 90), entries[0]);
		try t.expectEqual(@as(u32, 80), entries[1]);
	}

	{
		var index = try Index.init(t.allocator);
		defer index.deinit();
		try index.add(50, "among famous books");

		found = try search(t.allocator, "mon amour", index, &entries);
		try t.expectEqual(found, 1);
	}

}

test "top" {
	var entries : [MAX_RESULTS]u32 = undefined;
	{
		// single result
		var top = try Top.init(t.allocator, &entries);
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
		var top = try Top.init(t.allocator, &entries);
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
		var top = try Top.init(t.allocator, &entries);
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
