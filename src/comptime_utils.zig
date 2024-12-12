pub const Atom = @TypeOf(.enum_literal);
const std = @import("std");

pub fn joinAtoms(comptime atoms: []const Atom, comptime opts: struct {
    start_delim: []const u8 = "",
    thr_delim: []const u8 = ", ",
}) []const u8 {
    comptime var out: []const u8 = "";
    comptime var delim: []const u8 = opts.start_delim;
    inline for (atoms) |a| {
        out = out ++ delim ++ @tagName(a);
        delim = opts.thr_delim;
    }
    return out;
}

pub fn atomsToTagNames(comptime atoms: []const Atom) [][]const u8 {
    var tns: [atoms.len][]const u8 = undefined;
    inline for (atoms, 0..) |col, i| tns[i] = @tagName(col);

    return tns[0..atoms.len];
}

pub const StaticAssert = struct {
    pub fn isStructEq(comptime Table: type, comptime Other: type) void {
        const StructField = std.builtin.Type.StructField;
        const other = @typeInfo(Other).Struct;
        const full = @typeInfo(Table).Struct;
        inline for (other.fields) |of| {
            comptime var f: ?StructField = null;
            inline for (full.fields) |ff| {
                if (comptime std.mem.eql(u8, of.name, ff.name) and of.type == ff.type and
                    ff.alignment == of.alignment and ff.is_comptime == of.is_comptime and
                    ff.default_value == of.default_value) f = ff;
            }
            if (f == null) @compileError(of.name ++ " is not a field in " ++ @typeName(Table));
        }
    }

    pub fn isSubType(comptime Table: type, comptime fields: [][]const u8) void {
        const StructField = std.builtin.Type.StructField;
        const full = @typeInfo(Table).Struct;
        inline for (fields) |col| {
            comptime var f: ?StructField = null;
            inline for (full.fields) |ff| {
                const eq = comptime std.mem.eql(u8, col, ff.name);
                if (eq) f = ff;
            }
            if (f == null) @compileError(col ++ " is not a field in " ++ @typeName(Table));
        }
    }

    pub fn isFieldOf(comptime Table: type, comptime field_name: []const u8) void {
        const StructField = std.builtin.Type.StructField;
        const full = @typeInfo(Table).Struct;
        comptime var f: ?StructField = null;
        inline for (full.fields) |col| {
            const eq = comptime std.mem.eql(u8, field_name, col.name);
            if (eq) f = col;
        }
        if (f == null) @compileError(field_name ++ " is not a field in " ++ @typeName(Table));
    }

    pub fn comptimeInterface(comptime T: type) ComptimeInterface {
        const msg_start = "interface " ++ @typeName(T);
        switch (@typeInfo(T)) {
            .Struct => |s| {
                comptime var decls: [s.fields.len]ComptimeInterface.GenericVTableDecl = undefined;
                inline for (s.fields, 0..) |f, i| {
                    switch (@typeInfo(f.type)) {
                        .Fn => {
                            decls[i] = .{
                                .name = f.name,
                                .sig = f.type,
                            };
                        },
                        else => |e| @compileError(msg_start ++ ": decl signatures must be function types, found " ++ @tagName(e)),
                    }
                }
                const de = decls;
                return .{
                    .name = @typeName(T),
                    .decls = &de,
                };
            },
            else => @compileError(msg_start ++ ": definition must be a struct"),
        }
    }

    pub const ComptimeInterface = struct {
        name: []const u8,
        decls: []const GenericVTableDecl,

        pub const GenericVTableDecl = struct { name: []const u8, sig: type };

        pub fn is(comptime self: ComptimeInterface, comptime T: type) void {
            const msg_start = "interface " ++ self.name ++ ": impl " ++ @typeName(T);
            switch (@typeInfo(T)) {
                .Struct => |s| {
                    if (!(s.fields.len == 1 and s.fields[0].type == *anyopaque))
                        @compileError(msg_start ++ " must have one field, an opaque pointer");
                    inline for (self.decls) |if_decl| {
                        comptime var found: bool = false;
                        comptime var err_type: ?type = null;
                        inline for (s.decls) |d| {
                            const FldFn = @TypeOf(@field(T, d.name));
                            if (comptime std.mem.eql(u8, if_decl.name, d.name)) {
                                if (FldFn == if_decl.sig) {
                                    found = true;
                                } else err_type = FldFn;
                            }
                        }
                        if (!found) {
                            if (err_type) |ety| {
                                @compileError(msg_start ++ ": declaration " ++ if_decl.name ++
                                    " has the wrong signature. expected " ++
                                    @typeName(if_decl.sig) ++ ", got " ++ @typeName(ety));
                            } else @compileError(msg_start ++
                                " does not have a declaration for " ++ if_decl.name ++ ": " ++
                                @typeName(if_decl.sig));
                        }
                    }
                },
                else => @compileError("interface" ++ self.name ++ ": type " ++ @typeName(T) ++
                    " must be a struct"),
            }
        }

        pub fn Is(comptime self: ComptimeInterface, comptime T: type) type {
            self.is(T);
            return T;
        }
    };
};

pub fn Region(comptime n: comptime_int, comptime T: type) type {
    return struct {
        len: usize = 0,
        data: [n]T = undefined,

        pub fn append(comptime self: *@This(), comptime v: T) void {
            if (self.len == n) @compileError("overflow");
            self.data[self.len] = v;
            self.len += 1;
        }
    };
}

pub fn toUpperAsciiComptime(comptime input: []const u8) []const u8 {
    var ret: [input.len]u8 = undefined;
    inline for (input, 0..) |c, i| {
        ret[i] = std.ascii.toUpper(c);
    }
    const r = ret;
    return &r;
}

pub fn AnonFieldType(comptime Table: type, comptime fields: [][]const u8) type {
    const StructField = std.builtin.Type.StructField;
    const full = @typeInfo(Table).Struct;
    return @Type(std.builtin.Type{
        .Struct = .{
            .fields = b: {
                var sf: [fields.len]StructField = undefined;
                inline for (fields, 0..) |col, i| {
                    comptime var f: ?StructField = null;
                    inline for (full.fields) |ff| {
                        if (std.mem.eql(u8, col, ff.name)) f = ff;
                    }
                    if (f) |fld| {
                        sf[i] = fld;
                    } else {
                        @compileError(@tagName(col) ++ " is not a column in " ++ @typeName(Table));
                    }
                }
                break :b &sf;
            },
            .decls = &.{},
            .layout = .auto,
            .is_tuple = false,
        },
    });
}
