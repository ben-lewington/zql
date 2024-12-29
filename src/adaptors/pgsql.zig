comptime {
    if (!(@import("config").include_pgsql)) @compileError("pass -Dpgsql to compile pgsql adaptor");
}
const std = @import("std");
pub const pgsql = @import("bindings/pgsql.zig");
pub const Conn = pgsql.Conn;
const log = std.log.scoped(.zql_pgsql_adaptor);

const zql = @import("zql");
const adaptors = zql.adaptors;
const utils = zql.utils;

pub const dialect = adaptors.Dialect{
    .bind_value_str = Dialect.bindValueStr,
    .visit_create_sql = Dialect.visitCreateSql,
    .handle_tagged_type = Dialect.handleTaggedType,
};

const Ctx = struct {
    conn: pgsql.Conn,
};

pub const Statement = struct {
    sql: []const u8,
};

const Executor = struct {
    ctx: *anyopaque,

    pub fn init(ctx_ptr: *anyopaque) !void {
        const self: *Ctx = @alignCast(@ptrCast(ctx_ptr));
        _ = self;
    }
};

const Dialect = struct {
    const D = adaptors.Dialect;

    pub fn bindValueStr(comptime T: type) []const u8 {
        _ = T;
        return "?";
    }

    pub fn visitCreateSql(comptime sql: []const u8) []const u8 {
        return sql;
    }

    pub fn handleTaggedType(comptime tags: D.TaggedType) D.DbType {
        _ = tags;
        return .{
            .type_name = "int",
            .create_str = "int not null",
        };
    }
};
