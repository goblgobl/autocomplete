const std = @import("std");

const t = @import("t.zig");
const web = @import("web/web.zig");
const ac = @import("autocomplete.zig");
const Config = @import("config.zig").Config;

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

	const ctx = try ac.Context.init(allocator, config);
	try web.start(allocator, ctx, config);
}

fn readConfig(allocator: Allocator, path: []const u8) !Config {
	const data = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch |err| {
		if (err == error.FileNotFound) {
				std.log.warn("'{s}' not found", .{path});
		}
		return err;
	};
	defer allocator.free(data);

	var stream = std.json.TokenStream.init(data);
	return try std.json.parse(Config, &stream, .{.allocator = allocator});
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
	_ = @import("index.zig");
	_ = @import("search.zig");
	std.testing.refAllDecls(@This());
}

test "main: config not found" {
	std.testing.log_level = .err;
	try t.expectError(error.FileNotFound, readConfig(t.allocator, "invalid.json"));
	std.testing.log_level = .warn;
}

test "main: read config" {
	{
		const config = try readConfig(t.allocator, "tests/config.json");
		defer config.deinit(t.allocator);

		try t.expectString("/tmp/autocomplete.db", config.db.?);
		try t.expectEqual(@as(u16, 5400), config.port.?);
		try t.expectString("127.0.0.1", config.address.?);
	}

	{
		const config = try readConfig(t.allocator, "tests/config.empty.json");
		defer config.deinit(t.allocator);

		try t.expectEqual(@as(?[]const u8, null), config.db);
		try t.expectEqual(@as(?u16, null), config.port);
		try t.expectEqual(@as(?[]const u8, null), config.address);
	}
}
