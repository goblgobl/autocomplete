const std = @import("std");

const ac = @import("autocomplete.zig");

const Allocator = std.mem.Allocator;

pub fn main() !void {
	try quickBenchmark();
}

pub fn quickBenchmark() !void {
	const search = @import("search.zig");

	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.detectLeaks();

	var index = ac.Index.init(allocator, .{.id = 7007});
	defer index.deinit();

	{
		var file = try std.fs.cwd().openFile("../book_titles.txt", .{});
		defer file.close();
		var buf_reader = std.io.bufferedReader(file.reader());
		var in_stream = buf_reader.reader();
		var buf: [1024]u8 = undefined;
		var i : ac.Id = 0;
		while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
			try index.add(i, line);
			i += 1;
		}
	}

	var ids: ac.IdCollector = undefined;
	var ap = try search.AccumulatorPool.init(allocator, 100);
	defer ap.deinit();

	var timer = try std.time.Timer.start();

	std.debug.print("LOADED\n", .{});
	const LOOPS = 1000;
	timer.reset();

	for (0..LOOPS) |_| {
		const found = try ac.search(allocator, "revolution", &index, &ap, &ids);
		if (found != ac.MAX_RESULTS) {
			std.debug.print("didn't find ac.MAX_RESULTS items\n", .{});
		}
	}

	const elapsed = timer.lap() / 1_000;
	std.debug.print("Search took: {d}us ({d}us per loop)\n", .{elapsed, elapsed/LOOPS});
}
