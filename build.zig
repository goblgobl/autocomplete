const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	// setup executable
	const exe = b.addExecutable(.{
		.name = "autocomplete",
		.root_source_file = .{ .path = "src/main.zig" },
		.target = target,
		.optimize = optimize,
	});
	exe.addCSourceFile("lmdb/mdb.c", &[_][]const u8{});
	exe.addCSourceFile("lmdb/midl.c", &[_][]const u8{});
	exe.addIncludePath("lmdb");
	exe.install();

	const run_cmd = exe.run();
	run_cmd.step.dependOn(b.getInstallStep());
	if (b.args) |args| {
		run_cmd.addArgs(args);
	}

	// setup tests
	const run_step = b.step("run", "Run the app");
	run_step.dependOn(&run_cmd.step);

	const tests = b.addTest(.{
		.root_source_file = .{ .path = "src/main.zig" },
		.target = target,
		.optimize = optimize,
	});
	tests.addCSourceFile("lmdb/mdb.c", &[_][]const u8{});
	tests.addCSourceFile("lmdb/midl.c", &[_][]const u8{});
	tests.addIncludePath("lmdb");

	const test_step = b.step("test", "Run tests");
	test_step.dependOn(&tests.step);
}
