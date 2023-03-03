const std = @import("std");
const facs = @import("./facs.zig");

const print = std.debug.print;

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = general_purpose_allocator.allocator();

    const input = "  Sourdough";

    var database = try facs.Database.init(allocator);
    try database.add(882, input);
    // const input = try allocator.alloc(u8, s.len);
    // std.mem.copy(u8, input, s);

    // const entry = try facs.parse(allocator, 882, input);
    // print("{d} {s} {d}\n", .{entry.id, entry.input, entry.word_count});
    // for (entry.ngrams) |ngram| {
    //     print("{d} {s} {d}\n", .{ ngram.word, ngram.value, ngram.position });
    // }

}
