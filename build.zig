const std = @import("std");

const ModuleMap = std.StringArrayHashMap(*std.Build.Module);

pub fn build(b: *std.Build) !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const package_names = [_][]const u8{"zhp"};
	var modules = ModuleMap.init(allocator);
	defer modules.deinit();

	for (package_names) |name| {
		const pkg = b.dependency(name, .{
			.target = target,
			.optimize = optimize,
		});
		try modules.put(name, pkg.module(name));
	}

	// setup executable
	const exe = b.addExecutable(.{
		.name = "autocomplete",
		.root_source_file = .{ .path = "src/main.zig" },
		.target = target,
		.optimize = optimize,
	});
	addLibs(exe, modules);
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
	addLibs(tests, modules);

	const test_step = b.step("test", "Run tests");
	test_step.dependOn(&tests.step);
}

fn addLibs(step: *std.Build.CompileStep, modules: ModuleMap) void {
	var it = modules.iterator();
	while (it.next()) |m| {
		step.addModule(m.key_ptr.*, m.value_ptr.*);
	}
	step.addCSourceFile("lib/lmdb/mdb.c", &[_][]const u8{});
	step.addCSourceFile("lib/lmdb/midl.c", &[_][]const u8{});
	step.addIncludePath("lib/lmdb");
}
