const std = @import("std");
const zql = @import("zql");
const utils = zql.utils;
const pgsql = zql.adaptors.pgsql;

const Example = struct {
    id: usize,
};

const model = zql.model(&.{Example}, .foo, pgsql.dialect);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leaked memory");
    const alc = gpa.allocator();

    const conn_str = "host=0.0.0.0 port=8432 user=user password=Password1! dbname=db";
    var conn = try pgsql.Conn.init(alc, conn_str);
    defer conn.deinit();

    inline for (std.meta.fields(pgsql.pgsql.DataType.Tag)) |t| {
        if (conn.oids.get(t.name)) |oid| {
            std.log.debug("found {s}: {}", .{ t.name, oid });
        } else {
            std.log.debug("MISS {s}", .{t.name});
        }
    }
    std.log.debug("int4: {}", .{conn.oids.get("int4") orelse 0});
    const stmt = model.query(.{ .create = .{ .handle_collision = .if_not_exists } });
    std.log.debug("{s}", .{stmt.stmtSql()});

    // stmt.run(pgsql.)
}
