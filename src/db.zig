const std = @import("std");
const c = @cImport(@cInclude("lmdb.h"));

pub const DB = struct {
	dbi: c_uint,
	env: ?*c.MDB_env,

	const Tx = struct {
		dbi: c_uint,
		txn: ?*c.MDB_txn,

		pub fn abort(self: Tx) void {
			c.mdb_txn_abort(self.txn);
		}

		pub fn commit(self: Tx) !void {
			const result = c.mdb_txn_commit(self.txn);
			if (result != 0) {
				return errorFromCode(result);
			}
		}

		pub fn put(self: Tx, key: []const u8, value: []const u8) !void {
			var key_val = toMDBVal(key);
			var value_val = toMDBVal(value);
			const result = c.mdb_put(self.txn, self.dbi, &key_val, &value_val, 0);
			if (result != 0) {
				return errorFromCode(result);
			}
		}

		pub fn get(self: Tx, key: []const u8) !?[]const u8 {
			var key_val = toMDBVal(key);
			var value_val: c.MDB_val = undefined;
			const result = c.mdb_get(self.txn, self.dbi, &key_val, &value_val);
			if (result != 0) {
				if (result == c.MDB_NOTFOUND) {
					return null;
				}
				return errorFromCode(result);
			}
			return fromMDBVal(value_val);
		}
	};

	const Iterator = struct {
		tx: Tx,
		prefix: []const u8,
		started: bool,
		cursor: ?*c.MDB_cursor,

		pub fn deinit(self: Iterator) void {
			c.mdb_cursor_close(self.cursor);
			self.tx.abort();
		}

		pub fn next(self: *Iterator) !?Entry {
			var key: c.MDB_val = undefined;
			var value: c.MDB_val = undefined;
			var op : c_uint = c.MDB_NEXT;
			if (!self.started) {
				op = c.MDB_SET_RANGE;
				key = toMDBVal(self.prefix);
				self.started = true;
			}

			const result = c.mdb_cursor_get(self.cursor, &key, &value, op);
			if (result != 0) {
				if (result == c.MDB_NOTFOUND) {
					return null;
				}
				return errorFromCode(result);
			}

			const found_key = fromMDBVal(key);

			// LMDB _starts_ at the prefix, but it'll keep going beyond keys that
			// don't match it. So we have to (match it).
			if (!std.mem.startsWith(u8, found_key, self.prefix)) {
				return null;
			}

			return Entry{
				.key = found_key,
				.value = fromMDBVal(value),
			};
		}
	};

	const Entry = struct {
		key: []const u8,
		value: []const u8,
	};

	pub fn init(path: []const u8) !DB {
		var env: ?*c.MDB_env = null;

		var result = c.mdb_env_create(&env);
		if (result != 0) {
			return errorFromCode(result);
		}
		errdefer c.mdb_env_close(env);

		result = c.mdb_env_open(env, path.ptr, c.MDB_NOSUBDIR | c.MDB_NOMETASYNC | c.MDB_NOTLS, 0o600);
		if (result != 0) {
			return errorFromCode(result);
		}

		var db = DB{.env = env, .dbi = 0};

		const tx = try db.writeTx();
		errdefer tx.abort();

		var dbi: c.MDB_dbi = 0;
		result = c.mdb_dbi_open(tx.txn, null, 0, &dbi);
		if (result != 0) {
			return errorFromCode(result);
		}
		try tx.commit();

		db.dbi = dbi;
		return db;
	}

	pub fn deinit(self: DB) void {
		c.mdb_env_close(self.env);
	}

	pub fn writeTx(self: DB) !Tx{
		var txn: ?*c.MDB_txn = null;

		var result = c.mdb_txn_begin(self.env, null, 0, &txn);
		if (result != 0) {
			return errorFromCode(result);
		}

		return Tx{.txn = txn, .dbi = self.dbi};
	}

	pub fn readTx(self: DB) !Tx{
		var txn: ?*c.MDB_txn = null;

		var result = c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn);
		if (result != 0) {
			return errorFromCode(result);
		}

		return Tx{.txn = txn, .dbi = self.dbi};
	}

	pub fn iterate(self: DB, prefix: []const u8) !Iterator {
		const tx = try self.readTx();
		errdefer tx.abort();

		var cursor: ?*c.MDB_cursor = null;
		var result = c.mdb_cursor_open(tx.txn, self.dbi, &cursor);
		if (result != 0) {
			return errorFromCode(result);
		}

		return .{
			.tx = tx,
			.started = false,
			.prefix = prefix,
			.cursor = cursor,
		};
	}

	pub fn put(self: DB, key: []const u8, value: []const u8) !void {
		const tx = try self.writeTx();
		errdefer tx.abort();
		try tx.put(key, value);
		try tx.commit();
	}
};

fn toMDBVal(in: []const u8) c.MDB_val {
	return c.MDB_val{
		.mv_size = in.len,
		.mv_data = @ptrCast(@constCast(in.ptr)),
	};
}

fn fromMDBVal(val: c.MDB_val) []const u8 {
	return @as([*]const u8, @ptrCast(val.mv_data))[0..val.mv_size];
}

fn nullVal() c.MDB_val {
	return c.MDB_val{
		.mv_size = 0,
		.mv_data = undefined,
	};
}

fn errorFromCode(result: c_int) anyerror {
	 return switch (result) {
		c.MDB_KEYEXIST => error.KeyExists,
		c.MDB_NOTFOUND => error.NotFound,
		c.MDB_PAGE_NOTFOUND => error.PageNotFound,
		c.MDB_CORRUPTED => error.Corrupted,
		c.MDB_PANIC => error.Panic,
		c.MDB_VERSION_MISMATCH => error.VersionMismatch,
		c.MDB_INVALID => error.Invalid,
		c.MDB_MAP_FULL => error.MapFull,
		c.MDB_DBS_FULL => error.DbsFull,
		c.MDB_READERS_FULL => error.ReadersFull,
		c.MDB_TLS_FULL => error.TlsFull,
		c.MDB_TXN_FULL => error.TxnFull,
		c.MDB_CURSOR_FULL => error.CursorFull,
		c.MDB_PAGE_FULL => error.PageFull,
		c.MDB_INCOMPATIBLE => error.Incompatible,
		c.MDB_BAD_RSLOT => error.BadRSlot,
		c.MDB_BAD_TXN => error.BadTxn,
		c.MDB_BAD_VALSIZE => error.BadValSize,
		c.MDB_BAD_DBI => error.BadDbi,
		@intFromEnum(std.os.E.NOENT) => error.NoSuchFileOrDirectory,
		@intFromEnum(std.os.E.IO) => error.InputOutputError,
		@intFromEnum(std.os.E.NOMEM) => error.OutOfMemory,
		@intFromEnum(std.os.E.ACCES) => error.ReadOnly,
		@intFromEnum(std.os.E.BUSY) => error.DeviceOrResourceBusy,
		@intFromEnum(std.os.E.INVAL) => error.InvalidParameter,
		@intFromEnum(std.os.E.NOSPC) => error.NoSpaceLeftOnDevice,
		@intFromEnum(std.os.E.EXIST) => error.FileAlreadyExists,
		else => std.debug.panic("{s} {d}", .{c.mdb_strerror(result), result}),
	};
}

const t = @import("t.zig");
test "DB: iterator: no match" {
	t.cleanup();
	const kv = try DB.init("tests/db");
	defer kv.deinit();

	var it = try kv.iterate("does-not-exist");
	defer it.deinit();
	try t.expectEqual(@as(?DB.Entry, null), try it.next());
}

test "DB: iterator: matches" {
	t.cleanup();
	const kv = try DB.init("tests/db");
	defer kv.deinit();
	try kv.put("ka0", "v0");
	try kv.put("ke1", "v1");
	try kv.put("ke2", "v2");
	try kv.put("ke3", "v3");
	try kv.put("kz0", "v0");

	var it = try kv.iterate("ke");
	defer it.deinit();

	var entry = try it.next() orelse unreachable;
	try t.expectString(entry.key, "ke1");
	try t.expectString(entry.value, "v1");

	entry = try it.next() orelse unreachable;
	try t.expectString(entry.key, "ke2");
	try t.expectString(entry.value, "v2");

	entry = try it.next() orelse unreachable;
	try t.expectString(entry.key, "ke3");
	try t.expectString(entry.value, "v3");

	try t.expectEqual(@as(?DB.Entry, null), try it.next());
}

test "DB: get/put" {
	t.cleanup();
	const kv = try DB.init("tests/db");
	defer kv.deinit();

	try kv.put("key1", "val1a");
	try kv.put("key2", "val2a");
	{
		var tx = try kv.writeTx();
		errdefer tx.abort();
		try tx.put("key2", "val2b");
		try tx.put("key3", "val3a");
		try tx.commit();
	}

	{
		var tx = try kv.readTx();
		defer tx.abort();
		try t.expectString("val1a", (try tx.get("key1")).?);
		try t.expectString("val2b", (try tx.get("key2")).?);
		try t.expectString("val3a", (try tx.get("key3")).?);
		try t.expectEqual(@as(?[]const u8, null), try tx.get("key4"));
	}
}

//idx:ID -> index_config
//ID:p:id -> payload
//ID:i:id -> term
//ID:x:external-id ->
