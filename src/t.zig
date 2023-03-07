const std = @import("std");
const builtin = @import("builtin");

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;


pub fn cleanup() void {
	const cwd = std.fs.cwd();
	cwd.deleteFile("tests/db") catch {};
	cwd.deleteFile("tests/db-lock") catch {};
}
