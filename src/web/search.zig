const std = @import("std");

const httpz = @import("httpz");
const web = @import("web.zig");
const ac = @import("../autocomplete.zig");

const t = @import("../t.zig");
const ht = httpz.testing;

pub fn search(req: *httpz.Request, res: *httpz.Response, ctx: *ac.Context) !void {
	const query = try req.query();
	const term = query.get("query") orelse return web.requiredParameter(res, "query");
	const index = web.loadIndex(req.param("id").?, ctx) orelse return web.invalidIndex(res);

	var ids: ac.IdCollector = undefined;
	const time0 = try std.time.Instant.now();
	const found = try ac.search(req.arena, term, index, &ids);
	const time1 = try std.time.Instant.now();

	res.content_type = httpz.ContentType.JSON;
	var writer = res.writer();
	if (found == 0) {
		try writer.writeAll("{\"results\":[],\"timing\":");
		try std.fmt.formatInt(time1.since(time0)/1000, 10, .lower, .{}, writer);
		try writer.writeAll("}");
		return;
	}

	try writer.writeAll("{\"results\": [");
	var key = index.make_db_key_buf('p');
	var key_id_buf = key[key.len - 4..];
	const tx = try ctx.db.readTx();
	defer tx.abort(); // a bit faster to abort a read tx

	// TODO: I hate this
	var add_comma = false;
	for (ids[0..found]) |id| {
		ac.encodeId(key_id_buf, id);
		if (try tx.get(&key)) |payload| {
			if (add_comma) {
				try writer.writeByte(',');
			} else {
				add_comma = true;
			}
			try writer.writeAll(payload);
		}
	}
	try writer.writeAll("],\"timing\":");
	try std.fmt.formatInt(time1.since(time0)/1000, 10, .lower, .{}, writer);
	try writer.writeAll("}");
}

test "web.search: missing query" {
	var web_test = ht.init(.{});
	defer web_test.deinit();

	try search(web_test.req, web_test.res, undefined);
	try web_test.expectStatus(400);
	try web_test.expectJson(.{.code = 2});
}

test "web.search: invalid index id" {
	var web_test = ht.init(.{});
	defer web_test.deinit();

	web_test.url("/?query=abc");
	web_test.param("id", "nope");
	try search(web_test.req, web_test.res, undefined);
	try web_test.expectStatus(400);
	try web_test.expectJson(.{.code = 1});
}

test "web.search: unknown index id" {
	var web_test = ht.init(.{});
	defer web_test.deinit();

	var ctx = t.buildContext().context;
	defer ctx.deinit();

	web_test.url("?query=abc");
	web_test.param("id", "82281");
	try search(web_test.req, web_test.res, &ctx);
	try web_test.expectStatus(400);

	const json = try web_test.getJson();
	try t.expectEqual(@as(i64, 1), json.Object.get("code").?.Integer);
}
