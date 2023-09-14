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
	const time_taken = (try std.time.Instant.now()).since(time0);

	res.content_type = httpz.ContentType.JSON;
	var writer = res.directWriter();
	if (found == 0) {
		try writer.writeAll("{\"results\":[]}");
		return;
	}

	// We're going to need to get values from our DB by key. Our keys are a fixed-length
	// and the found ID is always the last 4 bytes, so we can do this efficiently
	var key = index.make_db_key_buf('p');
	var key_ref = &key;

	try writer.writeAll("{\"results\": [");

	const tx = try ctx.db.readTx();
	defer tx.abort(); // a bit faster to abort a read tx

	var added: usize = 0;

	for (ids[0..found]) |id| {
		ac.encodePrefixedId(key_ref, id);
		if (try tx.get(key_ref)) |payload| {
			try writer.writeAll(payload);
			try writer.writeByte(',');
			added += 1;
		}
	}

	if (added > 0) {
		// remove the last trailing comma
		writer.truncate(1);
	}

	try writer.writeAll("],\"timing\":");
	try std.fmt.formatInt(time_taken/1000, 10, .lower, .{}, writer);
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
	var cb = t.buildContext();
	defer cb.deinit();

	var web_test = ht.init(.{});
	defer web_test.deinit();

	web_test.url("?query=abc");
	web_test.param("id", "82281");
	try search(web_test.req, web_test.res, &cb.ctx);

	try web_test.expectStatus(400);
	try web_test.expectJson(.{.code = 1});
}

test "web.search" {
	var cb = t.buildContext();
	defer cb.deinit();
	var idx = cb.buildIndex(1234);
	idx.add(88191, "apple sauce", "1");
	idx.add(88192, "applaud", "2");
	idx.add(88193, "nope", "3");
	cb.addIndex(idx.index);

	{
		// no hits
		var web_test = ht.init(.{});
		defer web_test.deinit();

		web_test.url("?query=cat");
		web_test.param("id", "1234");
		try search(web_test.req, web_test.res, &cb.ctx);
		try web_test.expectStatus(200);
		try web_test.expectJson(.{.results = [_]u32{}});
	}

	{
		var web_test = ht.init(.{});
		defer web_test.deinit();

		web_test.url("?query=apple");
		web_test.param("id", "1234");
		try search(web_test.req, web_test.res, &cb.ctx);
		try web_test.expectStatus(200);
		try web_test.expectJson(.{.results = [_]u32{1, 2}});
	}
}
