const std = @import("std");
const builtin = @import("builtin");
const t = @import("t.zig");

const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

pub const Database = struct {
    allocator: Allocator,
    entries: ArrayList(*Entry),
    lookup: StringHashMap(ArrayList(NgramPosition)),

    const Self = @This();

    pub fn init(allocator: Allocator) !Database {
        return Database{
            .allocator = allocator,
            .entries = ArrayList(*Entry).init(allocator),
            .lookup = StringHashMap(ArrayList(NgramPosition)).init(allocator),
        };
    }

    pub fn add(self: *Self, id: u32, input: []const u8) !void {
        const allocator = self.allocator;

        var entry = try allocator.create(Entry);
        entry.id = id;
        try self.entries.append(entry);

        var lookup = &self.lookup;
        var parser = try parse(allocator, input);
        while (parser.next()) |result| {
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
        entry.input = parser.getNormalized();
        entry.word_count = parser.word_count;
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

test "database add" {
    {
        var db = try Database.init(t.allocator);
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

const Entry = struct {
    id: u32,
    input: []const u8,
    word_count: u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.input);
        self.* = undefined;
    }
};

const NgramPosition = struct {
    position: u8,
    word_index: u8,
    entry: *Entry,
};

const Parser = struct {
    input: []const u8,
    normalized_position: u32,
    normalized: []u8,
    word_count: u8,
    word_state: ?WordState,

    const Self = @This();

    const Result = struct {
        ngram: []const u8,
        position: u8,
        word_index: u8,
    };

    const WordState = struct {
        index: u8,
        position: u8,
        word: []const u8,
    };

    fn next(self: *Self) ?Result {
        @setRuntimeSafety(builtin.is_test);

        if (self.word_state) |ws| {
            const word = ws.word;
            const position = ws.position;
            if (position < word.len - 2) {
                self.word_state = WordState{
                    .word = word,
                    .index = ws.index,
                    .position = position + 1,
                };

                return Result{
                    .position = position,
                    .ngram = word[position .. position + 3],
                    .word_index = ws.index,
                };
            }
            self.word_state = null;
        }

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
            self.word_state = WordState{
                .position = 0,
                .index = word_count,
                .word = normalized[word_start..normalized_position],
            };

            self.word_count = word_count + 1;
        }
        return self.next();
    }

    fn getNormalized(self: Self) []const u8 {
        return self.normalized[0..self.normalized_position];
    }
};

fn parse(allocator: Allocator, input: []const u8) !Parser {
    return Parser{
        .input = input,
        .word_count = 0,
        .word_state = null,
        .normalized_position = 0,
        .normalized = try allocator.alloc(u8, input.len),
    };
}

test "parse single word" {
    {
        // 2 letter word
        var parsed = try testCollectParser("hi");
        defer parsed.deinit();
        try t.expectEqual(parsed.word_count, 0);
        try t.expectEqual(parsed.lookup.count(), 0);
    }

    {
        // 3 letter word
        var parsed = try testCollectParser("Tea");
        defer parsed.deinit();
        try t.expectString(parsed.input, "tea");
        try t.expectEqual(parsed.word_count, 1);
        try t.expectEqual(parsed.lookup.count(), 1);
        try parsed.expectNgram("tea", 0, 0);
    }

    const inputs = [_][]const u8{
        "Keemun", " keEMun", "keeMUN ", "  keemun", "KEEMUN  ", " keemun ", "  KEEmUN  ",
        " Kee%mun ", "keemun\t", "\t\nkeemun", "Kee-mun"
    };
    for (inputs) |input| {
        var parsed = try testCollectParser(input);
        defer parsed.deinit();
        try t.expectString(parsed.input, "keemun");
        try t.expectEqual(parsed.word_count, 1);
        try t.expectEqual(parsed.lookup.count(), 4);
        try parsed.expectNgram("kee", 0, 0);
        try parsed.expectNgram("eem", 0, 1);
        try parsed.expectNgram("emu", 0, 2);
        try parsed.expectNgram("mun", 0, 3);
    }
}

test "parse two word" {
    const inputs = [_][]const u8{
        "black bear",
        " black bear",
        "black bear ",
        " black Bear ",
        "  black bear  ",
        "BLACK    BEAR",
        " BLACK    BEAR  ",

    };

    for (inputs) |input| {
        var parsed = try testCollectParser(input);
        defer parsed.deinit();
        try t.expectString(parsed.input, "black bear");
        try t.expectEqual(parsed.word_count, 2);
        try t.expectEqual(parsed.lookup.count(), 5);
        try parsed.expectNgram("bla", 0, 0);
        try parsed.expectNgram("lac", 0, 1);
        try parsed.expectNgram("ack", 0, 2);
        try parsed.expectNgram("bea", 1, 0);
        try parsed.expectNgram("ear", 1, 1);
    }

    {
        // ignore short words
        var parsed = try testCollectParser(" Black  at");
        defer parsed.deinit();
        try t.expectString(parsed.input, "black at");
        try t.expectEqual(parsed.word_count, 1);
        try t.expectEqual(parsed.lookup.count(), 3);
        try parsed.expectNgram("bla", 0, 0);
        try parsed.expectNgram("lac", 0, 1);
        try parsed.expectNgram("ack", 0, 2);
    }

    {
        // ignore short words
        var parsed = try testCollectParser(" Black a  cat  ");
        defer parsed.deinit();
        try t.expectString(parsed.input, "black a cat");
        try t.expectEqual(parsed.word_count, 2);
        try t.expectEqual(parsed.lookup.count(), 4);
        try parsed.expectNgram("bla", 0, 0);
        try parsed.expectNgram("lac", 0, 1);
        try parsed.expectNgram("ack", 0, 2);
        try parsed.expectNgram("cat", 1, 0);
    }
}

const ParseTestResult = struct {
    input: []const u8,
    word_count: u8,
    lookup: StringHashMap(NgramPosition),

    const Self = @This();

    fn expectNgram(self: Self, ngram: []const u8, word_index: u8, position: u8) !void {
        var p = self.lookup.get(ngram) orelse unreachable;
        try t.expectEqual(p.position, position);
        try t.expectEqual(p.word_index, word_index);
    }

    fn deinit(self: *Self) void {
        t.allocator.free(self.input);
        self.lookup.deinit();
        self.* = undefined;
    }
};

fn testCollectParser(input: []const u8) !ParseTestResult {
    var lookup = StringHashMap(NgramPosition).init(t.allocator);
    var parser = try parse(t.allocator, input);
    while (parser.next()) |result| {
        try lookup.put(result.ngram, NgramPosition{
            .entry = undefined,
            .position = result.position,
            .word_index = result.word_index,
        });
    }
    return ParseTestResult{
        .lookup = lookup,
        .input = parser.getNormalized(),
        .word_count = parser.word_count,
    };
}
