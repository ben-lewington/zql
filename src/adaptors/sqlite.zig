comptime {
    if (!(@import("config").include_sqlite)) @compileError("pass -Dsqlite to compile sqlite adaptor");
}
const std = @import("std");

pub const sqlite = @import("bindings/sqlite.zig");
pub const Db = sqlite.Db;
const log = std.log.scoped(.zql_sqlite_adaptor);

const zql = @import("zql");
const adaptors = zql.adaptors;
const utils = zql.utils;

pub const dialect = adaptors.Dialect{
    .bind_value_str = Dialect.bindValueStr,
    .visit_create_sql = Dialect.visitCreateSql,
    .handle_tagged_type = Dialect.handleTaggedType,
};

pub const Ctx = struct {
    db: sqlite.Db,
    stmt: sqlite.Statement = .{},
};

pub const Executor = struct {
    ctx: *anyopaque,

    pub fn init(ctx: *anyopaque, sql_stmt: []const u8) anyerror!void {
        const self: *Ctx = @alignCast(@ptrCast(ctx));
        self.stmt = sqlite.Statement.init(self.db, sql_stmt) catch {
            const errstr: [*:0]const u8 = sqlite.c.sqlite3_errmsg(self.db.inner);
            log.err("{s}", .{errstr});
            return error.Init;
        };
    }

    pub fn deinit(ctx: *anyopaque) void {
        const self: *Ctx = @alignCast(@ptrCast(ctx));
        self.stmt.deinit();
    }

    pub fn step(ctx: *anyopaque) anyerror!adaptors.CursorStatus {
        const self: *Ctx = @alignCast(@ptrCast(ctx));
        var curs = self.stmt.step();

        const status = curs.next() catch {
            const errstr: [*:0]const u8 = sqlite.c.sqlite3_errmsg(self.db.inner);
            log.err("{s}", .{errstr});
            return error.Step;
        };
        return switch (status) {
            .done => .done,
            .more => .more,
        };
    }

    pub fn bind(ctx: *anyopaque, value: anytype, ix_1: usize) anyerror!void {
        const self: *Ctx = @alignCast(@ptrCast(ctx));
        var arg: ?sqlite.Statement.BindArgs = null;
        switch (@typeInfo(@TypeOf(value))) {
            .Int => |i| {
                if (i.bits > 64) @compileError("");
                arg = .{ .int64 = @intCast(value) };
            },
            .ComptimeInt => {
                arg = .{ .int64 = @intCast(value) };
            },
            .Float => |f| {
                if (f.bits > 64) @compileError("");
                arg = .{ .double = @floatCast(value) };
            },
            .ComptimeFloat => {
                arg = .{ .double = @floatCast(value) };
            },
            .Null => {
                arg = .null;
            },
            .Bool => {
                arg = .{ .int64 = @intFromBool(value) };
            },
            .Struct => |s| {
                if (s.fields.len != 1) @compileError("not implemented");
            },
            .Optional => {},
            .Array => |a| {
                const sz: usize = @sizeOf(a.child) * a.len;
                arg = .{ .blob = .{ .inner = .{
                    .ptr = &value,
                    .len = sz,
                } } };
            },
            .Pointer => |p| {
                switch (p.size) {
                    .One => {
                        arg = .{ .blob = .{ .inner = .{
                            .ptr = @constCast(@alignCast(@ptrCast(value))),
                            .len = @sizeOf(p.child),
                        } } };
                    },
                    .Slice => {
                        arg = .{ .text = .{ .inner = value } };
                    },
                    .Many, .C => @compileError(""),
                }
            },
            .Enum, .EnumLiteral => {
                const t = @tagName(value);
                arg = .{ .text = .{ .inner = .{
                    .ptr = t.ptr,
                    .len = t.len,
                } } };
            },
            .ErrorSet, .ErrorUnion => @compileError(""),
            .Vector, .AnyFrame, .Frame, .Opaque, .Fn, .Union => @compileError(""),
            .Undefined, .Void, .NoReturn => @compileError(""),
            .Type => @compileError(""),
        }
        if (arg) |a| {
            try self.stmt.bind(ix_1, a);
        } else {
            const errstr: [*:0]const u8 = sqlite.c.sqlite3_errmsg(self.db.inner);
            log.err("{s}", .{errstr});
            return error.UnableToBind;
        }
    }

    pub fn column(ctx: *anyopaque, comptime As: type, ix_0: usize, out_ptr: *anyopaque) anyerror!void {
        const self: *Ctx = @alignCast(@ptrCast(ctx));
        const out: *As = @alignCast(@ptrCast(out_ptr));
        const retty = comptime sqlite.Returns.from(As);
        const val = self.stmt.column(sqlite.Returns.from(As), ix_0);
        switch (retty) {
            .int, .int64 => {
                out.* = @intCast(val);
            },
            .double => {
                out.* = @floatCast(val);
            },
            .blob, .text, .text16, .value => {
                out.* = val;
            },
        }
    }
};

pub const DataType = enum {
    int,
    real,
    text,
    blob,
    any,

    const datatype = @typeInfo(DataType).Enum;

    const Reprs: [datatype.fields.len]type = b: {
        var ty: [datatype.fields.len]type = undefined;
        for (datatype.fields, 0..) |f, i| {
            ty[i] = switch (@field(DataType, f.name)) {
                .int => i64,
                .real => f64,
                .text => [*c]const u8,
                .blob => *const anyopaque,
                .any => *sqlite.c.struct_sqlite3_value,
            };
        }
        break :b ty;
    };

    pub const db_type_strs: [datatype.fields.len][]const u8 = ts: {
        var dts: [datatype.fields.len][]const u8 = undefined;
        for (datatype.fields, 0..) |f, i| {
            dts[i] = utils.toUpperAsciiComptime(f.name);
        }
        break :ts dts;
    };

    fn fromNotNull(comptime T: type, ptr_depth: *usize) DataType {
        const ti = @typeInfo(T);
        switch (ti) {
            .Optional => @compileError("Types passed to this function cannot be optional"),
            .ComptimeInt => return DataType.int,
            .ComptimeFloat => return DataType.real,
            .Int => |i| {
                if (i.bits > 64) @compileError("blob storage for integers > 64 bits is not implemented");
                return DataType.int;
            },
            .Float => |f| {
                if (f.bits > 64) @compileError("blob storage for floats > 64 bits is not implemented");
                return DataType.real;
            },
            .Bool => return DataType.int,
            .Null => @compileError("unable to infer datatype from null literal"),
            .Array => |a| {
                _ = a;
            },
            .Pointer => |p| {
                switch (p.size) {
                    .One => {
                        if (!p.is_const) @compileError("expected a *const ptr to a value");
                        ptr_depth.* += 1;
                        return fromNotNull(p.child, ptr_depth);
                    },
                    .C => {},
                    .Many => {},
                    .Slice => {
                        if (p.child != u8) @compileError("only u8 slices are currently implemented");
                        return DataType.text;
                    },
                }
            },
            .Struct => {},
            .Enum, .ErrorSet, .ErrorUnion => {},
            .EnumLiteral, .Vector, .AnyFrame, .Frame, .Opaque, .Fn, .Union => {},
            .Undefined, .Void, .NoReturn => {},
            .Type => {},
        }
        @compileError(@tagName(ti) ++ " is not implemented");
    }

    pub fn from(comptime T: type) struct {
        repr: DataType,
        nullable: bool,
        ptr_depth: usize,
    } {
        const ti: std.builtin.Type = @typeInfo(T);
        var pd: usize = 0;
        const typer = switch (ti) {
            .Optional => |o| .{
                .repr = DataType.fromNotNull(o.child, &pd),
                .nullable = true,
            },
            else => .{
                .nullable = false,
                .repr = DataType.fromNotNull(T, &pd),
            },
        };
        return .{
            .repr = typer.repr,
            .nullable = typer.nullable,
            .ptr_depth = pd,
        };
    }
};

const Dialect = struct {
    fn visitCreateSql(comptime create_sql: []const u8) []const u8 {
        return create_sql ++ " STRICT";
    }

    fn handleTaggedType(comptime tt: adaptors.Dialect.TaggedType) adaptors.Dialect.DbType {
        const info = DataType.from(tt.Unwrapped);
        var stmt: []const u8 = DataType.db_type_strs[@intFromEnum(info.repr)];

        if (!info.nullable) stmt = stmt ++ " NOT NULL";

        //FIXME: tag validation layer
        inline for (tt.tags) |tag| {
            stmt = stmt ++ " " ++ DataType.toUpperAsciiComptime(tag);
        }

        return adaptors.Dialect.DbType{
            .type_name = @tagName(info.repr),
            .create_str = stmt,
        };
    }

    fn bindValueStr(comptime T: type) []const u8 {
        _ = T;
        return "?";
    }
};
