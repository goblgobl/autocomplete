const std = @import("std");
const httpz = @import("httpz");
const search = @import("search.zig").search;
const ac = @import("../autocomplete.zig");

const Id = ac.Id;
const Index = ac.Index;
const Context = ac.Context;
const Config = @import("../config.zig").Config;

const t = @import("../t.zig");
const ht = httpz.testing;

const Allocator = std.mem.Allocator;

pub fn start(allocator: Allocator, context: Context, config: Config) !void {
	var ctx = context;
	var server = try httpz.ServerCtx(*Context).init(allocator, .{
		.port = config.port orelse 5400,
		.address = config.address orelse "127.0.0.1",
	}, &ctx);

	var router = server.router();
	router.get("/v1/search/:id", search);

	try server.listen();
}

pub fn loadIndex(sid: []const u8, ctx: *Context) ?*Index {
	const id = std.fmt.parseInt(u32, sid, 10) catch return null;
	return ctx.getIndex(@as(Id, id));
}

test "web: loadIndex null on invalid id" {
	var cb = t.buildContext();
	defer cb.deinit();
	try t.expectEqual(@as(?*Index, null), loadIndex("3223", &cb.ctx));
	try t.expectEqual(@as(?*Index, null), loadIndex("invalid", &cb.ctx));
}

test "web: loadIndex success" {
	var cb = t.buildContext();
	cb.addIndex(cb.buildIndex(391).index);
	defer cb.deinit();

	try t.expectEqual(@as(Id, 391), loadIndex("391", &cb.ctx).?.id);
}

pub fn invalidIndex(res: *httpz.Response) void {
	res.status = 400;
	res.content_type = httpz.ContentType.JSON;
	res.body = "{\"error\":\"invalid index id\",\"code\":1}";
}

test "web: invalidIndex" {
	var web_test = ht.init(.{});
	defer web_test.deinit();

	invalidIndex(web_test.res);
	try web_test.expectStatus(400);
	try web_test.expectJson(.{.@"error" = "invalid index id", .code = 1});
}

pub fn requiredParameter(res: *httpz.Response, parameter: []const u8) !void {
	res.status = 400;
	return res.json(.{.code = 2, .parameter = parameter, .@"error" = "missing parameter"});
}

test "web: requiredParameter" {
	var web_test = ht.init(.{});
	defer web_test.deinit();

	try requiredParameter(web_test.res, "px0");
	try web_test.expectStatus(400);
	try web_test.expectJson(.{.@"error" = "missing parameter", .code = 2, .parameter = "px0"});
}
