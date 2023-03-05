const std = @import("std");
const builtin = @import("builtin");
const t = @import("t.zig");

const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

const MAX_WORDS = (1 << @bitSizeOf(Input.WordIndexType)) - 1;
const MAX_WORD_LENGTH = (1 << @bitSizeOf(Input.NgramIndexType)) - 1;

// Takes an input and provides an iterator over normalized trigram. Every
// result includes the word, the word_index and the ngram_index (the index in
// the word where the trigram starts).
// Normalizing means ignoring non-alphanumeric (ascii) + lowercasing the input.
pub const Input = struct {
	input: []const u8,
	normalized_position: u32,
	normalized: []u8,
	word_count: u3,
	word_state: ?WordState,

	const Self = @This();

	pub const WordIndexType = u3;
	pub const NgramIndexType = u5;

	const WordState = struct {
		word: []const u8,
		word_index: WordIndexType,
		ngram_index: NgramIndexType,
	};

	pub fn parse(allocator: Allocator, input: []const u8) !Self {
		return Input{
			.input = input,
			.word_count = 0,
			.word_state = null,
			.normalized_position = 0,
			.normalized = try allocator.alloc(u8, input.len),
		};
	}

	// The iterator works by internally finding a word, and then yielding an trigram
	// at a time of that word.
	pub fn next(self: *Self) ?WordState {
		@setRuntimeSafety(builtin.is_test);

		if (self.word_state) |*ws| {
			// we've previously found a word, we need to yield the next trigram from it
			const word = ws.word;
			const ngram_index = ws.ngram_index;
			if (ngram_index < word.len - 3) {
				// yield
				ws.*.ngram_index += 1;
				return ws.*;
			}

			// we only have 2 characters of the word left, set the word_state to null
			// and go look for the next word
			self.word_state = null;
		}

		// we're going to find the next word (and normalize it).

		var normalized = self.normalized;

		var normalized_position = self.normalized_position;
		var word_start = normalized_position;
		var input = std.mem.trimLeft(u8, self.input, &ascii.whitespace);

		if (input.len == 0) {
			return null;
		}

		var word_count = self.word_count;
		if (word_count > 0) {
			normalized[normalized_position] = ' ';
			normalized_position += 1;
			word_start += 1;
		}

		var i: u32 = 0;
		for (input) |b| {
			i += 1;
			if (ascii.isAlphanumeric(b)) {
				normalized[normalized_position] = ascii.toLower(b);
				normalized_position += 1;
				continue;
			}

			if (b == ' ') {
				break;
			}
		}


		self.input = input[i..];
		self.normalized_position = normalized_position;

		if (normalized_position - word_start > 2) {
			var word = normalized[word_start..normalized_position];
			if (word.len > MAX_WORD_LENGTH) {
				word = word[0..MAX_WORD_LENGTH];
			}
			self.word_state = WordState{
				.word = word,
				.ngram_index = 0,
				.word_index = word_count,
			};

			if (word_count == MAX_WORDS) {
				return null;
			}

			self.word_count = word_count + 1;
			return self.word_state;
		}
		return self.next();
	}

	pub fn getNormalized(self: Self) []const u8 {
		return self.normalized[0..self.normalized_position];
	}
};

test "parse single word" {
	{
		// 2 letter word
		var input = try testCollectInput("hi");
		defer input.deinit();
		try t.expectEqual(@as(u8, 0), input.word_count);
		try t.expectEqual(@as(usize, 0), input.lookup.count());
	}

	{
		// 3 letter word
		var input = try testCollectInput("Tea");
		defer input.deinit();
		try t.expectString("tea", input.value,);
		try t.expectEqual(@as(u8, 1),input.word_count);
		try t.expectEqual(@as(usize, 1),input.lookup.count());
		try input.expectNgram("tea", 0, 0);
	}

	const values = [_][]const u8{
		"Keemun", " keEMun", "keeMUN ", "  keemun", "KEEMUN  ", " keemun ", "  KEEmUN  ",
		" Kee%mun ", "keemun\t", "\t\nkeemun", "Kee-mun"
	};
	for (values) |value| {
		var input = try testCollectInput(value);
		defer input.deinit();
		try t.expectString(input.value, "keemun");
		try t.expectEqual(@as(u8, 1),input.word_count);
		try t.expectEqual(@as(usize, 4),input.lookup.count());
		try input.expectNgram("kee", 0, 0);
		try input.expectNgram("eem", 0, 1);
		try input.expectNgram("emu", 0, 2);
		try input.expectNgram("mun", 0, 3);
	}
}

test "parse two word" {
	const values = [_][]const u8{
		"black bear",
		" black bear",
		"black bear ",
		" black Bear ",
		"  black bear  ",
		"BLACK    BEAR",
		" BLACK    BEAR  ",
	};

	for (values) |value| {
		var input = try testCollectInput(value);
		defer input.deinit();
		try t.expectString(input.value, "black bear");
		try t.expectEqual(@as(u8, 2),input.word_count);
		try t.expectEqual(@as(usize, 5),input.lookup.count());
		try input.expectNgram("bla", 0, 0);
		try input.expectNgram("lac", 0, 1);
		try input.expectNgram("ack", 0, 2);
		try input.expectNgram("bea", 1, 0);
		try input.expectNgram("ear", 1, 1);
	}

	{
			// ignore short words
			var input = try testCollectInput(" Black  at");
			defer input.deinit();
			try t.expectString(input.value, "black at");
			try t.expectEqual(@as(u8, 1),input.word_count);
			try t.expectEqual(@as(usize, 3),input.lookup.count());
			try input.expectNgram("bla", 0, 0);
			try input.expectNgram("lac", 0, 1);
			try input.expectNgram("ack", 0, 2);
	}

	{
		// ignore short words
		var input = try testCollectInput(" Black a  cat  ");
		defer input.deinit();
		try t.expectString(input.value, "black a cat");
		try t.expectEqual(@as(u8, 2),input.word_count);
		try t.expectEqual(@as(usize, 4),input.lookup.count());
		try input.expectNgram("bla", 0, 0);
		try input.expectNgram("lac", 0, 1);
		try input.expectNgram("ack", 0, 2);
		try input.expectNgram("cat", 1, 0);
	}
}

test "stops at 8 words" {
		var input = try testCollectInput("wrd1 wrd2 wrd3 wrd4 wrd5 wrd6 wrd7 wrd8 wrd9");
		defer input.deinit();
		try t.expectEqual(@as(u8, 7), input.word_count);
}

test "stops at 31 character words" {
		var input = try testCollectInput("0123456789012345678901234567ABC 0123456789012345678901234567VWXYZ");
		defer input.deinit();
		try t.expectEqual(@as(u8, 2), input.word_count);
		try input.expectNgram("abc", 0, 28);
		try input.expectNgram("vwx", 1, 28);
		try input.noNgram("wxy");
		try input.noNgram("xyz");
}

const ParseTestResult = struct {
	value: []const u8,
	word_count: u8,
	lookup: StringHashMap(Position),

	const Self = @This();

	const Position = struct {
		word_index: Input.WordIndexType,
		ngram_index: Input.NgramIndexType,
	};

	fn expectNgram(self: Self, ngram: []const u8, word_index: Input.WordIndexType, ngram_index: Input.NgramIndexType) !void {
		var p = self.lookup.get(ngram) orelse unreachable;
		try t.expectEqual(word_index, p.word_index);
		try t.expectEqual(ngram_index, p.ngram_index);
	}

	fn noNgram(self: Self, ngram: []const u8) !void {
		try t.expectEqual(false, self.lookup.contains(ngram));
	}

	fn deinit(self: *Self) void {
		t.allocator.free(self.value);
		self.lookup.deinit();
		self.* = undefined;
	}
};

fn testCollectInput(value: []const u8) !ParseTestResult {
	var lookup = StringHashMap(ParseTestResult.Position).init(t.allocator);
	var input = try Input.parse(t.allocator, value);
	while (input.next()) |result| {
		const ngram_index = result.ngram_index;
		const ngram = result.word[ngram_index..ngram_index+3];
		try lookup.put(ngram, ParseTestResult.Position{
			.word_index = result.word_index,
			.ngram_index = ngram_index,
		});
	}
	return ParseTestResult{
		.lookup = lookup,
		.value = input.getNormalized(),
		.word_count = input.word_count,
	};
}
