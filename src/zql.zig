const std = @import("std");
const Atom = @TypeOf(.enum_literal);

pub const Model = @import("zql/Model.zig");
pub const Stmt = Model.Stmt;
pub const adaptors = @import("adaptors.zig");
pub const utils = @import("comptime_utils.zig");

const Dialect = adaptors.Dialect;
const TaggedType = adaptors.Dialect.TaggedType;

pub fn model(
    comptime Constituents: []const type,
    comptime table_name: Atom,
    comptime dialect: Dialect,
) Model {
    const StructField = std.builtin.Type.StructField;
    const total_fields = blk: {
        var i: usize = 0;
        inline for (Constituents) |Fields| i += @typeInfo(Fields).Struct.fields.len;
        break :blk i;
    };
    const ValidatedSuperType = b: {
        var chk_fields: utils.Region(total_fields, StructField) = .{};

        inline for (Constituents) |Fields| {
            switch (@typeInfo(Fields)) {
                .Struct => |s| {
                    inline for (s.fields) |f| {
                        inline for (chk_fields.data[0..chk_fields.len]) |cf| {
                            if (std.mem.eql(u8, f.name, cf.name)) {
                                @compileError("constituent field names must be unique");
                            }
                        }
                        chk_fields.data[chk_fields.len] = f;
                        chk_fields.len += 1;
                    }
                },
                else => @compileError("constituent types must be structs"),
            }
        }

        const sfields = chk_fields.data;
        break :b @Type(std.builtin.Type{
            .Struct = .{
                .fields = &sfields,
                .decls = &.{},
                .layout = .auto,
                .is_tuple = false,
            },
        });
    };
    const validated = @typeInfo(ValidatedSuperType).Struct;
    const table: struct { Inner: type, db_types: [validated.fields.len]Dialect.DbType } = tyb: {
        const FieldResolver = struct {
            pub fn run(comptime FieldType: type) struct { Repr: type, db_type: adaptors.Dialect.DbType } {
                var tt: TaggedType = .{ .Unwrapped = FieldType };
                switch (@typeInfo(FieldType)) {
                    .Struct => |s| {
                        if (s.fields.len == 2 and
                            std.mem.eql(u8, s.fields[0].name, "inner") and
                            std.mem.eql(u8, s.fields[1].name, "tags") and
                            s.fields[1].is_comptime)
                        {
                            switch (@typeInfo(s.fields[1].type)) {
                                .Optional => |o| {
                                    switch (@typeInfo(o.child)) {
                                        .Enum => |e| {
                                            var tags: [e.fields.len][]const u8 = undefined;
                                            for (e.fields, 0..) |ef, i| {
                                                tags[i] = ef.name;
                                            }
                                            tt.tags = &tags;
                                        },
                                        else => {
                                            @compileError("tags must be an enum");
                                        },
                                    }
                                },
                                else => {
                                    @compileError("tags must be an enum");
                                },
                            }
                            tt.Unwrapped = s.fields[0].type;
                        }
                    },
                    else => {},
                }
                return .{
                    .Repr = tt.Unwrapped,
                    .db_type = dialect.handle_tagged_type(tt),
                };
            }
        };

        var tr: [validated.fields.len]StructField = undefined;
        var dbt: [validated.fields.len]adaptors.Dialect.DbType = undefined;
        for (validated.fields, 0..) |f, i| {
            const rt = FieldResolver.run(f.type);
            tr[i] = StructField{
                .name = f.name,
                .type = rt.Repr,
                .is_comptime = false,
                .alignment = @alignOf(rt.Repr),
                .default_value = null,
            };
            dbt[i] = rt.db_type;
        }

        const trf = tr;
        break :tyb .{
            .Inner = @Type(std.builtin.Type{
                .Struct = .{
                    .fields = &trf,
                    .decls = &.{},
                    .is_tuple = false,
                    .layout = .auto,
                },
            }),
            .db_types = dbt,
        };
    };

    const ColumnOf: type = std.meta.FieldEnum(table.Inner);

    return .{
        .Table = table.Inner,
        .ColumnOf = ColumnOf,
        .db_types = &table.db_types,
        .table_name = @tagName(table_name),
        .dialect = dialect,
    };
}
