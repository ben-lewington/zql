const std = @import("std");
const zql = @import("zql");
const adaptors = zql.adaptors;
const utils = zql.utils;

const Atom = utils.Atom;
const Dialect = adaptors.Dialect;
const Assert = utils.StaticAssert;

const Model = @This();
pub const Query = @import("Query.zig");
pub const Predicate = @import("Predicate.zig");
const log = std.log.scoped(.zql_model);

name: []const u8 = "",
table_name: []const u8,
Table: type,
ColumnOf: type,
db_types: []const adaptors.Dialect.DbType,
dialect: Dialect,

pub fn TypeOf(comptime self: Model, comptime col: []const u8) type {
    const v: self.Table = undefined;
    return @TypeOf(@field(v, col));
}

pub const Stmt = union(enum) {
    create: struct {
        handle_collision: ?enum { if_not_exists, or_replace } = null,
    },
    select: struct {
        columns: ?[]const Atom = null,
        where: ?Predicate = null,
    },
    insert: struct {
        columns: []const Atom,
        returning: ?[]const Atom = null,
        num_rows: usize = 1,
        must_use_binds: bool = true,
    },

    pub fn fmt(comptime self: Stmt) []const u8 {
        switch (self) {
            .create => |c| {
                return "create" ++ if (c.handle_collision) |h| " " ++ @tagName(h) else "";
            },
            .select => |s| {
                return "select (" ++ comptime utils.joinAtoms(s.columns orelse &.{}, .{}) ++ ")" ++
                    if (s.where) |_| " filtered" else "";
            },
            .insert => |i| {
                return "insert " ++ std.fmt.comptimePrint("{}", .{i.num_rows}) ++ "x(" ++
                    comptime utils.joinAtoms(i.columns, .{}) ++ ")" ++ if (i.returning) |r| " returning (" ++
                    utils.joinAtoms(r, .{}) ++ ")" else "";
            },
        }
    }
};

pub fn query(comptime self: Model, comptime stmt: Stmt) Query {
    switch (stmt) {
        .select => |s| {
            if (s.columns) |cs| {
                Assert.isSubType(self.Table, utils.atomsToTagNames(cs));
            }
        },
        .insert => |i| {
            Assert.isSubType(self.Table, utils.atomsToTagNames(i.columns));
            if (i.returning) |rs| {
                Assert.isSubType(self.Table, utils.atomsToTagNames(rs));
            }
        },
        else => {},
    }
    return .{
        .model = self,
        .stmt = stmt,
    };
}

pub fn predicate(comptime self: Model, comptime value: anytype) Predicate {
    return .{
        .model = self,
        .node = Predicate.Parser(self).parse(@TypeOf(value)),
    };
}

pub fn TypeOfCol(comptime self: Model, comptime field: []const u8) type {
    const full = @typeInfo(self.Table).Struct;
    inline for (full.fields) |col| {
        if (std.mem.eql(u8, field, col.name)) return col.type else {
            @compileError(@tagName(col) ++ " is not a column in " ++ @typeName(self.Table));
        }
    }
}

pub fn ColsType(comptime self: Model, comptime cols: []const Atom) type {
    return utils.AnonFieldType(self.Table, utils.atomsToTagNames(cols));
}

pub fn ValueType(comptime self: Model, comptime field: Atom) type {
    return utils.AnonFieldType(self.Table, &.{@tagName(field)});
}

pub fn ColsTypeStr(comptime self: Model, comptime cols: [][]const u8) type {
    return utils.AnonFieldType(self.Table, cols);
}

pub fn ValueTypeStr(comptime self: Model, comptime field: []const u8) type {
    return utils.AnonFieldType(self.Table, &.{field});
}
