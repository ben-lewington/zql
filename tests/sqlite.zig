const std = @import("std");
const zql = @import("zql");
const utils = zql.utils;
const adaptors = zql.adaptors;
const sqlite = adaptors.sqlite;

const Foo = struct {
    id: usize,
    name: []const u8,
};

const model = zql.model(&.{Foo}, .foo, sqlite.dialect);

const db_name = "test.sqlite";

pub fn main() !void {
    var db = try sqlite.Db.init(db_name);
    defer db.deinit();
    var ctx = sqlite.Ctx{ .db = db };
    const exec = sqlite.Executor{ .ctx = @ptrCast(&ctx) };

    comptime var stmt = model.query(.{ .create = .{ .handle_collision = .if_not_exists } });
    try stmt.run(exec);

    stmt = model.query(.{ .insert = .{
        .columns = &.{ .id, .name },
        .num_rows = 1,
        .returning = &.{.id},
    } });

    var binding = try stmt.run(exec);
    try binding.bindRecord(model.ColsType(&.{ .id, .name }){
        .id = 4,
        .name = "foobar",
    });

    var returning = try binding.ready();
    while (try returning.next()) |v| {
        std.log.debug("returning id: {}", .{v.id});
    }

    stmt = model.query(.{ .select = .{
        .columns = &.{ .id, .name },
        .where = model.predicate(.{ .@"or" = .{
            .{ .@"=" = .{ .name, "foobar" } },
            .{ .@"=" = .{ .id, 4 } },
        } }),
    } });

    var returns = try stmt.run(exec);

    while (try returns.next()) |v| {
        std.log.debug("selecting id: {} name: {s}", .{ v.id, v.name });
    }
}
