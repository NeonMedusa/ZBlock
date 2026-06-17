// log.zig — 迷你日志系统
// 用法：Log.info("server started on port {}", .{PORT});
//       Log.err("failed to open file: {}", .{err});
// 日志文件: logs/<timestamp>.txt

const std = @import("std");

pub const Level = enum(u3) { debug, info, warn, err };

var file: ?std.fs.File = null;
var mutex: std.Thread.Mutex = .{};
var arena: std.heap.ArenaAllocator = undefined;

pub fn init(gpa: std.mem.Allocator) !void {
    std.fs.cwd().makeDir("logs") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const ts = std.time.timestamp();
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "logs/{d}.txt", .{ts}) catch "logs/game.txt";
    file = try std.fs.cwd().createFile(name, .{});
    arena = std.heap.ArenaAllocator.init(gpa);
}

pub fn deinit() void {
    if (file) |f| f.close();
    arena.deinit();
}

pub fn log(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    const label = comptime switch (level) {
        .debug => "DEBG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERRO",
    };
    const ns = std.time.nanoTimestamp();
    const sec = @divFloor(ns, 1_000_000_000);
    const ms = @divFloor(@mod(ns, 1_000_000_000), 1_000_000);
    const alloc = arena.allocator();
    const msg = std.fmt.allocPrint(alloc, "[{d}.{d:0>3}] [{s}] " ++ fmt ++ "\n", .{ sec, ms, label } ++ args) catch return;
    mutex.lock();
    defer mutex.unlock();
    if (file) |f| f.writeAll(msg) catch {};
    _ = std.debug.print("{s}", .{msg});
}

pub inline fn debug(comptime fmt: []const u8, args: anytype) void { log(.debug, fmt, args); }
pub inline fn info(comptime fmt: []const u8, args: anytype) void { log(.info, fmt, args); }
pub inline fn warn(comptime fmt: []const u8, args: anytype) void { log(.warn, fmt, args); }
pub inline fn err(comptime fmt: []const u8, args: anytype) void { log(.err, fmt, args); }
