//! Freestanding WebAssembly entry for embedders.
//!
//! Build with `zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`.
//! The artifact is `zig-out/bin/rush.wasm`: an executable with no start
//! function. Instantiate it with no imports; `memory` and the `rush_*`
//! exports are enough.
//!
//! The module evaluates the shell language and builtins in-process. External
//! commands return 127. Pipes, subshells, and job control fail with status 2
//! and `rush: shell error` on stderr.
//!
//! Each `rush_create` instance is a persistent shell. `rush_eval` runs one
//! REPL command: EXIT traps fire on `exit` / fatal flow, then once more from
//! `rush_destroy` if they have not already run. Eval after `exit` returns the
//! finished status and does not run more script.
//!
//! C ABI (`callconv(.c)`):
//! - `rush_create` may return null on allocation failure.
//! - `rush_eval(instance, ptr, len)` reads UTF-8 bytes that must stay valid
//!   for the call.
//! - `rush_stdout_*` / `rush_stderr_*` point into instance memory and are
//!   invalidated by the next eval or by destroy.
//! - `rush_wasm_alloc_u8_array` / `rush_wasm_free_u8_array` must be paired
//!   with the same length.
//! - EXIT-trap output from `rush_destroy` is discarded with the instance; eval
//!   `exit` first if the embedder needs to read it.

const std = @import("std");
const builtin = @import("builtin");

const build_config = @import("build_config");
const host = @import("host.zig");

const WasmSession = host.WasmSession;

const allocator = if (builtin.target.cpu.arch.isWasm())
    std.heap.wasm_allocator
else
    std.heap.smp_allocator;

pub const std_options: std.Options = options: {
    var options: std.Options = .{};
    if (builtin.target.cpu.arch.isWasm()) {
        options.log_level = .err;
        options.logFn = wasmLogNoop;
    }
    break :options options;
};

fn wasmLogNoop(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

fn version() callconv(.c) [*:0]const u8 {
    return (build_config.version ++ "\x00")[0..build_config.version.len :0];
}

fn create() callconv(.c) ?*WasmSession {
    const instance = allocator.create(WasmSession) catch return null;
    instance.* = WasmSession.init(allocator) catch {
        allocator.destroy(instance);
        return null;
    };
    return instance;
}

fn destroy(instance: *WasmSession) callconv(.c) void {
    _ = instance.finish();
    instance.deinit();
    allocator.destroy(instance);
}

fn eval(instance: *WasmSession, ptr: [*]const u8, len: usize) callconv(.c) u8 {
    return instance.evalScript(ptr[0..len]);
}

fn stdoutPtr(instance: *WasmSession) callconv(.c) [*]const u8 {
    return instance.shell.host.stdoutPtr();
}

fn stdoutLen(instance: *WasmSession) callconv(.c) usize {
    return instance.shell.host.stdoutSlice().len;
}

fn stderrPtr(instance: *WasmSession) callconv(.c) [*]const u8 {
    return instance.shell.host.stderrPtr();
}

fn stderrLen(instance: *WasmSession) callconv(.c) usize {
    return instance.shell.host.stderrSlice().len;
}

fn allocU8Array(len: usize) callconv(.c) ?[*]u8 {
    const bytes = allocator.alloc(u8, len) catch return null;
    return bytes.ptr;
}

fn freeU8Array(ptr: [*]u8, len: usize) callconv(.c) void {
    allocator.free(ptr[0..len]);
}

comptime {
    @export(&version, .{ .name = "rush_version" });
    @export(&create, .{ .name = "rush_create" });
    @export(&destroy, .{ .name = "rush_destroy" });
    @export(&eval, .{ .name = "rush_eval" });
    @export(&stdoutPtr, .{ .name = "rush_stdout_ptr" });
    @export(&stdoutLen, .{ .name = "rush_stdout_len" });
    @export(&stderrPtr, .{ .name = "rush_stderr_ptr" });
    @export(&stderrLen, .{ .name = "rush_stderr_len" });
    @export(&allocU8Array, .{ .name = "rush_wasm_alloc_u8_array" });
    @export(&freeU8Array, .{ .name = "rush_wasm_free_u8_array" });
}
