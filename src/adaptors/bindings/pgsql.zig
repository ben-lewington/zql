const std = @import("std");
pub const c = @cImport(@cInclude("libpq-fe.h"));

pub const log = std.log.scoped(.zql_pgsql_bindings);

const options = .{
    .verbosity = Verbosity.verbose,
    .context_visibility = ContextVisibility.errors,
};

pub const Conn = struct {
    inner: ?*c.PGconn,
    oids: std.StringHashMap(c.Oid),

    pub const Status = enum(c.ConnStatusType) {
        ok = c.CONNECTION_OK,
        bad = c.CONNECTION_BAD,
        started = c.CONNECTION_STARTED,
        made = c.CONNECTION_MADE,
        awaiting_response = c.CONNECTION_AWAITING_RESPONSE,
        auth_ok = c.CONNECTION_AUTH_OK,
        setenv = c.CONNECTION_SETENV,
        ssl_startup = c.CONNECTION_SSL_STARTUP,
        needed = c.CONNECTION_NEEDED,
        check_writable = c.CONNECTION_CHECK_WRITABLE,
        consume = c.CONNECTION_CONSUME,
        gss_startup = c.CONNECTION_GSS_STARTUP,
        check_target = c.CONNECTION_CHECK_TARGET,
        check_standby = c.CONNECTION_CHECK_STANDBY,
    };

    pub fn errorMessage(self: Conn) []const u8 {
        return std.mem.span(c.PQerrorMessage(self.inner));
    }

    pub fn status(self: Conn) Status {
        return c.PQstatus(self.inner);
    }

    pub fn getResult(self: Conn) ?Result {
        if (c.PQgetResult(self.inner)) |r| return .{ .inner = r };
        return null;
    }

    pub fn query(self: Conn, cmd_sql: []const u8) !Handle {
        const ret = c.PQsendQuery(self.inner, cmd_sql);

        if (ret == 0) {
            log.err("{s}", .{self.errorMessage()});
            return error.ExecQuery;
        }

        return .{ .conn = self.inner };
    }

    pub fn queryParams(self: Conn, cmd_sql: []const u8, params: ParamSlice, result_format: Param.Format) !Handle {
        const ret = c.PQsendQueryParams(
            self.inner,
            cmd_sql,
            @intCast(params.len),
            params.get(.value),
            params.get(.len),
            params.get(.format),
            @intFromEnum(result_format),
        );

        if (ret == 0) {
            log.err("{s}", .{self.errorMessage()});
            return error.ExecQueryParams;
        }

        return .{ .conn = self.inner };
    }

    pub fn prepareStatement(self: Conn, cmd_sql: []const u8, types: []const c.Oid) !PreparedStatement {
        var buf: [64]u8 = undefined;
        const stmt_name = std.fmt.bufPrint(&buf, "prepare_{}_{}", .{
            types.len,
            std.time.nanoTimestamp(),
        }) catch return error.StatementNameTooLong;

        const ret = c.PQsendPrepare(
            self.conn.inner,
            stmt_name,
            cmd_sql,
            types.len,
            types.ptr,
        );
        if (ret == 0) {
            log.err("{s}", .{self.errorMessage()});
            return error.ExecPrepared;
        }

        const res = self.getResult();
        switch (try res.status()) {
            .command => return .{
                .stmt_name = stmt_name,
                .conn = self,
            },
            .nonfatal, .tuple => {
                log.err("{s}", .{res.errorMessage(.{})});
                return error.ExpectedCommandOk;
            },
        }
    }

    pub fn init(alc: std.mem.Allocator, conn_str: [:0]const u8) !Conn {
        var conn: Conn = undefined;
        conn.oids = std.StringHashMap(c.Oid).init(alc);
        conn.inner = c.PQconnectdb(conn_str);

        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            log.err("{s}", .{conn.errorMessage()});
            return error.Init;
        }

        const handle = try conn.query("select typname, oid from pg_type;");

        while (handle.next()) |r| {
            defer r.deinit();

            const nrows = try r.asTuples();
            for (0..@intCast(nrows)) |i| {
                const typname = std.mem.span(c.PQgetvalue(r, @intCast(i), 0));
                const oid = try std.fmt.parseInt(
                    c.Oid,
                    std.mem.span(c.PQgetvalue(r, @intCast(i), 1)),
                    10,
                );

                try conn.oids.put(typname, oid);
            }
        }

        return conn;
    }

    pub fn deinit(self: Conn) void {
        self.oids.deinit();
        c.PQfinish(self.inner);
    }
};

const PreparedStatement = struct {
    conn: Conn,
    stmt_name: []const u8,

    pub fn exec(self: PreparedStatement, params: ParamSlice, result_format: Param.Format) !Handle {
        const ret = c.PQsendQueryPrepared(
            self.conn.inner,
            self.stmt_name,
            @intCast(params.len),
            params.get(.value),
            params.get(.len),
            params.get(.format),
            @intFromEnum(result_format),
        );
        if (ret == 0) {
            log.err("{s}", .{self.errorMessage()});
            return error.ExecPrepared;
        }
    }
};

pub const Handle = struct {
    conn: Conn,

    pub fn next(self: Handle) ?Result {
        return self.conn.getResult();
    }
};
// exec ->
//    query <params> -> resultHandle,
//    query prepare  -> PreparedStatement,

const Query = struct {
    conn: Conn,
    command_sql: []const u8,
    args: ?struct {
        params: ParamSlice,
        result_format: Param.Format = .text,
    } = null,

    fn init(self: Query) !Handle {
        const ret = b: {
            if (self.args) |a| {
                switch (a) {
                    .params => |p| break :b c.PQsendQueryParams(
                        self.conn.inner,
                        self.command_sql,
                        p.params.len,
                        p.params.get(.type),
                        p.params.get(.value),
                        p.params.get(.len),
                        p.params.get(.format),
                        @intFromEnum(p.result_format),
                    ),
                    .prepare => |p| {
                        var buf: [64]u8 = undefined;
                        const stmt_name = std.fmt.bufPrint(&buf, "prepare_{}_{}", .{
                            p.types.len,
                            std.time.nanoTimestamp(),
                        }) catch return error.StatementNameTooLong;

                        break :b .{
                            .code = c.PQsendPrepare(
                                self.conn.inner,
                                stmt_name,
                                self.command_sql,
                                p.types.len,
                                p.types.ptr,
                            ),
                            .stmt_name = stmt_name,
                        };
                    },
                }
            } else break :b .{
                .code = c.PQsendQuery(self.conn.inner, self.command_sql),
                .stmt_name = null,
            };
        };
        if (ret.code == 0) {
            log.err("{s}", .{c.PQerrorMessage(self.conn.inner)});
            return error.Send;
        }

        if (self.args) |a| {
            switch (a) {
                .prepare => |p| {
                    while (c.PQgetResult(self.conn.inner)) |result| {
                        defer c.PQclear(result);

                        const res = std.meta.intToEnum(Result.Status, c.PQresultStatus(result)) catch return error.UnknownResultCode;
                        switch (res) {
                            .command_ok => {},
                            else => @panic("expected .command_ok"),
                        }
                    }

                    return .{
                        .conn = self.conn,
                        .prepared = .{
                            .name = ret.stmt_name,
                            .types = p.types,
                        },
                    };
                },
                else => {},
            }
        }

        return .{ .conn = self.conn };
    }
};

const ParamSlice = std.MultiArrayList(Param).Slice;
const Param = struct {
    type: c.Oid,
    value: [*c]const u8,
    len: usize,
    format: Format = .text,

    pub const Format = enum(u1) {
        text = 0,
        binary = 1,
    };
};

pub const Result = struct {
    inner: *c.PGresult = undefined,

    pub fn deinit(self: Result) Result {
        c.PQclear(self.inner);
    }

    pub fn status(self: Result) !Status {
        const res = std.meta.stringToEnum(Status.Full, c.PQresultStatus(self.inner)) orelse
            return error.UnknownStatusCode;

        switch (res) {
            .command_ok => return .command,
            .tuples_ok => return .tuple,
            .copy_in, .copy_out, .copy_both => {
                log.warn("not implemented", .{self.errorMessage(.{})});
                @panic("not implemented");
            },
            .empty_query, .bad_response, .fatal_error => {
                log.err("{s}", .{self.errorMessage(.{})});
                return error.Query;
            },
            .nonfatal_error => {
                log.warn("{s}", .{self.errorMessage(.{})});
                return .nonfatal;
            },
        }
    }

    pub fn asTuples(self: Result) !usize {
        switch (try self.status()) {
            .tuple => return c.PQnfields(self.inner),
            else => return error.ExpectedTupleResult,
        }
    }

    pub fn errorMessage(self: Result, opts: struct {
        verbose: ?struct {
            verbosity: Verbosity = .verbose,
            context_visibility: ContextVisibility = .always,
        } = null,
    }) []const u8 {
        return std.mem.span(if (opts.verbose) |v|
            c.PQresultVerboseErrorMessage(self.inner, @intFromEnum(v.verbosity), @intFromEnum(v.context_visibility))
        else
            c.PQresultErrorMessage(self.inner));
    }

    pub const Status = enum(c.ExecStatusType) {
        command,
        tuple,
        nonfatal,

        pub const Full = enum(c.ExecStatusType) {
            command_ok = c.PGRES_COMMAND_OK,
            tuples_ok = c.PGRES_TUPLES_OK,

            copy_out = c.PGRES_COPY_OUT,
            copy_in = c.PGRES_COPY_IN,
            copy_both = c.PGRES_COPY_BOTH,

            empty_query = c.PGRES_EMPTY_QUERY,
            bad_response = c.PGRES_BAD_RESPONSE,
            nonfatal_error = c.PGRES_NONFATAL_ERROR,
            fatal_error = c.PGRES_FATAL_ERROR,
        };
    };
};

pub const DataType = union(enum) {
    bool,
    // integer types
    int2,
    int4,
    int8,
    // auto incrementing integer types, no oid, cannot be specified as a paramType
    serial2,
    serial4,
    serial8,
    // floating point
    float4,
    float8,
    // fixed precision decimal
    numeric: struct {
        precision: ?usize = null,
        scale: ?usize = null,
    },
    // currency amount in fixed fractional precision
    money,
    // fixed length bit string
    bit: usize,
    // variable length bit string
    varbit: usize,
    // byte array
    bytea,
    uuid,
    // fixed length character string
    char: usize,
    // variable length character string
    varchar: usize,
    text,
    json,
    jsonb,
    xml,
    // date and time types
    date,
    time: struct {
        precision: ?usize = null,
        time_zone: bool = false,
    },
    timestamp: struct {
        precision: ?usize = null,
        time_zone: bool = false,
    },
    interval: struct {
        precision: ?usize = null,
    },
    // geometric types
    point,
    line,
    lseg,
    path,
    circle,
    box,
    polygon,
    // text search types
    tsquery,
    tsvector,
    // Media Access Control address types
    macaddr,
    macaddr8,
    // IP address types
    cidr,
    inet,
    // postgres internal types
    pg_lsn,
    pg_snapshot,
    txid_snapshot,
    @"[]": struct {
        repr: []const u8,
        dimensions: []struct {
            bounded: ?usize = null,
        },
    },

    pub const Tag = b: {
        const dt = @typeInfo(DataType).Union;
        var fields: struct {
            data: [dt.fields.len - 1]std.builtin.Type.EnumField = undefined,
            len: usize = 0,
        } = .{};
        for (dt.fields, 0..) |f, i| {
            if (!std.mem.eql(u8, f.name, "[]")) {
                fields.data[i] = std.builtin.Type.EnumField{
                    .name = f.name,
                    .value = i,
                };
                fields.len += 1;
            }
        }
        const fs = fields;
        break :b @Type(std.builtin.Type{ .Enum = .{
            .fields = fs.data[0..fs.len],
            .decls = &.{},
            .tag_type = usize,
            .is_exhaustive = true,
        } });
    };
};

pub const Verbosity = enum(c_int) {
    terse = c.PQERRORS_TERSE,
    default = c.PQERRORS_DEFAULT,
    verbose = c.PQERRORS_VERBOSE,
    sqlstate = c.PQERRORS_SQLSTATE,
};

pub const ContextVisibility = enum(c_int) {
    never = c.PQSHOW_CONTEXT_NEVER,
    errors = c.PQSHOW_CONTEXT_ERRORS,
    always = c.PQSHOW_CONTEXT_ALWAYS,
};
