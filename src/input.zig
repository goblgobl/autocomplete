const std = @import("std");
const builtin = @import("builtin");

const t = @import("t.zig");
const ac = @import("autocomplete.zig");

const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

// Takes an input and provides an iterator over normalized word. Every
// result includes the word and the word_index.
// Normalizing means ignoring non-alphanumeric (ascii) + lowercasing the input.
pub const Input = struct {
	// The raw input. Not normalized, not trimmed. We don't own this.
	input: []const u8,

	// The normalized input. We own this, but if this is being called when adding
	// an item to the Index, the Index will take over this.
	normalized: []u8,

	// We normalize one character at a time, and this in where in normalized that
	// we're at. The final normalized.len will always be <= input.len.
	normalized_position: u32,

	// The 0-based number of words we've seen
	word_count: u3,

	const Self = @This();

	// the word that we're yielding, which includes the word itself and it's 0-based index
	const Word = struct {
		value: []const u8,
		index: ac.WordIndex,
	};

	pub fn parse(allocator: Allocator, input: []const u8) !Self {
		return Input{
			.input = input,
			.word_count = 0,
			.normalized_position = 0,
			.normalized = try allocator.alloc(u8, input.len),
		};
	}


	pub fn next(self: *Self) ?Word {
		@setRuntimeSafety(builtin.is_test);

		var word_count = self.word_count;
		if (word_count == ac.MAX_WORDS) {
			// we've reached the max number of words we support per entry
			return null;
		}

		var input = std.mem.trimLeft(u8, self.input, &ascii.whitespace);
		if (input.len == 0) {
			// no more input
			return null;
		}

		var normalized = self.normalized;
		var normalized_position = self.normalized_position;
		var word_start = normalized_position;


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

		// when next() is called again, we'll start scanning input from where we left off
		self.input = input[i..];
		self.normalized_position = normalized_position;


		if (normalized_position - word_start < 3) {
			// our "word" is only 1 or 2 characters, skip to the next word
			// TODO: remove this recursion.
			return self.next();
		}

		var word = normalized[word_start..normalized_position];
		if (word.len > ac.MAX_WORD_LENGTH) {
			word = word[0..ac.MAX_WORD_LENGTH];
		}

		self.word_count = word_count + 1;
		return Word{
			.value = word,
			.index = word_count,
		};
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
		try input.expectWord("tea", 0);
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
		try t.expectEqual(@as(usize, 1),input.lookup.count());
		try input.expectWord("keemun", 0);
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
		try t.expectEqual(@as(usize, 2),input.lookup.count());
		try input.expectWord("black", 0);
		try input.expectWord("bear", 1);
	}

	{
			// ignore short words
			var input = try testCollectInput(" Black  at");
			defer input.deinit();
			try t.expectString(input.value, "black at");
			try t.expectEqual(@as(u8, 1),input.word_count);
			try t.expectEqual(@as(usize, 1),input.lookup.count());
			try input.expectWord("black", 0);
	}

	{
		// ignore short words
		var input = try testCollectInput(" Black a  cat  ");
		defer input.deinit();
		try t.expectString(input.value, "black a cat");
		try t.expectEqual(@as(u8, 2),input.word_count);
		try t.expectEqual(@as(usize, 2),input.lookup.count());
		try input.expectWord("black", 0);
		try input.expectWord("cat", 1);
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
		try input.expectWord("0123456789012345678901234567abc", 0);
		try input.expectWord("0123456789012345678901234567vwx", 1);
}

const ParseTestResult = struct {
	value: []const u8,
	word_count: u8,
	lookup: StringHashMap(ac.WordIndex),

	const Self = @This();

	fn expectWord(self: Self, word: []const u8, word_index: ac.WordIndex) !void {
		var actual = self.lookup.get(word) orelse unreachable;
		try t.expectEqual(word_index, actual);
	}

	fn deinit(self: *Self) void {
		t.allocator.free(self.value);
		self.lookup.deinit();
		self.* = undefined;
	}
};

fn testCollectInput(value: []const u8) !ParseTestResult {
	var lookup = StringHashMap(ac.WordIndex).init(t.allocator);
	var input = try Input.parse(t.allocator, value);
	while (input.next()) |word| {
		try lookup.put(word.value, word.index);
	}
	return ParseTestResult{
		.lookup = lookup,
		.value = input.getNormalized(),
		.word_count = input.word_count,
	};
}
