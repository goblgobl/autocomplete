const std = @import("std");
const zac = @import("./zac.zig");

const Index = zac.Index;
const Timer = std.time.Timer;

const print = std.debug.print;

pub fn main() !void {
	var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = general_purpose_allocator.allocator();

	var buffer = try allocator.alloc(u8, 2_000_000);
	defer allocator.free(buffer);

	const contents = try std.fs.cwd().readFile("book_titles.txt", buffer);

	var index = try Index.init(allocator);
	defer index.deinit();

	var id : u32 = 0;
	var it = std.mem.split(u8, contents, "\n");

	var timer = try Timer.start();
	while (it.next()) |title| {
		try index.add(id, title);
		id += 1;
	}
	print("Load took: {d}ms\n", .{timer.lap() / 1_000_000});

	var results : [zac.MAX_RESULTS]u32 = undefined;

	timer.reset();
	for (0..100) |_| {
		const found = try index.find("mon amour", &results);
		if (found.len != 10) {
			print("didn't find 10 items\n", .{});
		}
	}
	const elapsed = timer.lap() / 1_000_000;
	print("Search took: {d}ms ({d}ms per loop)\n", .{elapsed, elapsed/100});

	for (results) |r| {
		print("{d}\n", .{r});
	}
}
