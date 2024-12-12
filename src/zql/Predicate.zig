const std = @import("std");
const Predicate = @This();

const zql = @import("zql");
const adaptors = zql.adaptors;
const utils = zql.utils;
const Assert = utils.StaticAssert;
const Atom = utils.Atom;
const Model = @import("Model.zig");

model: Model,
node: Node,

pub const Combinator = enum {
    not,
    @"or",
    @"and",
};

pub const BinOp = enum {
    @"=",
    @"!=",
    @"<",
    @">",
    @"<=",
    @">=",
};

pub const Node = union(enum) {
    input: struct {
        field_name: []const u8,
        op: BinOp = .@"=",
        field_first: bool = true,
        value: ?[]const u8 = null,
    },
    compare_columns: struct {
        field_names: [2][]const u8,
        op: BinOp = .@"=",
        reverse: bool = false,
    },
    not: *const Node,
    @"and": []const Node,
    @"or": []const Node,

    fn strThr(comptime self: *const Node, comptime model: Model, comptime pred: *[]const u8) void {
        switch (self.*) {
            .input => |i| {
                const val = if (i.value) |v| v else model.dialect.bind_value_str(model.TypeOf(i.field_name));
                pred.* = pred.* ++ i.field_name ++ " " ++ @tagName(i.op) ++ " " ++ val;
            },
            .compare_columns => |cc| {
                _ = cc;
            },
            .not => |neg| pred.* = pred.* ++ "!(" ++ neg.str(model, pred) ++ ")",
            .@"or", .@"and" => |junc| {
                comptime var delim: []const u8 = "";
                const op = utils.toUpperAsciiComptime(@tagName(self.*));
                pred.* = pred.* ++ delim ++ "(";
                inline for (junc) |pr| {
                    pred.* = pred.* ++ delim;
                    pr.strThr(model, pred);
                    pred.* = pred.*;
                    delim = std.fmt.comptimePrint("\n   {s: >3} ", .{op});
                }
                pred.* = pred.* ++ ")";
            },
        }
    }
};

pub fn str(comptime self: Predicate) []const u8 {
    var out: []const u8 = "";
    self.node.strThr(self.model, &out);
    return out;
}

const BindCtx = struct {
    const BindField = struct {
        Type: type,
    };
};

pub fn BindType(comptime self: Predicate) ?type {
    const len = b: {
        const Count = struct {
            fn run(comptime node: Node, len: *usize) void {
                switch (node) {
                    .input => |i| if (i.value == null) {
                        len += 1;
                    },
                    .not => |n| run(n, len),
                    .@"and" => |a| for (a) |p| run(p, len),
                    .@"or" => |o| for (o) |p| run(p, len),
                    else => return,
                }
            }
        };
        comptime var l: usize = 0;
        Count.run(self.node, &l);
        break :b l;
    };

    if (len == 0) return null;

    const bindfields = f: {
        const StructField = std.builtin.Type.StructField;
        const Collect = struct {
            fn run(comptime node: Node, fields: *utils.Region(len, StructField)) void {
                switch (node) {
                    .input => |i| if (i.value == null) {
                        fields.append(StructField{
                            .name = i.field_name,
                            .type = self.model.TypeOfCol(i.field_name),
                            .alignment = @alignOf(self.model.TypeOfCol(i.field_name)),
                            .is_comptime = false,
                            .default_value = null,
                        });
                    },
                    .not => |n| run(n, fields),
                    .@"and" => |a| for (a) |p| run(p, fields),
                    .@"or" => |o| for (o) |p| run(p, fields),
                    else => return,
                }
            }
        };
        comptime var bfs: utils.Region(len, StructField) = .{};
        Collect.run(self.node, &bfs);

        break :f bfs;
    };

    return @Type(std.builtin.Type{
        .Struct = .{
            .fields = bindfields.data[0..bindfields.len],
            .decls = &.{},
            .layout = .auto,
            .is_tuple = false,
        },
    });
}

pub fn Parser(comptime model: Model) type {
    return struct {
        const NodeType = union(enum) {
            branch: Combinator,
            leaf: BinOp,
        };

        fn nodeType(comptime T: type) NodeType {
            const ti = @typeInfo(T).Struct;

            if (ti.fields.len == 1) {
                const f = ti.fields[0];
                return if (std.meta.stringToEnum(Combinator, f.name)) |com| .{
                    .branch = com,
                } else if (std.meta.stringToEnum(BinOp, f.name)) |op| .{
                    .leaf = op,
                } else @compileError(":)");
            }
        }

        fn parseLeafNode(comptime T: type, comptime op: BinOp) Predicate.Node {
            const ti = @typeInfo(T).Struct;
            const fval = ti.fields[0];
            const child = @typeInfo(fval.type);
            switch (child) {
                .Struct => |cs| {
                    if (cs.fields.len == 1) {
                        const col = cs.fields[0];
                        if (col.type != utils.Atom) @compileError("");
                        const ff: *const Atom = @ptrCast(col.default_value);
                        const fname = @tagName(ff.*);
                        Assert.isFieldOf(model.Table, fname);
                        return Node{ .input = .{
                            .field_name = fname,
                            .op = op,
                        } };
                    } else if (cs.fields.len == 2) {
                        var t1 = cs.fields[0];
                        var t2 = cs.fields[1];
                        if (t1.type == Atom and t2.type == Atom) {
                            const ff1: *const Atom = @ptrCast(t1.default_value);
                            const f1name = @tagName(ff1.*);
                            Assert.isFieldOf(model.Table, f1name);
                            const ff2: *const Atom = @ptrCast(t2.default_value);
                            const f2name = @tagName(ff2.*);
                            Assert.isFieldOf(model.Table, f2name);
                            return Node{ .compare_columns = [2].{
                                ff1,
                                ff2,
                            } };
                        } else if (t1.type == Atom or t2.type == Atom) {
                            var field_first = true;
                            if (t2.type == Atom) {
                                const tmp = t2;
                                t2 = t1;
                                t1 = tmp;
                                field_first = false;
                            }
                            const ff: *const Atom = @ptrCast(t1.default_value);
                            const fname = @tagName(ff.*);
                            Assert.isFieldOf(model.Table, fname);
                            const v: ?*const t2.type = @alignCast(@ptrCast(t2.default_value));
                            if (v) |default| {
                                switch (@typeInfo(t2.type)) {
                                    .ComptimeInt, .Int => {
                                        const val: i64 = @intCast(default.*);
                                        return Node{ .input = .{
                                            .field_name = fname,
                                            .op = op,
                                            .field_first = field_first,
                                            .value = std.fmt.comptimePrint("{}", .{val}),
                                        } };
                                    },
                                    .Pointer => |p| {
                                        switch (p.size) {
                                            .Slice => {
                                                @compileError("" ++ @typeName(p.child));
                                            },
                                            .One => {
                                                switch (@typeInfo(p.child)) {
                                                    .Struct => {},
                                                    .Array => |a| {
                                                        if (a.child != u8) @compileError("expected u8 array");
                                                        comptime var st: [a.len]u8 = undefined;
                                                        inline for (default.*, 0..) |ch, i| {
                                                            st[i] = ch;
                                                        }
                                                        const strs = st;

                                                        return Node{ .input = .{
                                                            .field_name = fname,
                                                            .op = op,
                                                            .field_first = field_first,
                                                            .value = "\"" ++ strs[0..a.len] ++ "\"",
                                                        } };
                                                    },
                                                    else => {},
                                                }
                                            },
                                            .C, .Many => @compileError(@tagName(p.size) ++ " " ++ @typeName(p.child)),
                                        }
                                    },
                                    else => |e| @compileError(@tagName(e)),
                                }
                            } else return Node{ .input = .{
                                .field_name = fname,
                                .op = op,
                                .field_first = field_first,
                            } };
                        } else @compileError("");
                    } else @compileError(
                        "expected child to be either .{Atom}, .{Atom, <value>}, or .{Atom, Atom}",
                    );
                },
                .EnumLiteral => {
                    const atom: *const Atom = @ptrCast(fval.default_value);
                    return Node{ .input = .{
                        .field_name = @tagName(atom.*),
                        .op = op,
                    } };
                },
                else => |e| @compileLog("sussy: " ++ @tagName(e)),
            }
        }

        pub fn parse(comptime T: type) Node {
            const ti = @typeInfo(T).Struct;
            const nt = nodeType(T);
            switch (nt) {
                .leaf => |op| return parseLeafNode(T, op),
                .branch => |com| {
                    const fval = ti.fields[0];
                    const child = @typeInfo(fval.type).Struct;
                    if (com == .not and child.fields.len != 1) @compileError("");
                    comptime var child_nodes: [child.fields.len]Node = undefined;
                    for (child.fields, 0..) |cf, i| {
                        const nnt = nodeType(cf.type);
                        switch (nnt) {
                            .leaf => |op| {
                                child_nodes[i] = parseLeafNode(cf.type, op);
                            },
                            .branch => {
                                child_nodes[i] = parse(cf.type);
                            },
                        }
                    }
                    const chnode = child_nodes;
                    if (com == .not) return Node{ .not = &chnode[0] };
                    const chs: []const Node = chnode[0..child.fields.len];
                    return switch (com) {
                        .@"and" => .{ .@"and" = chs },
                        .@"or" => .{ .@"or" = chs },
                        else => unreachable,
                    };
                },
            }
        }
    };
}
