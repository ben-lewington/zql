const std = @import("std");
pub const c = @cImport(@cInclude("libpq-fe.h"));

pub const log = std.log.scoped(.zql_pgsql_bindings);

pub const Conn = struct {
    inner: ?*c.PGconn = undefined,

    pub fn init(self: *Conn, conn_str: [:0]const u8) !void {
        self.inner = c.PQconnectdb(conn_str);

        if (c.PQstatus(self.inner) != c.CONNECTION_OK) {
            log.err("{s}", .{c.PQerrorMessage(self.inner)});
            return error.Init;
        }
    }

    pub fn deinit(self: *Conn) void {
        c.PQfinish(self.inner);
    }
};
