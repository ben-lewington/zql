const std = @import("std");

const sqlite_dep: CDep.Zig = .{
    .name = "sqlite",
    .dep = .{ .source_code = .{
        .include = .{ .cwd_relative = "lib/include/sqlite" },
        .c_files = &.{"sqlite3.c"},
    } },
    .bindgen_path = "src/adaptors/bindings/sqlite.zig",
};

const CDep = union(enum) {
    pre_compiled: struct {
        path: std.Build.LazyPath,
        name: []const u8,
    },
    source_code: struct {
        include: std.Build.LazyPath,
        src: ?std.Build.LazyPath = null,
        c_files: []const []const u8,
    },

    fn addTo(self: @This(), obj: *std.Build.Step.Compile) void {
        switch (self) {
            .pre_compiled => |d| {
                obj.linkLibC();
                obj.addIncludePath(d.path);
                obj.addLibraryPath(d.path);
                obj.linkSystemLibrary(d.name);
            },
            .source_code => |d| {
                obj.linkLibC();
                obj.addIncludePath(d.include);
                obj.addCSourceFiles(.{
                    .root = d.src orelse d.include,
                    .files = d.c_files,
                    .flags = &.{},
                });
            },
        }
    }

    const Zig = struct {
        name: []const u8,
        bindgen_path: ?[]const u8 = null,
        dep: CDep,
    };

    const Resolved = struct {
        obj: CDep,
        lib: ?*std.Build.Step.Compile = null,

        pub fn addImport(self: *const Resolved, name: []const u8, mod: *std.Build.Module) void {
            const lib = self.lib orelse return;
            mod.addImport(name, &lib.root_module);
        }
    };
};

pub fn makeZql(b: *std.Build, opts: anytype) *std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "zql",
        .root_source_file = b.path("src/zql.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    const arches = SqlArch.makeOptions(b);
    if (arches.values.get(.sqlite)) {
        const sqlite_lib = b.addSharedLibrary(.{
            .name = sqlite_dep.name,
            .root_source_file = b.path(sqlite_dep.bindgen_path.?),
            .target = opts.target,
            .optimize = opts.optimize,
        });

        sqlite_dep.dep.addTo(sqlite_lib);
        lib.root_module.addImport(sqlite_dep.name, &sqlite_lib.root_module);
    }
    if (arches.values.get(.pqsql)) {
        const postgres = b.dependency("libpq", .{
            .target = opts.target,
            .optimize = opts.optimize,
        });
        const libpq = postgres.artifact("pq");
        //
        // // wherever needed:
        lib.linkLibrary(libpq);
    }

    lib.root_module.addImport("zql", &lib.root_module);
    lib.root_module.addOptions("config", arches.opts);

    return lib;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zql = makeZql(b, .{ .target = target, .optimize = optimize });

    const int_tests = try b.build_root.handle.openDir("tests", .{ .iterate = true });
    var bins = int_tests.iterate();
    while (try bins.next()) |f| {
        switch (f.kind) {
            .file => {
                const exe = b.addExecutable(.{
                    .name = try std.fmt.allocPrint(b.allocator, "integration_test_{s}", .{
                        f.name[0 .. std.mem.indexOf(u8, f.name, ".zig") orelse unreachable],
                    }),
                    .root_source_file = b.path(b.pathJoin(&.{ "tests", f.name })),
                    .target = target,
                    .optimize = optimize,
                });

                exe.root_module.addImport("zql", &zql.root_module);

                b.installArtifact(exe);
            },
            else => |k| std.debug.panic("file type {s} not implemented", .{@tagName(k)}),
        }
    }
}

const SqlArch = enum {
    sqlite,
    pqsql,

    const sqlarch = @typeInfo(SqlArch).Enum;

    const Arches = struct {
        values: [sqlarch.fields.len]bool,

        pub fn get(self: Arches, v: SqlArch) bool {
            return self.values[@intFromEnum(v)];
        }
    };

    pub fn makeOptions(b: *std.Build) struct { values: Arches, opts: *std.Build.Step.Options } {
        const opts = b.addOptions();
        var vals: [sqlarch.fields.len]bool = undefined;
        inline for (sqlarch.fields, 0..) |f, i| {
            const opt = b.option(bool, f.name, "include adaptor for " ++ f.name) orelse false;
            opts.addOption(bool, "include_" ++ f.name, opt);
            vals[i] = opt;
        }
        return .{
            .values = .{
                .values = vals,
            },
            .opts = opts,
        };
    }
};
