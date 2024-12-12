/// Interface definitions.
/// The dialect is for writing a correct sql statement in a specfic architecture,
/// and the executor for interacting with the database client
pub const sqlite = @import("adaptors/sqlite.zig");

const utils = @import("zql").utils;
const Atom = utils.Atom;
const Assert = utils.StaticAssert;

pub const CursorStatus = enum {
    done,
    more,
};

pub const ExecutorI = Assert.comptimeInterface(struct {
    init: fn (ctx_ptr: *anyopaque, sql_stmt: []const u8) anyerror!void,
    deinit: fn (ctx_ptr: *anyopaque) void,
    step: fn (ctx_ptr: *anyopaque) anyerror!CursorStatus,
    bind: fn (ctx_ptr: *anyopaque, value: anytype, ix_1: usize) anyerror!void,
    column: fn (ctx_ptr: *anyopaque, comptime As: type, ix_0: usize, out_ptr: *anyopaque) anyerror!void,
});

pub const Dialect = struct {
    handle_tagged_type: *const fn (comptime TaggedType) DbType,
    visit_create_sql: *const fn (comptime []const u8) []const u8,
    bind_value_str: *const fn (comptime type) []const u8,

    pub const TaggedType = struct {
        Unwrapped: type,
        tags: []const []const u8 = &.{},

        pub fn From(comptime T: type, comptime tags: []Atom) TaggedType {
            var tag_names: [tags.len][]const u8 = undefined;
            inline for (tags, 0..) |tag, i| {
                tag_names[i] = @tagName(tag);
            }
            const tt = tags;
            return .{
                .Unwrapped = T,
                .tags = &tt,
            };
        }

        pub fn Unwrap(comptime self: TaggedType) type {
            self.Unwrapped;
        }
    };

    pub const DbType = struct {
        type_name: []const u8,
        create_str: []const u8,
    };
};
