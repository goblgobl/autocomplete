const std = @import("std");

const LazyPath = std.Build.LazyPath;
const ModuleMap = std.StringArrayHashMap(*std.Build.Module);

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	var modules = ModuleMap.init(allocator);
	defer modules.deinit();

	try modules.put("httpz", b.addModule("httpz", .{
		.source_file = .{ .path = "lib/http.zig/src/httpz.zig" },
	}));

	// setup executable
	const exe = b.addExecutable(.{
		.name = "autocomplete",
		.root_source_file = .{ .path = "src/main.zig" },
		.target = target,
		.optimize = optimize,
	});
	addLibs(exe, modules);
	b.installArtifact(exe);

	const run_cmd = b.addRunArtifact(exe);
	run_cmd.step.dependOn(b.getInstallStep());
	if (b.args) |args| {
		run_cmd.addArgs(args);
	}

	// setup tests
	const run_step = b.step("run", "Run the app");
	run_step.dependOn(&run_cmd.step);

	const tests = b.addTest(.{
		.root_source_file = .{ .path = "src/lib.zig" },
		.target = target,
		.optimize = optimize,
	});

	addLibs(tests, modules);
	const run_test = b.addRunArtifact(tests);
	run_test.has_side_effects = true;

	const test_step = b.step("test", "Run tests");
	test_step.dependOn(&run_test.step);
}

fn addLibs(step: *std.Build.CompileStep, modules: ModuleMap) void {
	var it = modules.iterator();
	while (it.next()) |m| {
		step.addModule(m.key_ptr.*, m.value_ptr.*);
	}
	// step.linkSystemLibrary("c");
	step.addCSourceFiles(&.{
		"lib/lmdb/mdb.c",
		"lib/lmdb/midl.c"
	}, &[_][]const u8{});

	step.addIncludePath(LazyPath.relative("lib/lmdb"));
}
