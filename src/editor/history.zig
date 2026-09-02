//! Editor-facing history models and pure display helpers.

const std = @import("std");

pub const Entry = struct {
    id: i64,
    /// Owned by the allocator passed to the provider callback or by the
    /// helper that constructed this entry; always release with `deinit`.
    text: []const u8,
    when: i64 = 0,

    // ziglint-ignore: Z012 Z023 method receiver must stay first; type is public as View.HistoryEntry
    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const QueryToken = struct {
    line_epoch: u64,
    generation: u64,
};

pub const View = struct {
    pub const HistoryEntry = Entry;

    /// Borrowed static history entries. They must remain valid for the lifetime
    /// of the line session and are copied into the edit buffer before use.
    entries: []const []const u8 = &.{},
    now: i64 = 0,
    context: ?*anyopaque = null,
    /// Provider callbacks return allocator-owned `HistoryEntry` values. The
    /// line session copies `entry.text` before calling `HistoryEntry.deinit`.
    previous: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, ?i64) anyerror!?HistoryEntry = null,
    next: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, i64) anyerror!?HistoryEntry = null,
    by_number: ?*const fn (*anyopaque, std.mem.Allocator, usize) anyerror!?HistoryEntry = null,
    search: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        []const u8,
        SearchFilters,
        ?i64,
    ) anyerror!?HistoryEntry = null,
    search_next: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        []const u8,
        SearchFilters,
        ?i64,
    ) anyerror!?HistoryEntry = null,
    suggest: ?*const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?HistoryEntry = null,
    async: ?Async = null,

    pub const Async = struct {
        context: *anyopaque,
        wake_fd: std.posix.fd_t,
        /// Borrows `request`; the provider must copy anything retained after
        /// this call returns.
        submit: *const fn (*anyopaque, Request) anyerror!void,
        cancel: *const fn (*anyopaque) void,
        drain_wake: *const fn (*anyopaque) void,
        /// Returns a deeply owned completion allocated by `allocator`.
        take_result: *const fn (*anyopaque, std.mem.Allocator) anyerror!?Completion,
    };
};

pub const SearchFilters = packed struct(u3) {
    cwd: bool = false,
    successful: bool = false,
    session: bool = false,
};

/// Deeply owned request payload, normally transferred through the outbox.
pub const Request = union(enum) {
    previous: struct { prefix: []const u8, before: ?i64 },
    next: struct { prefix: []const u8, after: i64 },
    by_number: usize,
    search: struct {
        query: []const u8,
        filters: SearchFilters,
        before: ?i64,
        token: QueryToken = .{ .line_epoch = 0, .generation = 0 },
    },
    search_next: struct {
        query: []const u8,
        filters: SearchFilters,
        after: ?i64,
        token: QueryToken = .{ .line_epoch = 0, .generation = 0 },
    },
    suggest: struct {
        prefix: []const u8,
        token: QueryToken = .{ .line_epoch = 0, .generation = 0 },
    },
    cancel_async: QueryToken,

    pub fn deinit(self: Request, allocator: std.mem.Allocator) void {
        switch (self) {
            .previous => |request| allocator.free(request.prefix),
            .next => |request| allocator.free(request.prefix),
            .search => |request| allocator.free(request.query),
            .search_next => |request| allocator.free(request.query),
            .suggest => |request| allocator.free(request.prefix),
            .by_number, .cancel_async => {},
        }
    }
};

/// Deeply owned callback result. Consumers either call `deinit` or explicitly
/// transfer contained entries into session-owned state.
pub const Result = union(enum) {
    entry: ?Entry,
    entries: []Entry,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        switch (self) {
            .entry => |maybe_entry| if (maybe_entry) |entry| entry.deinit(allocator),
            .entries => |entries| {
                for (entries) |entry| entry.deinit(allocator);
                allocator.free(entries);
            },
        }
    }
};

pub const Completion = struct {
    request: Request,
    result: Result,

    pub fn deinit(self: Completion, allocator: std.mem.Allocator) void {
        self.request.deinit(allocator);
        self.result.deinit(allocator);
    }
};

pub fn description(allocator: std.mem.Allocator, now: i64, when: i64) !?[]const u8 {
    if (now <= 0 or when <= 0) return null;
    var age_buffer: [16]u8 = undefined;
    const age = relativeAge(&age_buffer, now, when);
    return try allocator.dupe(u8, age);
}

pub fn relativeAge(buffer: *[16]u8, now: i64, when: i64) []const u8 {
    const elapsed = @max(now - when, 0);
    const value = if (elapsed < 60)
        elapsed
    else if (elapsed < 60 * 60)
        @divTrunc(elapsed, 60)
    else if (elapsed < 24 * 60 * 60)
        @divTrunc(elapsed, 60 * 60)
    else
        @divTrunc(elapsed, 24 * 60 * 60);
    const suffix: u8 = if (elapsed < 60)
        's'
    else if (elapsed < 60 * 60)
        'm'
    else if (elapsed < 24 * 60 * 60)
        'h'
    else
        'd';
    return std.fmt.bufPrint(buffer, "{d}{c}", .{ value, suffix }) catch unreachable;
}
