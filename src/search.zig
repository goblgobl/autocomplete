const std = @import("std");
const ac = @import("lib.zig");

const Index = ac.Index;
const Input = ac.Input;

const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;

const abs = std.math.abs;

// the entry_id is the key in our map
const EntryScore = struct {
	// the running score for this entry
	score: u16,

	// the word_index of our last match
	word_index: ac.WordIndex,

	// the ngram_index of our last match
	ngram_index: ac.NgramIndex,
};

pub fn search(a: Allocator, value: []const u8, idx: *Index, ap: *AccumulatorPool, top_entries: *ac.IdCollector) !usize {
	var arena = std.heap.ArenaAllocator.init(a);
	defer arena.deinit();
	const allocator = arena.allocator();

	var input = try Input.parse(allocator, value);

	// we're getting matches from here
	var lookup = idx.lookup;

	// and we're accumulating scores here
	// var accumulator = AutoHashMap(ac.Id, EntryScore).init(allocator);
	// _ = ap;
	var accumulator = try ap.acquire();
	defer ap.release(accumulator);

	// top scores/entries are mantained here
	var top = Top.init(top_entries);

	while (input.next()) |result| {
		const word = result.value;
		for (0..word.len - 2) |ngram_index| {
			const ngram = result.value[ngram_index..ngram_index+3];
			const matches = lookup.get(ngram) orelse continue;

			const word_index = result.index;
			const ngram_typed: ac.NgramIndex = @intCast(ngram_index);

			var last_entry_id: ac.Id = 0;
			for (matches.items) |match| {
				const entry_id = match.entry_id;

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

				// any match gets a minimum score of 1
				// (we can always filter out low scores as a final pass, but for now we
				// want to collect everything)
				var score : u16 = 1;

				// word_index and ngram_indexes are the positions within the provided input
				// entry_word_index and entry_ngram_indexes are the positions within the
				// indexes entries. The closer word_index is to entry_word_index, the better.
				// More importantly, the closer ngram_index is to entry_ngram_indexes, the better.
				const entry_word_index = match.word_index;
				const entry_ngram_index = match.ngram_index;

				score += switch (@as(i16, word_index) - entry_word_index) {
					0 => 6,   // words are in the same position, quite meaningful
					1, -1 => 3, // words are off by 1, not very meanigful
					2, -2 => 1, // words are off by 2, which isn't great, but still a slight boost
					else => 0,
				};

				switch (@as(i16, ngram_typed) - entry_ngram_index) {
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

				var gop = try accumulator.getOrPut(entry_id, ap);
				if (gop.found_existing) {
					// We've matched this entry before
					const es = gop.value_ptr.*;
					if (es.word_index == word_index) {
						const previous_ngram_index = es.ngram_index;

						// It's possible for ngram_index == previous_ngram_index in the same word
						if (ngram_index > previous_ngram_index) {
							// We "boost" the score based on how close this ngram is to the previous
							// matched ngram. The max boost is 30. For every 1 position apart
							// current is from previous, the boost decreases by 5.
							// Say the previous ngram was at position 3 and the current is at
							// position 4 (this is very good, it's 2 consecutive ngrams), the
							// boost will be the full 30 =
							//    30 - (4 - 3 - 1) * 5  ->  30 - 0 * 5  ->  30
							// Say the previous ngram was 2 and now we're at 5, the boost is:
							//    30 - (5 - 2 - 1) * 5  ->  30 - 2 * 5  ->  20
							const diff = ngram_typed - previous_ngram_index - 1;
							if (diff < 6) {
								score += 30 - (diff * 5);
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
	scores: [ac.MAX_RESULTS]u16,

	// The entry_ids corresponding to each score. Say entry_id 32 has a top score
	// at index 4, so: entries[4] == 32. Then its score is at scores[4].
	// Once rank() is called the scores and entries indexes are no longer consistent.
	entries: *ac.IdCollector,

	// entry => index lookup. Following the above example, entry_lookup[32] == 4
	entry_lookup: KeyValue(ac.Id, u8),

	const Self = @This();

	fn init(entries: *ac.IdCollector) Top {
		return Top{
			.low_score = 0,
			.low_index = 0,
			.entries = entries,
			.scores = [_]u16{0} ** ac.MAX_RESULTS,
			.entry_lookup = KeyValue(ac.Id, u8).init(),
		};
	}

	fn update(self: *Self, entry_id: ac.Id, new_score: u16) void {
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

		} else if (entry_lookup.len < ac.MAX_RESULTS) {
			const index: u8 = @intCast(entry_lookup.len);
			entry_lookup.add(entry_id, index);

			scores[index] = new_score;
			self.entries[index] = entry_id;
			if (new_score < low_score) {
				self.low_score = new_score;
				self.low_index = index;
			}
		} else if (new_score > low_score) {
			var entries = self.entries;

			// we have a score for an entry which IS not currently in the top entries
			// but which now has a score higher than our lowest top score

			// The first thing we'll do is swap out the old lowest score with this new score
			scores[low_index] = new_score;
			entry_lookup.replaceOrPut(entries[low_index], entry_id, low_index);
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
					low_index = @intCast(i);
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
		var scores = self.scores;
		const entry_count = self.entry_lookup.len;

		// linear insertion sort
		// We need j to be a usize, to access arrays, but we need it to go to -1
		// so that we can use [j+1] when setting the final position of the element.
		// We rely on Zig's guarantee wraparound operators to get over this.
		var i : usize = 1;
		const maxUsize = std.math.maxInt(usize);
		while (i < entry_count) : (i += 1) {
			const score = scores[i];
			const entry = entries[i];
			var j: usize = i - 1;
			while (j != maxUsize and score >= scores[j]) : (j -%= 1) {
				scores[j + 1] = scores[j];
				entries[j + 1] = entries[j];
			}
			scores[j+%1] = score;
			entries[j+%1] = entry;
		}

		return entry_count;
	}
};

// An optimized key=>value lookup for Top. Since we have a hard and small upper
// limit on the size, and don't need to delete, implementing this as two arrays
// is faster.
fn KeyValue(comptime K: type, comptime V: type) type {
	return struct {
		len: usize,
		keys: [ac.MAX_RESULTS]K,
		values: [ac.MAX_RESULTS]V,

		const Self = @This();

		fn init() Self {
			return .{
				.len = 0,
				.keys = std.mem.zeroes([ac.MAX_RESULTS]K),
				.values = std.mem.zeroes([ac.MAX_RESULTS]V),
			};
		}

		fn get(self: Self, key: K) ?V {
			@setRuntimeSafety(false);
			std.debug.assert(ac.MAX_RESULTS == 10);
			const keys = &self.keys;
			if (keys[0] == key) return self.values[0];
			if (keys[1] == key) return self.values[1];
			if (keys[2] == key) return self.values[2];
			if (keys[3] == key) return self.values[3];
			if (keys[4] == key) return self.values[4];
			if (keys[5] == key) return self.values[5];
			if (keys[6] == key) return self.values[6];
			if (keys[7] == key) return self.values[7];
			if (keys[8] == key) return self.values[8];
			if (keys[9] == key) return self.values[9];
			return null;
		}

		fn add(self: *Self, key: K, value: V) void {
			const len = self.len;
			std.debug.assert(len < self.keys.len);
			self.keys[len] = key;
			self.values[len] = value;
			self.len = len + 1;
		}

		fn replaceOrPut(self: *Self, key_to_replace: K, key_to_add: K, value_to_add: V) void {
			const len = self.len;
			for (self.keys[0..len], 0..) |k, i| {
				if (k == key_to_replace) {
					self.keys[i] = key_to_add;
					self.values[i] = value_to_add;
					return;
				}
			}
			std.debug.assert(len < self.keys.len);
			self.keys[len] = key_to_add;
			self.values[len] = value_to_add;
			self.len = len + 1;
		}
	};
}

pub const Accumulator = struct {
	const SIZE = 32768;
	const SIZE_MASK = SIZE - 1;
	const STATE_BITS = SIZE / 64;
	const GROW_SIZE : u16 = @intFromFloat(SIZE * 0.7);

	size: usize = 0,
	ids: [SIZE]ac.Id = std.mem.zeroes([SIZE]ac.Id),
	states: [STATE_BITS]u64 = std.mem.zeroes([STATE_BITS]u64),
	scores: [SIZE]EntryScore = undefined,
	next: ?*Accumulator = null,

	const GetOrPutResult = struct {
		found_existing: bool,
		value_ptr: *EntryScore,
	};

	const ProbeResult = struct {
		found: bool,
		idx: u16,
		slot: u64,
		bucket: u16,
	};

	fn init() Accumulator {
		return .{};
	}

	fn reset(self:* Accumulator) void {
		self.size = 0;
		self.next = null;
		for (&self.states) |*i| {
			i.* = 0;
		}
	}

	fn getOrPut(self: *Accumulator, id: ac.Id, pool: *AccumulatorPool) !GetOrPutResult {
		var pr = self.find(id);

		if (pr.found) {
			// we found the entry, return it
			return .{
				.found_existing = true,
				.value_ptr = &self.scores[pr.idx],
			};
		}

		if (self.next) |next| {
			// we didn't find the entry, and we have a chained accumulator,
			// delegate to it
			return next.getOrPut(id, pool);
		}

		if (try self.conditionallyGrow(pool)) |next| {
			// we didn't find the entry, but we just added a chained accumulator,
			// delegate to it.
			return next.getOrPut(id, pool);
		}

		// We didn't find the entry, we have no chained accumulator, put the entry
		// in the (non-ideal) spot that we did find
		self.size += 1;
		const idx = pr.idx;
		self.ids[idx] = id;
		self.states[pr.bucket] |= pr.slot;
		return .{
			.found_existing = false,
			.value_ptr = &self.scores[idx],
		};
	}

	fn find(self: *Accumulator, id: ac.Id) ProbeResult {
		const ids = &self.ids;
		const states = &self.states;

		var h = hash(id);
		while (true) : (h += 1) {
			const idx: u16 = @intCast(h & SIZE_MASK);
			const bucket = idx / 64;
			const slot = @as(u64, 1) << @intCast(idx & 63);

			if (states[bucket] & slot == 0) {
				return .{
					.idx = idx,
					.slot = slot,
					.found = false,
					.bucket = bucket,
				};
			}

			if (ids[idx] == id) {
				return .{
					.idx = idx,
					.slot = slot,
					.found = true,
					.bucket = bucket,
				};
			}
		}

		unreachable;
	}

	fn conditionallyGrow(self: *Accumulator, pool: *AccumulatorPool) !?*Accumulator{
		if (self.size < GROW_SIZE) {
			return null;
		}
		const acc = try pool.acquire();
		self.next = acc;
		return acc;
	}
};

fn hash(x: ac.Id) u64 {
	var h: u64 = @intCast(x);
	h ^= h >> 16;
	h *%= 0x7feb352d;
	h ^= h >> 15;
	h *%= 0x846ca68b;
	h ^= h >> 16;
	return h;
}

// fn hash(x: ac.Id ) u64 {
// 	return std.hash.Wyhash.hash(0, std.mem.asBytes(&x));
// }

pub const AccumulatorPool = struct {
	available: usize,
	allocator: Allocator,
	mutex: std.Thread.Mutex,
	accumulators: []*Accumulator,

	pub fn init(allocator: Allocator, size: usize) !AccumulatorPool {
		const accumulators = try allocator.alloc(*Accumulator, size);
		for (0..size) |i| {
			const accumulator = try allocator.create(Accumulator);
			accumulator.* = Accumulator.init();
			accumulators[i] = accumulator;
		}

		return .{
			.mutex = .{},
			.available = size,
			.allocator = allocator,
			.accumulators = accumulators,
		};
	}

	pub fn deinit(self: *AccumulatorPool) void {
		const allocator = self.allocator;
		for (self.accumulators) |a| {
			allocator.destroy(a);
		}
		allocator.free(self.accumulators);
	}

	pub fn acquire(self: *AccumulatorPool) !*Accumulator {
		const accumulators = self.accumulators;
		self.mutex.lock();
		const available = self.available;
		if (available == 0) {
			self.mutex.unlock();
			const accumulator = try self.allocator.create(Accumulator);
			accumulator.* = Accumulator.init();
			return accumulator;
		}
		const new_available = available - 1;
		const acc = accumulators[new_available];
		self.available = new_available;
		self.mutex.unlock();

		return acc;
	}

	pub fn release(self: *AccumulatorPool, a: *Accumulator) void {
		if (a.next) |next| {
			self.release(next);
		}

		a.reset();
		const accumulators = self.accumulators;
		self.mutex.lock();

		const available = self.available;
		if (available == accumulators.len) {
			self.mutex.unlock();
			const allocator = self.allocator;
			allocator.destroy(a);
			return;
		}

		accumulators[available] = a;
		self.available = available + 1;
		self.mutex.unlock();
	}
};

const t = ac.testing;
test "search: empty index" {
	var entries : ac.IdCollector = undefined;

	var idx = Index.init(t.allocator, Index.Config{.id = 0});
	defer idx.deinit();
	const found = try search(t.allocator, "anything", &idx, &entries);
	try t.expectEqual(0, found);
}

test "search: index with 1 entry" {
	var entries : ac.IdCollector = undefined;

	var idx = Index.init(t.allocator, Index.Config{.id = 0});
	defer idx.deinit();
	try idx.add(99, "silver needle");

	var found = try search(t.allocator, "nope", &idx, &entries);
	try t.expectEqual(0, found);

	const inputs = [_][]const u8 {"silver needle", "silver", "needle", "  SilVER", "silvar", "need"};
	for (inputs) |input| {
		found = try search(t.allocator, input, &idx, &entries);
		try t.expectEqual(found, 1);
		try t.expectEqual(99, entries[0]);
	}
}

test "search: index with multiple entries" {
	var entries : ac.IdCollector = undefined;

	var idx = Index.init(t.allocator, Index.Config{.id = 0});
	defer idx.deinit();
	try idx.add(50, "silver needle");
	try idx.add(60, "keemun");
	try idx.add(70, "iron goddess");
	try idx.add(80, "dragon well");
	try idx.add(90, "yellow mountain");

	var found = try search(t.allocator, "nope", &idx, &entries);
	try t.expectEqual(0, found);

	found = try search(t.allocator, "kee", &idx, &entries);
	try t.expectEqual(found, 1);
	try t.expectEqual(60, entries[0]);

	found = try search(t.allocator, "yellow", &idx, &entries);
	try t.expectEqual(found, 2);
	try t.expectEqual(90, entries[0]);
	try t.expectEqual(80, entries[1]);

	found = try search(t.allocator, "ell dragon", &idx, &entries);
	try t.expectEqual(found, 2);
	try t.expectEqual(80, entries[0]);
	try t.expectEqual(90, entries[1]);
}

test "search: full" {
	var entries : ac.IdCollector = undefined;

	var idx = Index.init(t.allocator, Index.Config{.id = 0});
	defer idx.deinit();
	for (0..ac.MAX_RESULTS+5) |i| {
		try idx.add(@intCast(i), "cab");
	}

	var found = try search(t.allocator, "nope", &idx, &entries);
	try t.expectEqual(0, found);

	found = try search(t.allocator, "cab", &idx, &entries);
	try t.expectEqual(found, ac.MAX_RESULTS);
}

test "search: fuzzyness" {
	var entries : ac.IdCollector = undefined;

	var idx = Index.init(t.allocator, Index.Config{.id = 0});
	defer idx.deinit();
	try idx.add(50, "among famous books");

	const found = try search(t.allocator, "mon amour", &idx, &entries);
	try t.expectEqual(found, 1);
}

test "search: matching" {
	var entries : ac.IdCollector = undefined;

	var idx = Index.init(t.allocator, Index.Config{.id = 0});
	defer idx.deinit();
	try idx.add(2, "salad");
	try idx.add(3, "mild salsa");
	try idx.add(4, "hot salsa");

	const found = try search(t.allocator, "salsa", &idx, &entries);
	try t.expectEqual(found, 3);
	try t.expectEqual(4, entries[0]);
	try t.expectEqual(3, entries[1]);
	try t.expectEqual(2, entries[2]);
}

// TODO: we need to index trigrams with missing letters
// So we have our normal trigram for Rooibos:
//   roo, ooi, oib, ibo, bos
// and we'd add:
//   roi, oib, obo, ios, ibs
// test "search: fuzzyness ranking" {
// 	var found : usize = 0;
// 	var entries : ac.IdCollector = undefined;

// 	var idx = Index.init(t.allocator, Index.Config{.id = 0});
// 	defer idx.deinit();
// 	try idx.add(1, "Ciya Rooster 4.75\" Porcelain Pot");
// 	try idx.add(2, "Nature's Nutrition Organic Rooibos Tea");

// 	found = try search(t.allocator, "roobois", &idx, &entries);
// 	try t.expectEqual(found, 2);
// 	try t.expectEqual(@as(u32, 2), entries[0]);
// 	try t.expectEqual(@as(u32, 1), entries[1]);
// }

test "top" {
	var entries : ac.IdCollector = undefined;
	{
		// single result
		var top = Top.init(&entries);

		top.update(1, 1);
		var expected = [_]u32{1};
		try assertTop(&top, expected[0..]);

		// update the same entry, nothing should change
		top.update(1, 3);
		try assertTop(&top, expected[0..]);
	}

	{
		// two resutls (baby steps!)
		var top = Top.init(&entries);

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
		var top = Top.init(&entries);

		for (1..100) |i| {
			var b : u16 = @intCast(i);
			top.update(b, b);
		}

		var expected = [_]u32{99, 98, 97, 96, 95, 94, 93, 92, 91, 90};
		try assertTop(&top, expected[0..]);

		for (10..30) |i| {
			var b : u16 = @intCast(i);
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
	// the entry_lookup no longer has the correct indexes into entries and score.

	// But of testing, we'd like to make incremental changes to top and assert the
	// scores. So we'll very much hack this and re-set the internal state to be
	// correct for future calls.
	// We're able to do this because the entry_lookup keeps the entry -> index
	// which we can use to restore the entries array.
	const el = top.entry_lookup;
	for (el.keys[0..el.len], el.values[0..el.len]) |entry_id, index_id| {
		top.entries[index_id] = entry_id;
	}
}

test "KeyValue: replaceOrPut" {
	var kv = KeyValue(u32, u8).init();
	try t.expectEqual(@as(?u8, null), kv.get(32));

	kv.replaceOrPut(0, 32, 10);
	try t.expectEqual(10, kv.get(32).?);

	kv.replaceOrPut(0, 9932, 2);
	try t.expectEqual(10, kv.get(32).?);
	try t.expectEqual(2, kv.get(9932).?);

	kv.replaceOrPut(9932, 888, 3);
	try t.expectEqual(10, kv.get(32).?);
	try t.expectEqual(3, kv.get(888).?);
	try t.expectEqual(@as(?u8, null), kv.get(9932));

	kv.replaceOrPut(32, 2323, 5);
	try t.expectEqual(5, kv.get(2323).?);
	try t.expectEqual(3, kv.get(888).?);
	try t.expectEqual(@as(?u8, null), kv.get(32));
}

test "KeyValue: add" {
	var kv = KeyValue(u32, u8).init();
	try t.expectEqual(@as(?u8, null), kv.get(10));

	kv.add(10, 1);
	kv.add(11, 2);
	kv.add(12, 3);

	try t.expectEqual(1, kv.get(10).?);
	try t.expectEqual(2, kv.get(11).?);
	try t.expectEqual(3, kv.get(12).?);
}

test "Accumulator: getOrPut" {
	var pool = try AccumulatorPool.init(t.allocator, 1);
	defer pool.deinit();

	var acc = try pool.acquire();
	defer pool.release(acc);

	var gop = try acc.getOrPut(32, &pool);
	try t.expectEqual(false, gop.found_existing);
	gop.value_ptr.* = makeEntryScore(1, 2, 3);

	gop = try acc.getOrPut(32, &pool);
	try t.expectEqual(true, gop.found_existing);
	try t.expectEqual(1, gop.value_ptr.score);
}

test "Accumulator: growth" {
	var pool = try AccumulatorPool.init(t.allocator, 1);
	defer pool.deinit();

	var acc = try pool.acquire();

	for (1..10000) |i| {
		const id: u32 = @intCast(i);
		var gop = try acc.getOrPut(id, &pool);
		try t.expectEqual(false, gop.found_existing);
		gop.value_ptr.* = makeEntryScore(1, 2, 3);
	}

	for (1..10000) |i| {
		const id: u32 = @intCast(i);
		var gop = try acc.getOrPut(id, &pool);
		try t.expectEqual(true, gop.found_existing);
	}
	pool.release(acc);

	acc = try pool.acquire();
	defer pool.release(acc);
	for (1..10000) |i| {
		const id: u32 = @intCast(i);
		var gop = try acc.getOrPut(id, &pool);
		try t.expectEqual(false, gop.found_existing);
	}
}

fn makeEntryScore(score: u16, word_index: ac.WordIndex, ngram_index: ac.NgramIndex) EntryScore{
	return .{
		.score = score,
		.word_index = word_index,
		.ngram_index = ngram_index,
	};
}
