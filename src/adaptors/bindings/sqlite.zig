const std = @import("std");
pub const c = @cImport(@cInclude("sqlite3.h"));

const copyValue = c.SQLITE_TRANSIENT;

pub const FreeFn = @TypeOf(copyValue);

pub const log = std.log.scoped(.zql_sqlite_bindings);

pub const Db = struct {
    inner: ?*c.sqlite3 = undefined,

    pub fn init(name: []const u8) !Db {
        var r: Db = undefined;
        const res = c.sqlite3_open(name.ptr, &r.inner);

        if (res != c.SQLITE_OK) {
            const errstr: [*:0]const u8 = c.sqlite3_errmsg(r.inner);
            log.err("{s}", .{errstr});
            return error.Open;
        }
        return r;
    }

    pub fn deinit(self: *Db) void {
        const res = c.sqlite3_close(self.inner);
        if (res != c.SQLITE_OK) {
            const errstr: [*:0]const u8 = c.sqlite3_errmsg(self.inner);
            log.warn("{s}", .{errstr});
        }
    }
};

const Stepping = enum {
    done,
    more,
};

pub const Statement = struct {
    inner: ?*c.sqlite3_stmt = undefined,

    pub fn init(db: Db, sql: []const u8) !Statement {
        var ret: Statement = .{};
        log.debug("preparing statement:{s}", .{sql});
        const res = c.sqlite3_prepare_v2(db.inner, sql.ptr, @intCast(sql.len), &ret.inner, null);

        if (res != c.SQLITE_OK) {
            const errstr: [*:0]const u8 = c.sqlite3_errmsg(db.inner);
            log.err("{s}", .{errstr});
            return error.Init;
        }
        return ret;
    }

    pub fn deinit(self: Statement) void {
        log.debug("ending statement", .{});
        const res = c.sqlite3_finalize(self.inner);

        if (res != c.SQLITE_OK) {
            const db = c.sqlite3_db_handle(self.inner);
            const errstr: [*:0]const u8 = c.sqlite3_errmsg(db);
            log.warn("{s}", .{errstr});
        }
    }

    pub fn bind(self: Statement, index: usize, args: BindArgs) !void {
        log.debug("binding {s}: {any}", .{ @tagName(args), args });
        const ret = switch (args) {
            .blob => |v| c.sqlite3_bind_blob(self.inner, @intCast(index), v.inner.ptr, v.inner.len, v.free),
            .blob64 => |v| c.sqlite3_bind_blob64(self.inner, @intCast(index), v.inner.ptr, v.inner.len, v.free),
            .double => |v| c.sqlite3_bind_double(self.inner, @intCast(index), v),
            .int => |v| c.sqlite3_bind_int(self.inner, @intCast(index), v),
            .int64 => |v| b: {
                // log.debug("{any} {}", .{ v, index });

                break :b c.sqlite3_bind_int64(self.inner, @intCast(index), @intCast(v));
            },
            .null => |_| c.sqlite3_bind_null(self.inner, @intCast(index)),
            .text => |v| b: {
                const ptr: [*c]const u8 = @alignCast(@ptrCast(v.inner.ptr));
                // log.debug("{s}", .{ptr[0..v.inner.len]});
                break :b c.sqlite3_bind_text(self.inner, @intCast(index), ptr, @intCast(v.inner.len), c.SQLITE_STATIC);
            },
            .text16 => |v| c.sqlite3_bind_text16(self.inner, @intCast(index), v.inner.ptr, v.inner.len, v.free),
            .text64 => |v| c.sqlite3_bind_text64(self.inner, @intCast(index), v.inner.text_args.ptr, v.inner.text_args.len, v.free, v.inner.encoding),
            .value => |v| c.sqlite3_bind_value(self.inner, @intCast(index), v),
            .pointer => |v| c.sqlite3_bind_pointer(self.inner, @intCast(index), v.inner.ptr, v.inner.name, v.free),
            .zeroblob => |v| c.sqlite3_bind_zeroblob(self.inner, @intCast(index), v),
            .zeroblob64 => |v| c.sqlite3_bind_zeroblob64(self.inner, @intCast(index), v),
        };

        if (ret != c.SQLITE_OK) {
            const db = c.sqlite3_db_handle(self.inner);
            const errstr: [*:0]const u8 = c.sqlite3_errmsg(db);
            log.err("{s}", .{errstr});
            return error.Bind;
        }
    }

    const Cursor = struct {
        stmt: Statement,

        pub fn next(self: *Cursor) !Stepping {
            const ret = c.sqlite3_step(self.stmt.inner);
            const state = std.meta.intToEnum(Return, ret) catch {
                const db = c.sqlite3_db_handle(self.stmt.inner);
                const errstr: [*:0]const u8 = c.sqlite3_errmsg(db);
                log.err("{s}", .{errstr});
                return error.Step;
            };
            switch (state) {
                .busy, .@"error", .misuse => {
                    const db = c.sqlite3_db_handle(self.stmt.inner);
                    const errstr: [*:0]const u8 = c.sqlite3_errmsg(db);
                    log.err("{s}", .{errstr});
                    return error.BadStep;
                },
                .row => return .more,
                .done => return .done,
            }
        }

        const Return = enum(c_int) {
            busy = c.SQLITE_BUSY,
            done = c.SQLITE_DONE,
            row = c.SQLITE_ROW,
            @"error" = c.SQLITE_ERROR,
            misuse = c.SQLITE_MISUSE,
        };
    };

    pub fn step(self: Statement) Cursor {
        return .{ .stmt = self };
    }

    pub fn column(self: Statement, comptime result: Returns, ix: usize) result.Repr() {
        const columnFn = @field(c, "sqlite3_column_" ++ @tagName(result));
        const idx = @as(c_int, @intCast(ix));
        const value = columnFn(self.inner, @as(c_int, @intCast(ix)));
        switch (result) {
            .blob => {
                const len = c.sqlite3_column_bytes(self.inner, idx);
                return .{
                    .ptr = value,
                    .len = len,
                };
            },
            .text => {
                const len = c.sqlite3_column_bytes(self.inner, idx);
                return value[0..@intCast(len)];
            },
            .text16 => {
                const len = c.sqlite3_column_bytes16(self.inner, idx);
                return .{
                    .ptr = value,
                    .len = len,
                };
            },
            else => return value,
        }
    }

    pub const BindArgs = union(enum) {
        fn MemMan(comptime T: type) type {
            return struct {
                inner: T,
                free: FreeFn = copyValue,
            };
        }

        fn Ptr(comptime Inner: type, comptime LenCont: type) type {
            return struct {
                ptr: Inner,
                len: LenCont,
            };
        }

        blob: MemMan(Ptr(?*anyopaque, c_int)),
        blob64: MemMan(Ptr(?*anyopaque, c_ulonglong)),
        double: f64,
        int: c_int,
        int64: c_longlong,
        null,
        text: MemMan([]const u8),
        text16: MemMan(Ptr(?*anyopaque, c_int)),
        text64: MemMan(struct {
            text_args: Ptr([*c]const u8, c_ulonglong),
            encoding: u8,
        }),
        value: ?*const c.sqlite3_value,
        pointer: MemMan(struct {
            ptr: ?*anyopaque,
            name: [*c]const u8,
        }),
        zeroblob: c_int,
        zeroblob64: c_ulonglong,
    };
};

pub const Returns = enum {
    blob,
    double,
    int,
    int64,
    text,
    text16,
    value,

    pub fn from(comptime T: type) Returns {
        switch (@typeInfo(T)) {
            .Int => return .int64,
            .Float => return .double,
            .Bool => return .int64,
            .Optional => |o| return Returns.from(o.child),
            .Pointer => |p| {
                switch (p.size) {
                    .One => return .blob,
                    .Slice => return .text,
                    .Many => return .blob,
                    .C => return .blob,
                }
            },
            .Array, .Enum, .EnumLiteral, .ErrorSet, .ErrorUnion, .Vector, .AnyFrame, .Frame, .Opaque, .Fn, .Union, .Undefined, .Void, .NoReturn, .Type, .ComptimeFloat, .ComptimeInt, .Null, .Struct => {
                unreachable;
            },
        }
    }

    pub fn Repr(comptime self: Returns) type {
        return switch (self) {
            .blob => struct {
                ptr: ?*anyopaque,
                len: usize,
            },
            .double => f64,
            .int => i32,
            .int64 => i64,
            .text => []const u8,
            .text16 => []const u8,
            .value => *c.sqlite3_value,
        };
    }
};

pub const Type = enum(c_int) {
    int = c.SQLITE_INTEGER,
    float = c.SQLITE_FLOAT,
    text = c.SQLITE3_TEXT,
    blob = c.SQLITE_BLOB,
    null = c.SQLITE_NULL,
};
