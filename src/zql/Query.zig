const std = @import("std");
const zql = @import("zql");
const adaptors = zql.adaptors;
const utils = zql.utils;

const Assert = utils.StaticAssert;
const Atom = utils.Atom;
const Query = @This();
const Model = @import("Model.zig");
const Stmt = Model.Stmt;
const ExecutorI = adaptors.ExecutorI;

const log = std.log.scoped(.zql_model_query);

model: Model,
stmt: Stmt,

pub fn run(
    comptime self: Query,
    executor: anytype,
) self.RuntimeCtx(ExecutorI.Is(@TypeOf(executor))) {
    const Executor = @TypeOf(executor);
    log.debug("model <" ++ self.model.table_name ++ ">: produced statement:\n    " ++ self.stmt.fmt(), .{});
    const sql = comptime self.stmtSql() ++ ";";
    try Executor.init(executor.ctx, sql);
    switch (self.stmt) {
        .create => {
            _ = try Executor.step(executor.ctx);
            Executor.deinit(executor.ctx);
        },
        .select => return .{ .exec = executor },
        .insert => return .{ .exec = executor },
    }
}

pub fn RuntimeCtx(comptime self: Query, comptime Executor: type) type {
    return anyerror!switch (self.stmt) {
        // statement runs to completion and is finalised with the client
        .create => void,
        //
        .insert => |i| self.AwaitingInput(Executor, .{
            .input = .{ .insert = .{
                .columns = i.columns,
                .num_rows = i.num_rows,
                .must_use_binds = i.must_use_binds,
            } },
            .returning = i.returning,
        }),
        //
        .select => |s| b: {
            if (s.where) |p| {
                if (p.BindType()) |B| break :b self.AwaitingInput(Executor, .{
                    .input = .{ .value_list = B },
                });
            }
            break :b self.ReturningCursor(Executor, .{ .columns = s.columns });
        },
    };
}

fn AwaitingInput(comptime self: Query, comptime Executor: type, comptime opts: struct {
    input: union(enum) {
        value_list: type,
        insert: struct {
            columns: []const Atom,
            num_rows: usize = 1,
            must_use_binds: bool = true,
        },
    },
    returning: ?[]const Atom = null,
}) type {
    switch (opts.input) {
        .insert => |i| {
            return struct {
                const Ctx = @This();
                exec: Executor,
                binds: struct {
                    total: usize = i.num_rows * i.columns.len,
                    cur: usize = 1,
                } = .{},

                pub fn bindRecord(this: *Ctx, value: anytype) !void {
                    const value_ti = @typeInfo(@TypeOf(value)).Struct;
                    Assert.isStructEq(self.model.ColsType(i.columns), @TypeOf(value));
                    if (this.binds.total - (this.binds.cur - 1) < value_ti.fields.len) return error.Bind;
                    inline for (value_ti.fields) |f| {
                        const v = @field(value, f.name);
                        // log.debug("binding value .{s} = {any}, {*}", .{ f.name, v, this.exec.ctx });
                        try Executor.bind(this.exec.ctx, v, this.binds.cur);
                        this.binds.cur += 1;
                    }
                }

                pub fn bindRecords(this: *Ctx, values: anytype) !void {
                    switch (@typeInfo(@TypeOf(values))) {
                        .Struct => try this.bindValue(values),
                        .Pointer => |p| {
                            switch (p.size) {
                                .Slice => for (values) |v| try this.bindValue(v),
                                else => @compileError(@typeName(p.child)),
                            }
                        },
                        .Array => |a| for (0..a.len) |j| try this.bindValue(values[j]),
                        else => @compileError(""),
                    }
                }

                pub fn ready(this: *Ctx) !self.ReturningCursor(Executor, .{
                    .columns = opts.returning orelse &.{},
                }) {
                    if (!(i.must_use_binds and
                        this.binds.cur - 1 == this.binds.total))
                    {
                        log.err(
                            "parameters must be used: expected {} bound, got {}",
                            .{ this.binds.total, this.binds.cur - 1 },
                        );
                        return error.UnboundParams;
                    }
                    return .{ .exec = this.exec };
                }
            };
        },
        .value_list => @compileError("TODO"),
    }
}

fn ReturningCursor(comptime self: Query, comptime Executor: type, comptime opts: struct {
    columns: ?[]const Atom = null,
}) type {
    const C = utils.AnonFieldType(self.model.Table, utils.atomsToTagNames(opts.columns orelse &.{}));
    return struct {
        exec: Executor,

        pub fn next(this: *@This()) anyerror!?C {
            switch (try Executor.step(this.exec.ctx)) {
                .done => {
                    Executor.deinit(this.exec.ctx);
                    return null;
                },
                .more => {
                    var ret: C = undefined;
                    inline for (@typeInfo(C).Struct.fields, 0..) |f, j| {
                        const outp: *f.type = &@field(ret, f.name);
                        try Executor.column(this.exec.ctx, f.type, j, @ptrCast(@alignCast(outp)));
                    }
                    return ret;
                },
            }
        }
    };
}

pub fn stmtSql(comptime self: Query) []const u8 {
    const full = @typeInfo(self.model.Table).Struct;
    comptime var sql: []const u8 = "\n";
    switch (self.stmt) {
        .create => |c| {
            sql = sql ++ if (c.handle_collision) |f| switch (f) {
                .if_not_exists => "CREATE TABLE IF NOT EXISTS ",
                .or_replace => "CREATE OR REPLACE TABLE ",
            } else "CREATE TABLE ";
            sql = sql ++ self.model.table_name ++ " (\n";
            comptime var head_delim: []const u8 = "    ";
            inline for (full.fields, self.model.db_types) |fld, db_type| {
                sql = sql ++ head_delim ++ fld.name ++ " " ++ db_type.create_str;
                head_delim = "\n  , ";
            }
            sql = sql ++ "\n)";
            return self.model.dialect.visit_create_sql(sql);
        },
        .select => |s| {
            Assert.isSubType(self.model.Table, utils.atomsToTagNames(s.columns orelse &.{}));
            sql = sql ++ "SELECT ";

            var delim: []const u8 = "";
            if (s.columns) |cols| {
                inline for (cols) |col| {
                    var found = false;
                    const coln = @tagName(col);
                    inline for (full.fields) |ff| {
                        if (std.mem.eql(u8, coln, ff.name)) found = true;
                    }
                    if (!found) {
                        @compileError(coln ++ " is not a column in " ++ self.model.table_name);
                    }
                    sql = sql ++ delim ++ coln;
                    delim = "\n     , ";
                }
            } else sql = sql ++ "*";

            sql = sql ++ "\n  FROM " ++ self.model.table_name;

            sql = sql ++ if (s.where) |pred|
                "\n WHERE 1 = 1\n   AND (" ++ comptime pred.str() ++ ")\n"
            else
                "\n";

            return sql;
        },
        .insert => |i| {
            Assert.isSubType(self.model.Table, utils.atomsToTagNames(i.columns));
            const Columns = utils.AnonFieldType(self.model.Table, utils.atomsToTagNames(i.columns));
            Assert.isSubType(self.model.Table, utils.atomsToTagNames(i.returning orelse &.{}));

            sql = sql ++ "INSERT INTO " ++ self.model.table_name ++ " (";

            comptime var delim: []const u8 = "";
            inline for (i.columns) |f| {
                sql = sql ++ delim ++ @tagName(f);
                delim = ", ";
            }
            sql = sql ++ ")\n     VALUES ";
            delim = "";
            inline for (0..i.num_rows) |_| {
                comptime var idelim: []const u8 = delim ++ "(";
                inline for (@typeInfo(Columns).Struct.fields) |f| {
                    const ty = comptime self.model.dialect.bind_value_str(f.type);
                    sql = sql ++ idelim ++ ty;
                    idelim = ", ";
                }
                sql = sql ++ ")";
                delim = "\n          , ";
            }

            if (i.returning) |ret| {
                delim = "\n  RETURNING ";
                inline for (ret) |r| {
                    sql = sql ++ delim ++ @tagName(r);
                    delim = "\n          , ";
                }
            }

            sql = sql ++ "\n";
            return sql;
        },
    }
}
