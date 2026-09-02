//! Executes latency-sensitive persistent-history reads away from the editor
//! thread. One latest-only mailbox and SQLite's progress handler bound stale
//! work while a nonblocking pipe wakes the terminal event loop.

const HistoryQueryWorker = @This();

const std = @import("std");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

const editor_history = @import("../editor/history.zig");
const signal = @import("../editor/signal.zig");

const log = std.log.scoped(.history_query_worker);
const page_size = 20;

allocator: std.mem.Allocator,
io: std.Io,
path: []const u8,
wake_pipe: signal.Pipe,
thread: ?std.Thread = null,
mutex: std.Io.Mutex = .init,
condition: std.Io.Condition = .init,
ready: bool = false,
startup_error: ?anyerror = null,
shutdown: bool = false,
shutdown_requested: std.atomic.Value(bool) = .init(false),
latest_sequence: std.atomic.Value(u64) = .init(0),
executing_sequence: std.atomic.Value(u64) = .init(0),
suggestion_statement_executions: std.atomic.Value(u64) = .init(0),
search_statement_executions: std.atomic.Value(u64) = .init(0),
queued: ?Request = null,
published: ?Completed = null,

const Direction = enum { previous, next };

pub const Stats = struct {
    suggestion_statement_executions: u64,
    search_statement_executions: u64,
};

const SearchRequest = struct {
    query: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    filters: editor_history.SearchFilters,
    direction: Direction,
    cursor: ?i64,
};

const Request = struct {
    sequence: u64 = 0,
    token: editor_history.QueryToken,
    payload: Payload,

    const Payload = union(enum) {
        suggest: struct {
            prefix: []const u8,
            cwd: []const u8,
        },
        search: SearchRequest,
    };

    fn deinit(self: Request, allocator: std.mem.Allocator) void {
        switch (self.payload) {
            .suggest => |suggest| {
                allocator.free(suggest.prefix);
                allocator.free(suggest.cwd);
            },
            .search => |search| {
                allocator.free(search.query);
                allocator.free(search.cwd);
                allocator.free(search.session_id);
            },
        }
    }
};

const Entry = struct {
    id: i64,
    text: []const u8,
    when: i64,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

const Result = union(enum) {
    suggestion: ?Entry,
    search_page: []Entry,

    fn deinit(self: Result, allocator: std.mem.Allocator) void {
        switch (self) {
            .suggestion => |maybe_entry| if (maybe_entry) |entry| entry.deinit(allocator),
            .search_page => |entries| {
                for (entries) |entry| entry.deinit(allocator);
                allocator.free(entries);
            },
        }
    }
};

const Completed = struct {
    request: Request,
    result: Result,

    fn deinit(self: Completed, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.result.deinit(allocator);
    }
};

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !*HistoryQueryWorker {
    std.debug.assert(path.len != 0);
    std.debug.assert(!std.mem.eql(u8, path, ":memory:"));

    const worker = try allocator.create(HistoryQueryWorker);
    errdefer allocator.destroy(worker);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    var wake_pipe = try signal.makePipe(io);
    errdefer wake_pipe.close(io);
    try signal.setNonBlocking(wake_pipe.read.handle);
    try signal.setNonBlocking(wake_pipe.write.handle);

    worker.* = .{
        .allocator = allocator,
        .io = io,
        .path = owned_path,
        .wake_pipe = wake_pipe,
    };
    worker.thread = try std.Thread.spawn(.{ .allocator = allocator }, threadMain, .{worker});

    worker.mutex.lockUncancelable(io);
    while (!worker.ready) worker.condition.waitUncancelable(io, &worker.mutex);
    const startup_error = worker.startup_error;
    worker.mutex.unlock(io);
    if (startup_error) |err| {
        worker.thread.?.join();
        return err;
    }
    return worker;
}

pub fn destroy(self: *HistoryQueryWorker) void {
    self.shutdown_requested.store(true, .release);
    _ = self.latest_sequence.fetchAdd(1, .acq_rel);
    self.mutex.lockUncancelable(self.io);
    self.shutdown = true;
    if (self.queued) |request| request.deinit(self.allocator);
    self.queued = null;
    if (self.published) |completed| completed.deinit(self.allocator);
    self.published = null;
    self.condition.signal(self.io);
    self.mutex.unlock(self.io);

    self.thread.?.join();
    self.thread = null;
    std.debug.assert(self.queued == null);
    std.debug.assert(self.published == null);
    self.wake_pipe.close(self.io);
    self.allocator.free(self.path);
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

pub fn wakeFd(self: HistoryQueryWorker) std.posix.fd_t {
    return self.wake_pipe.read.handle;
}

pub fn stats(self: *const HistoryQueryWorker) Stats {
    return .{
        .suggestion_statement_executions = self.suggestion_statement_executions.load(.acquire),
        .search_statement_executions = self.search_statement_executions.load(.acquire),
    };
}

pub fn submit(
    self: *HistoryQueryWorker,
    request: editor_history.Request,
    cwd: []const u8,
    session_id: []const u8,
) !void {
    var owned = try self.copyRequest(request, cwd, session_id);
    errdefer owned.deinit(self.allocator);
    const sequence = self.latest_sequence.fetchAdd(1, .acq_rel) +% 1;
    std.debug.assert(sequence != 0);
    owned.sequence = sequence;

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.shutdown) return error.HistoryQueryWorkerShutdown;
    if (self.queued) |queued| queued.deinit(self.allocator);
    if (self.published) |published| published.deinit(self.allocator);
    self.queued = owned;
    self.published = null;
    self.condition.signal(self.io);
}

pub fn cancel(self: *HistoryQueryWorker) void {
    _ = self.latest_sequence.fetchAdd(1, .acq_rel);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.queued) |queued| queued.deinit(self.allocator);
    if (self.published) |published| published.deinit(self.allocator);
    self.queued = null;
    self.published = null;
}

pub fn drainWake(self: *HistoryQueryWorker) void {
    var buffer: [64]u8 = undefined;
    while (true) {
        _ = signal.rawRead(self.wake_pipe.read.handle, &buffer) catch return;
    }
}

pub fn takeResult(
    self: *HistoryQueryWorker,
    allocator: std.mem.Allocator,
) !?editor_history.Completion {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const published = self.published orelse return null;
    const completion = try cloneCompletion(allocator, published);
    published.deinit(self.allocator);
    self.published = null;
    return completion;
}

fn copyRequest(
    self: *HistoryQueryWorker,
    request: editor_history.Request,
    cwd: []const u8,
    session_id: []const u8,
) !Request {
    return switch (request) {
        .suggest => |suggest| blk: {
            const prefix = try self.allocator.dupe(u8, suggest.prefix);
            errdefer self.allocator.free(prefix);
            break :blk .{
                .token = suggest.token,
                .payload = .{ .suggest = .{
                    .prefix = prefix,
                    .cwd = try self.allocator.dupe(u8, cwd),
                } },
            };
        },
        .search => |search| try self.copySearchRequest(
            search.token,
            search.query,
            cwd,
            session_id,
            search.filters,
            .previous,
            search.before,
        ),
        .search_next => |search| try self.copySearchRequest(
            search.token,
            search.query,
            cwd,
            session_id,
            search.filters,
            .next,
            search.after,
        ),
        else => unreachable,
    };
}

fn copySearchRequest(
    self: *HistoryQueryWorker,
    token: editor_history.QueryToken,
    query: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    filters: editor_history.SearchFilters,
    direction: Direction,
    cursor: ?i64,
) !Request {
    const owned_query = try self.allocator.dupe(u8, query);
    errdefer self.allocator.free(owned_query);
    const owned_cwd = try self.allocator.dupe(u8, cwd);
    errdefer self.allocator.free(owned_cwd);
    return .{
        .token = token,
        .payload = .{ .search = .{
            .query = owned_query,
            .cwd = owned_cwd,
            .session_id = try self.allocator.dupe(u8, session_id),
            .filters = filters,
            .direction = direction,
            .cursor = cursor,
        } },
    };
}

fn cloneCompletion(allocator: std.mem.Allocator, completed: Completed) !editor_history.Completion {
    const request: editor_history.Request = switch (completed.request.payload) {
        .suggest => |suggest| .{ .suggest = .{
            .prefix = try allocator.dupe(u8, suggest.prefix),
            .token = completed.request.token,
        } },
        .search => |search| if (search.direction == .previous)
            .{ .search = .{
                .query = try allocator.dupe(u8, search.query),
                .filters = search.filters,
                .before = search.cursor,
                .token = completed.request.token,
            } }
        else
            .{ .search_next = .{
                .query = try allocator.dupe(u8, search.query),
                .filters = search.filters,
                .after = search.cursor,
                .token = completed.request.token,
            } },
    };
    errdefer request.deinit(allocator);

    const result: editor_history.Result = switch (completed.result) {
        .suggestion => |maybe_entry| .{ .entry = if (maybe_entry) |entry| .{
            .id = entry.id,
            .text = try allocator.dupe(u8, entry.text),
            .when = entry.when,
        } else null },
        .search_page => |entries| blk: {
            const cloned = try allocator.alloc(editor_history.Entry, entries.len);
            errdefer allocator.free(cloned);
            var cloned_count: usize = 0;
            errdefer for (cloned[0..cloned_count]) |entry| entry.deinit(allocator);
            for (entries, cloned) |entry, *destination| {
                destination.* = .{
                    .id = entry.id,
                    .text = try allocator.dupe(u8, entry.text),
                    .when = entry.when,
                };
                cloned_count += 1;
            }
            break :blk .{ .entries = cloned };
        },
    };
    return .{ .request = request, .result = result };
}

fn threadMain(self: *HistoryQueryWorker) void {
    var cache = QueryCache.init(self) catch |err| {
        self.reportStartup(err);
        return;
    };
    defer cache.deinit();
    self.reportStartup(null);

    while (self.waitForRequest()) |request| {
        if (request.sequence != self.latest_sequence.load(.acquire)) {
            request.deinit(self.allocator);
            continue;
        }
        self.executing_sequence.store(request.sequence, .release);
        const query_result = cache.execute(request);
        self.executing_sequence.store(0, .release);
        const result = query_result catch |err| result: {
            if (err != error.SqliteInterrupted) log.debug("history query failed: {}", .{err});
            break :result emptyResult(self.allocator, request) catch {
                request.deinit(self.allocator);
                continue;
            };
        };
        self.publish(.{ .request = request, .result = result });
    }
}

fn reportStartup(self: *HistoryQueryWorker, startup_error: ?anyerror) void {
    self.mutex.lockUncancelable(self.io);
    self.startup_error = startup_error;
    self.ready = true;
    self.condition.signal(self.io);
    self.mutex.unlock(self.io);
}

fn waitForRequest(self: *HistoryQueryWorker) ?Request {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while (self.queued == null and !self.shutdown) {
        self.condition.waitUncancelable(self.io, &self.mutex);
    }
    if (self.shutdown) return null;
    const request = self.queued.?;
    self.queued = null;
    return request;
}

fn publish(self: *HistoryQueryWorker, completed: Completed) void {
    if (completed.request.sequence != self.latest_sequence.load(.acquire) or
        self.shutdown_requested.load(.acquire))
    {
        completed.deinit(self.allocator);
        return;
    }

    self.mutex.lockUncancelable(self.io);
    if (self.shutdown or completed.request.sequence != self.latest_sequence.load(.acquire)) {
        self.mutex.unlock(self.io);
        completed.deinit(self.allocator);
        return;
    }
    if (self.published) |published| published.deinit(self.allocator);
    self.published = completed;
    self.mutex.unlock(self.io);
    // ziglint-ignore: Z026 best-effort wakeup; the result remains in the mailbox
    signal.rawWriteAll(self.wake_pipe.write.handle, "h") catch {};
}

fn emptyResult(allocator: std.mem.Allocator, request: Request) !Result {
    return switch (request.payload) {
        .suggest => .{ .suggestion = null },
        .search => .{ .search_page = try allocator.alloc(Entry, 0) },
    };
}

const QueryCache = struct {
    worker: *HistoryQueryWorker,
    db: *sqlite.sqlite3,
    suggestion_exists: *sqlite.sqlite3_stmt,
    suggestion_local: *sqlite.sqlite3_stmt,
    suggestion_global: *sqlite.sqlite3_stmt,
    search_fts_previous: *sqlite.sqlite3_stmt,
    search_fts_next: *sqlite.sqlite3_stmt,
    search_substring_previous: *sqlite.sqlite3_stmt,
    search_substring_next: *sqlite.sqlite3_stmt,
    search_list_previous: *sqlite.sqlite3_stmt,
    search_list_next: *sqlite.sqlite3_stmt,
    pattern: std.ArrayList(u8) = .empty,

    fn init(worker: *HistoryQueryWorker) !QueryCache {
        const db = try openReadOnlyDb(worker.allocator, worker.path);
        errdefer _ = sqlite.sqlite3_close(db);
        sqlite.sqlite3_progress_handler(db, 1000, progressCallback, worker);

        var cache: QueryCache = .{
            .worker = worker,
            .db = db,
            .suggestion_exists = undefined,
            .suggestion_local = undefined,
            .suggestion_global = undefined,
            .search_fts_previous = undefined,
            .search_fts_next = undefined,
            .search_substring_previous = undefined,
            .search_substring_next = undefined,
            .search_list_previous = undefined,
            .search_list_next = undefined,
        };
        var prepared: usize = 0;
        errdefer cache.finalizeFirst(prepared);
        cache.suggestion_exists = try prepare(db, suggestion_exists_sql);
        prepared += 1;
        cache.suggestion_local = try prepare(db, suggestion_local_sql);
        prepared += 1;
        cache.suggestion_global = try prepare(db, suggestion_global_sql);
        prepared += 1;
        cache.search_fts_previous = try prepare(db, search_fts_previous_sql);
        prepared += 1;
        cache.search_fts_next = try prepare(db, search_fts_next_sql);
        prepared += 1;
        cache.search_substring_previous = try prepare(db, search_substring_previous_sql);
        prepared += 1;
        cache.search_substring_next = try prepare(db, search_substring_next_sql);
        prepared += 1;
        cache.search_list_previous = try prepare(db, search_list_previous_sql);
        prepared += 1;
        cache.search_list_next = try prepare(db, search_list_next_sql);
        return cache;
    }

    fn finalizeFirst(self: *QueryCache, count: usize) void {
        if (count >= 9) _ = sqlite.sqlite3_finalize(self.search_list_next);
        if (count >= 8) _ = sqlite.sqlite3_finalize(self.search_list_previous);
        if (count >= 7) _ = sqlite.sqlite3_finalize(self.search_substring_next);
        if (count >= 6) _ = sqlite.sqlite3_finalize(self.search_substring_previous);
        if (count >= 5) _ = sqlite.sqlite3_finalize(self.search_fts_next);
        if (count >= 4) _ = sqlite.sqlite3_finalize(self.search_fts_previous);
        if (count >= 3) _ = sqlite.sqlite3_finalize(self.suggestion_global);
        if (count >= 2) _ = sqlite.sqlite3_finalize(self.suggestion_local);
        if (count >= 1) _ = sqlite.sqlite3_finalize(self.suggestion_exists);
    }

    fn deinit(self: *QueryCache) void {
        self.pattern.deinit(self.worker.allocator);
        self.finalizeFirst(9);
        const rc = sqlite.sqlite3_close(self.db);
        std.debug.assert(rc == sqlite.SQLITE_OK);
        self.* = undefined;
    }

    fn execute(self: *QueryCache, request: Request) !Result {
        return switch (request.payload) {
            .suggest => |suggest| .{
                .suggestion = try self.executeSuggestion(request.sequence, suggest.prefix, suggest.cwd),
            },
            .search => |search| .{
                .search_page = try self.executeSearchPage(request.sequence, search),
            },
        };
    }

    fn executeSuggestion(
        self: *QueryCache,
        sequence: u64,
        prefix: []const u8,
        cwd: []const u8,
    ) !?Entry {
        if (prefix.len == 0) return null;
        self.pattern.clearRetainingCapacity();
        try appendSqlLikePrefix(self.worker.allocator, &self.pattern, prefix);

        try bindSuggestion(self.db, self.suggestion_exists, self.pattern.items, prefix.len, cwd);
        defer resetStatement(self.suggestion_exists);
        _ = self.worker.suggestion_statement_executions.fetchAdd(1, .monotonic);
        const exists_rc = sqlite.sqlite3_step(self.suggestion_exists);
        switch (exists_rc) {
            sqlite.SQLITE_ROW => {},
            sqlite.SQLITE_DONE => return null,
            sqlite.SQLITE_INTERRUPT => return error.SqliteInterrupted,
            else => try sqliteCheck(exists_rc, self.db),
        }
        if (sequence != self.worker.latest_sequence.load(.acquire)) return error.SqliteInterrupted;

        _ = self.worker.suggestion_statement_executions.fetchAdd(1, .monotonic);
        if (try stepSuggestion(
            self.worker.allocator,
            self.db,
            self.suggestion_local,
            self.pattern.items,
            prefix.len,
            cwd,
        )) |entry| {
            return entry;
        }
        if (sequence != self.worker.latest_sequence.load(.acquire)) return error.SqliteInterrupted;
        _ = self.worker.suggestion_statement_executions.fetchAdd(1, .monotonic);
        if (try stepSuggestion(
            self.worker.allocator,
            self.db,
            self.suggestion_global,
            self.pattern.items,
            prefix.len,
            cwd,
        )) |entry| {
            return entry;
        }
        return null;
    }

    fn executeSearchPage(
        self: *QueryCache,
        sequence: u64,
        search: SearchRequest,
    ) ![]Entry {
        const offset = if (search.cursor) |cursor| @max(cursor, 0) else 0;
        var entries = try self.executeSearchAtOffset(sequence, search, offset);
        if (entries.len == 0 and search.cursor != null) {
            self.worker.allocator.free(entries);
            entries = try self.executeSearchAtOffset(sequence, search, 0);
        }
        return entries;
    }

    fn executeSearchAtOffset(
        self: *QueryCache,
        sequence: u64,
        search: SearchRequest,
        offset: i64,
    ) ![]Entry {
        self.pattern.clearRetainingCapacity();
        const statement = if (historySearchNeedsSubstring(search.query)) blk: {
            try appendSqlLikeSubstring(self.worker.allocator, &self.pattern, search.query);
            break :blk switch (search.direction) {
                .previous => self.search_substring_previous,
                .next => self.search_substring_next,
            };
        } else blk: {
            try appendHistoryFtsQuery(self.worker.allocator, &self.pattern, search.query);
            if (self.pattern.items.len == 0) {
                break :blk switch (search.direction) {
                    .previous => self.search_list_previous,
                    .next => self.search_list_next,
                };
            }
            break :blk switch (search.direction) {
                .previous => self.search_fts_previous,
                .next => self.search_fts_next,
            };
        };
        resetStatement(statement);
        defer resetStatement(statement);
        if (statement == self.search_list_previous or statement == self.search_list_next) {
            try bindListSearch(self.db, statement, search, offset);
        } else {
            try bindTextSearch(self.db, statement, self.pattern.items, search, offset);
        }
        _ = self.worker.search_statement_executions.fetchAdd(1, .monotonic);

        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |entry| entry.deinit(self.worker.allocator);
            entries.deinit(self.worker.allocator);
        }
        while (entries.items.len < page_size) {
            const rc = sqlite.sqlite3_step(statement);
            if (rc == sqlite.SQLITE_DONE) break;
            if (rc == sqlite.SQLITE_INTERRUPT) return error.SqliteInterrupted;
            if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, self.db);
            const text = sqlite.sqlite3_column_text(statement, 1) orelse continue;
            try entries.ensureUnusedCapacity(self.worker.allocator, 1);
            entries.appendAssumeCapacity(.{
                .id = offset + @as(i64, @intCast(entries.items.len)) + 1,
                .text = try self.worker.allocator.dupe(u8, std.mem.span(text)),
                .when = sqlite.sqlite3_column_int64(statement, 2),
            });
            if (sequence != self.worker.latest_sequence.load(.acquire)) return error.SqliteInterrupted;
        }
        return entries.toOwnedSlice(self.worker.allocator);
    }
};

fn openReadOnlyDb(allocator: std.mem.Allocator, path: []const u8) !*sqlite.sqlite3 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var db: ?*sqlite.sqlite3 = null;
    const open_rc = sqlite.sqlite3_open_v2(
        path_z.ptr,
        &db,
        sqlite.SQLITE_OPEN_READONLY | sqlite.SQLITE_OPEN_NOMUTEX,
        null,
    );
    errdefer if (db) |handle| {
        _ = sqlite.sqlite3_close(handle);
    };
    try sqliteCheck(open_rc, db);
    const handle = db.?;
    try sqliteExec(handle,
        \\pragma query_only = on;
        \\pragma busy_timeout = 100;
        \\pragma foreign_keys = on;
        \\pragma temp_store = memory;
    );
    return handle;
}

fn progressCallback(context: ?*anyopaque) callconv(.c) c_int {
    const worker: *HistoryQueryWorker = @ptrCast(@alignCast(context.?));
    if (worker.shutdown_requested.load(.acquire)) return 1;
    const executing = worker.executing_sequence.load(.acquire);
    if (executing != 0 and executing != worker.latest_sequence.load(.acquire)) return 1;
    return 0;
}

fn prepare(db: *sqlite.sqlite3, sql: [*:0]const u8) !*sqlite.sqlite3_stmt {
    var statement: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, sql, -1, &statement, null), db);
    return statement.?;
}

fn resetStatement(statement: *sqlite.sqlite3_stmt) void {
    _ = sqlite.sqlite3_reset(statement);
    _ = sqlite.sqlite3_clear_bindings(statement);
}

fn bindSuggestion(
    db: *sqlite.sqlite3,
    statement: *sqlite.sqlite3_stmt,
    pattern: []const u8,
    prefix_len: usize,
    cwd: []const u8,
) !void {
    resetStatement(statement);
    try sqliteCheck(sqlite.sqlite3_bind_text(statement, 1, pattern.ptr, @intCast(pattern.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int64(statement, 2, @intCast(prefix_len)), db);
    if (sqlite.sqlite3_bind_parameter_count(statement) >= 3) {
        try sqliteCheck(sqlite.sqlite3_bind_text(statement, 3, cwd.ptr, @intCast(cwd.len), null), db);
    }
}

fn stepSuggestion(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    statement: *sqlite.sqlite3_stmt,
    pattern: []const u8,
    prefix_len: usize,
    cwd: []const u8,
) !?Entry {
    try bindSuggestion(db, statement, pattern, prefix_len, cwd);
    defer resetStatement(statement);
    const rc = sqlite.sqlite3_step(statement);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc == sqlite.SQLITE_INTERRUPT) return error.SqliteInterrupted;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const text = sqlite.sqlite3_column_text(statement, 1) orelse return null;
    return .{
        .id = sqlite.sqlite3_column_int64(statement, 0),
        .text = try allocator.dupe(u8, std.mem.span(text)),
        .when = sqlite.sqlite3_column_int64(statement, 2),
    };
}

fn bindTextSearch(
    db: *sqlite.sqlite3,
    statement: *sqlite.sqlite3_stmt,
    pattern: []const u8,
    search: SearchRequest,
    offset: i64,
) !void {
    try sqliteCheck(sqlite.sqlite3_bind_text(statement, 1, pattern.ptr, @intCast(pattern.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(statement, 2, search.cwd.ptr, @intCast(search.cwd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int64(statement, 3, offset), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(statement, 4, @intFromBool(search.filters.cwd)), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(statement, 5, @intFromBool(search.filters.successful)), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(statement, 6, @intFromBool(search.filters.session)), db);
    try sqliteCheck(
        sqlite.sqlite3_bind_text(statement, 7, search.session_id.ptr, @intCast(search.session_id.len), null),
        db,
    );
    try sqliteCheck(sqlite.sqlite3_bind_int(statement, 8, page_size), db);
}

fn bindListSearch(
    db: *sqlite.sqlite3,
    statement: *sqlite.sqlite3_stmt,
    search: SearchRequest,
    offset: i64,
) !void {
    try sqliteCheck(sqlite.sqlite3_bind_int(statement, 1, @intFromBool(search.filters.cwd)), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(statement, 2, search.cwd.ptr, @intCast(search.cwd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(statement, 3, @intFromBool(search.filters.successful)), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(statement, 4, @intFromBool(search.filters.session)), db);
    try sqliteCheck(
        sqlite.sqlite3_bind_text(statement, 5, search.session_id.ptr, @intCast(search.session_id.len), null),
        db,
    );
    try sqliteCheck(sqlite.sqlite3_bind_int64(statement, 6, offset), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(statement, 7, page_size), db);
}

fn appendSqlLikePrefix(allocator: std.mem.Allocator, pattern: *std.ArrayList(u8), prefix: []const u8) !void {
    for (prefix) |byte| switch (byte) {
        '%', '_', '\\' => {
            try pattern.append(allocator, '\\');
            try pattern.append(allocator, byte);
        },
        else => try pattern.append(allocator, byte),
    };
    try pattern.append(allocator, '%');
}

fn appendSqlLikeSubstring(allocator: std.mem.Allocator, pattern: *std.ArrayList(u8), query: []const u8) !void {
    try pattern.append(allocator, '%');
    try appendSqlLikePrefix(allocator, pattern, query);
}

fn historySearchNeedsSubstring(query: []const u8) bool {
    for (query) |byte| {
        if (!historyFtsTokenByte(byte) and byte != ' ' and byte != '\t') return true;
    }
    return false;
}

fn appendHistoryFtsQuery(allocator: std.mem.Allocator, output: *std.ArrayList(u8), query: []const u8) !void {
    var token_start: ?usize = null;
    for (query, 0..) |byte, index| {
        if (historyFtsTokenByte(byte)) {
            if (token_start == null) token_start = index;
        } else if (token_start) |start| {
            try appendHistoryFtsQueryToken(allocator, output, query[start..index]);
            token_start = null;
        }
    }
    if (token_start) |start| try appendHistoryFtsQueryToken(allocator, output, query[start..]);
}

fn historyFtsTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn appendHistoryFtsQueryToken(allocator: std.mem.Allocator, output: *std.ArrayList(u8), token: []const u8) !void {
    if (token.len == 0) return;
    if (output.items.len != 0) try output.append(allocator, ' ');
    try output.append(allocator, '"');
    try output.appendSlice(allocator, token);
    try output.appendSlice(allocator, "\"*");
}

fn sqliteExec(db: *sqlite.sqlite3, sql: [*:0]const u8) !void {
    var error_message: [*c]u8 = null;
    const rc = sqlite.sqlite3_exec(db, sql, null, null, &error_message);
    defer if (error_message != null) sqlite.sqlite3_free(error_message);
    try sqliteCheck(rc, db);
}

fn sqliteCheck(code: c_int, db: ?*sqlite.sqlite3) !void {
    if (code == sqlite.SQLITE_OK or code == sqlite.SQLITE_ROW or code == sqlite.SQLITE_DONE) return;
    if (code == sqlite.SQLITE_INTERRUPT) return error.SqliteInterrupted;
    if (db) |handle| log.debug("sqlite error {d}: {s}", .{ code, sqlite.sqlite3_errmsg(handle) });
    return error.SqliteFailure;
}

const suggestion_exists_sql =
    \\select 1
    \\from history indexed by history_command_nocase_id_idx
    \\where command like ?1 escape '\'
    \\  and length(cast(command as blob)) > ?2
    \\limit 1
;

const suggestion_local_sql =
    \\select h.id, h.command, h.started_at
    \\from history h indexed by history_cwd_id_idx
    \\where h.cwd = ?3
    \\  and h.command like ?1 escape '\'
    \\  and length(cast(h.command as blob)) > ?2
    \\  and not exists (
    \\    select 1
    \\    from history newer indexed by history_command_key_cwd_id_idx
    \\    where newer.command_key = h.command_key
    \\      and newer.cwd = ?3
    \\      and newer.id > h.id
    \\  )
    \\order by h.id desc
    \\limit 1
;

const suggestion_global_sql =
    \\select h.id, h.command, h.started_at
    \\from history h not indexed
    \\where h.cwd <> ?3
    \\  and h.command like ?1 escape '\'
    \\  and length(cast(h.command as blob)) > ?2
    \\  and not exists (
    \\    select 1
    \\    from history newer indexed by history_command_key_id_idx
    \\    where newer.command_key = h.command_key
    \\      and (newer.cwd = ?3 or (newer.cwd <> ?3 and newer.id > h.id))
    \\  )
    \\order by h.id desc
    \\limit 1
;

const search_fts_previous_sql = searchFtsSql(.previous);
const search_fts_next_sql = searchFtsSql(.next);
const search_substring_previous_sql = searchSubstringSql(.previous);
const search_substring_next_sql = searchSubstringSql(.next);
const search_list_previous_sql = searchListSql(.previous);
const search_list_next_sql = searchListSql(.next);

fn searchFtsSql(comptime direction: Direction) [*:0]const u8 {
    return (if (direction == .previous)
        \\select h.id, h.command, h.started_at
        \\from history_fts f
        \\join history h on h.id = f.rowid
        \\where history_fts match ?1
        \\  and (?4 = 0 or h.cwd = ?2)
        \\  and (?5 = 0 or h.status = 0)
        \\  and (?6 = 0 or h.session_id = ?7)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?5 = 0 or newer.status = 0)
        \\      and (?6 = 0 or newer.session_id = ?7)
        \\      and ((?4 <> 0 and newer.cwd = ?2 and newer.id > h.id) or
        \\        (?4 = 0 and ((newer.cwd = ?2 and h.cwd <> ?2) or
        \\          ((newer.cwd = ?2) = (h.cwd = ?2) and newer.id > h.id))))
        \\  )
        \\order by (h.cwd = ?2) desc, h.id desc
        \\limit ?8 offset ?3
    else
        \\select h.id, h.command, h.started_at
        \\from history_fts f
        \\join history h on h.id = f.rowid
        \\where history_fts match ?1
        \\  and (?4 = 0 or h.cwd = ?2)
        \\  and (?5 = 0 or h.status = 0)
        \\  and (?6 = 0 or h.session_id = ?7)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?5 = 0 or newer.status = 0)
        \\      and (?6 = 0 or newer.session_id = ?7)
        \\      and ((?4 <> 0 and newer.cwd = ?2 and newer.id > h.id) or
        \\        (?4 = 0 and ((newer.cwd = ?2 and h.cwd <> ?2) or
        \\          ((newer.cwd = ?2) = (h.cwd = ?2) and newer.id > h.id))))
        \\  )
        \\order by (h.cwd = ?2) asc, h.id asc
        \\limit ?8 offset ?3
    );
}

fn searchSubstringSql(comptime direction: Direction) [*:0]const u8 {
    return (if (direction == .previous)
        \\select h.id, h.command, h.started_at
        \\from history h
        \\where h.command like ?1 escape '\'
        \\  and (?4 = 0 or h.cwd = ?2)
        \\  and (?5 = 0 or h.status = 0)
        \\  and (?6 = 0 or h.session_id = ?7)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?5 = 0 or newer.status = 0)
        \\      and (?6 = 0 or newer.session_id = ?7)
        \\      and ((?4 <> 0 and newer.cwd = ?2 and newer.id > h.id) or
        \\        (?4 = 0 and ((newer.cwd = ?2 and h.cwd <> ?2) or
        \\          ((newer.cwd = ?2) = (h.cwd = ?2) and newer.id > h.id))))
        \\  )
        \\order by (h.cwd = ?2) desc, h.id desc
        \\limit ?8 offset ?3
    else
        \\select h.id, h.command, h.started_at
        \\from history h
        \\where h.command like ?1 escape '\'
        \\  and (?4 = 0 or h.cwd = ?2)
        \\  and (?5 = 0 or h.status = 0)
        \\  and (?6 = 0 or h.session_id = ?7)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?5 = 0 or newer.status = 0)
        \\      and (?6 = 0 or newer.session_id = ?7)
        \\      and ((?4 <> 0 and newer.cwd = ?2 and newer.id > h.id) or
        \\        (?4 = 0 and ((newer.cwd = ?2 and h.cwd <> ?2) or
        \\          ((newer.cwd = ?2) = (h.cwd = ?2) and newer.id > h.id))))
        \\  )
        \\order by (h.cwd = ?2) asc, h.id asc
        \\limit ?8 offset ?3
    );
}

fn searchListSql(comptime direction: Direction) [*:0]const u8 {
    return (if (direction == .previous)
        \\select h.id, h.command, h.started_at
        \\from history h
        \\where (?1 = 0 or h.cwd = ?2)
        \\  and (?3 = 0 or h.status = 0)
        \\  and (?4 = 0 or h.session_id = ?5)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?1 = 0 or newer.cwd = ?2)
        \\      and (?3 = 0 or newer.status = 0)
        \\      and (?4 = 0 or newer.session_id = ?5)
        \\      and newer.id > h.id
        \\  )
        \\order by (h.cwd = ?2) desc, h.id desc
        \\limit ?7 offset ?6
    else
        \\select h.id, h.command, h.started_at
        \\from history h
        \\where (?1 = 0 or h.cwd = ?2)
        \\  and (?3 = 0 or h.status = 0)
        \\  and (?4 = 0 or h.session_id = ?5)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command_key = h.command_key
        \\      and (?1 = 0 or newer.cwd = ?2)
        \\      and (?3 = 0 or newer.status = 0)
        \\      and (?4 = 0 or newer.session_id = ?5)
        \\      and newer.id > h.id
        \\  )
        \\order by (h.cwd = ?2) asc, h.id asc
        \\limit ?7 offset ?6
    );
}

test "split autosuggestion statements preserve recency plans without temporary sorting" {
    var db: ?*sqlite.sqlite3 = null;
    try sqliteCheck(sqlite.sqlite3_open_v2(
        ":memory:",
        &db,
        sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_NOMUTEX,
        null,
    ), db);
    defer _ = sqlite.sqlite3_close(db.?);
    try sqliteExec(db.?,
        \\create table history (
        \\  id integer primary key,
        \\  command text not null,
        \\  command_key text not null,
        \\  cwd text not null,
        \\  started_at integer not null
        \\);
        \\create index history_command_nocase_id_idx on history(command collate nocase, id);
        \\create index history_command_key_id_idx on history(command_key, id);
        \\create index history_command_key_cwd_id_idx on history(command_key, cwd, id);
        \\create index history_cwd_id_idx on history(cwd, id);
    );

    try expectQueryPlanContains(db.?, suggestion_local_sql, "history_command_key_cwd_id_idx");
    try expectQueryPlanContains(db.?, suggestion_global_sql, "history_command_key_id_idx");
}

fn expectQueryPlanContains(db: *sqlite.sqlite3, sql: [*:0]const u8, expected_index: []const u8) !void {
    const explain_sql = try std.fmt.allocPrintSentinel(std.testing.allocator, "explain query plan {s}", .{sql}, 0);
    defer std.testing.allocator.free(explain_sql);
    var statement: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, explain_sql.ptr, -1, &statement, null), db);
    defer _ = sqlite.sqlite3_finalize(statement);

    var found_index = false;
    while (true) {
        const rc = sqlite.sqlite3_step(statement);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
        const detail_text = sqlite.sqlite3_column_text(statement, 3) orelse continue;
        const detail = std.mem.span(detail_text);
        try std.testing.expect(std.mem.indexOf(u8, detail, "USE TEMP B-TREE") == null);
        if (std.mem.indexOf(u8, detail, expected_index) != null) found_index = true;
    }
    try std.testing.expect(found_index);
}
