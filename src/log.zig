// log.zig — 迷你日志系统（带时间戳，仅 stderr 输出）
const std = @import("std");

pub const Level = enum { debug, info, warn, err };

pub fn log(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    const label = comptime switch (level) {
        .debug => "DEBG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERRO",
    };
    const ns = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds;
    const sec = @divFloor(ns, 1_000_000_000);
    const ms = @divFloor(@mod(ns, 1_000_000_000), 1_000_000);
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[{d}.{d:0>3}] [{s}] " ++ fmt ++ "\n", .{ sec, ms, label } ++ args) catch return;
    std.debug.print("{s}", .{msg});
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}
