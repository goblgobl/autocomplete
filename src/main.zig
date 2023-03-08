const std = @import("std");

const t = @import("t.zig");
const ac = @import("autocomplete.zig");
const zhp = @import("zhp");

const Allocator = std.mem.Allocator;

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	var config_file: []const u8 = "config.json";
	var it = std.process.args();
	_ = it.next(); // skip executable
	if (it.next()) |arg| {
		config_file = arg;
	}

	const config = try readConfig(allocator, config_file);
	defer config.deinit(allocator);

	try ac.setup(allocator, config);
	defer ac.deinit(allocator);

	var app = zhp.Application.init(allocator, .{ .debug = true });

	defer app.deinit();
	try app.listen("127.0.0.1", 9000);
	try app.start();
}

fn readConfig(allocator: Allocator, path: []const u8) !ac.Config {
	const data = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch |err| {
		if (err == error.FileNotFound) {
				std.log.warn("'{s}' not found", .{path});
		}
		return err;
	};
	defer allocator.free(data);

	var stream = std.json.TokenStream.init(data);
	return try std.json.parse(ac.Config, &stream, .{.allocator = allocator});
}



// pub fn quickBenchmark() !void {
// 	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
// 	const allocator = gpa.allocator();

// 	// const storage = try Storage.init("/tmp/test");
// 	// defer storage.deinit();

// 	// const contents = try std.fs.cwd().readFileAlloc(gpa, "config.json", buffer, 4096);
// 	const contents = try std.fs.cwd().readFileAlloc(allocator, "book_titles.txt", 20_000_0000);
// 	defer allocator.free(contents);


// 	var index = try Index.init(allocator);
// 	defer index.deinit();

// 	var id : u32 = 0;
// 	var it = std.mem.split(u8, contents, "\n");

// 	var timer = try Timer.start();
// 	while (it.next()) |title| {
// 		try index.add(id, title);
// 		id += 1;
// 	}
// 	print("Load took: {d}us\n", .{timer.lap() / 1_000});

// 	var results : [search.MAX_RESULTS]u32 = undefined;

// 	timer.reset();
// 	for (0..100) |_| {
// 		const found = try index.find("mon amour", &results);
// 		if (found.len != 10) {
// 			print("didn't find 10 items\n", .{});
// 		}
// 	}
// 	const elapsed = timer.lap() / 1_000;
// 	print("Search took: {d}us ({d}us per loop)\n", .{elapsed, elapsed/100});

// 	for (results) |r| {
// 		print("{d}\n", .{r});
// 	}
// }

test {
	_ = @import("./index.zig");
	_ = @import("./search.zig");
	std.testing.refAllDecls(@This());
}

test "readConfig fileNotFound" {
	std.testing.log_level = .err;
	try t.expectError(error.FileNotFound, readConfig(t.allocator, "invalid.json"));
	std.testing.log_level = .warn;
}


test "readConfig" {
	{
		const config = try readConfig(t.allocator, "tests/config.json");
		defer config.deinit(t.allocator);

		try t.expectString("/tmp/autocomplete.db", config.db.?);
		try t.expectString("127.0.0.1:4000", config.listen.?);
	}

	{
		const config = try readConfig(t.allocator, "tests/config.empty.json");
		defer config.deinit(t.allocator);

		try t.expectEqual(@as(?[]const u8, null), config.db);
		try t.expectEqual(@as(?[]const u8, null), config.listen);
	}
}
