// log.zig — 迷你日志系统（线程安全，stderr + 文件输出）
// 用法：Log.info(.network, "player joined", .{});
//       Log.setModule(.frame, false);  // 关掉每帧刷屏
// 日志文件: logs/<timestamp>.txt（不覆盖历史会话）

const std = @import("std");
const io = @import("imports.zig").io;

pub const Level = enum(u3) { debug, info, warn, err };

/// 日志模块标签。每条日志带一个模块名，运行时可按模块开关。
pub const Module = enum {
    startup, // 启动流程（startSave / initGame）
    network, // 网络事件（连接 / 断开 / 错误）
    frame, // 每帧渲染（Render.draw / pollServerSnapshot）
    model, // 模型加载
    latency, // 延迟统计
    game, // 通用游戏逻辑
};

var log_file: ?std.Io.File = null;
var log_mutex: std.Io.Mutex = .init;
var reentrant: bool = false; // 防止 Log 内调 Log 死锁

// 模块开关（默认全开）
var mod_enabled = @as(u64, ~@as(u64, 0));

pub fn setModule(mod: Module, on: bool) void {
    const bit = @as(u64, 1) << @intFromEnum(mod);
    if (on) mod_enabled |= bit else mod_enabled &= ~bit;
}

pub fn init(path: []const u8) void {
    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "logs") catch {};
    const full = if (path.len > 0) path else blk: {
        const ts = @divFloor(std.Io.Timestamp.now(io, .awake).nanoseconds, 1_000_000_000);
        var name_buf: [64]u8 = undefined;
        break :blk std.fmt.bufPrint(&name_buf, "logs/{d}.txt", .{ts}) catch "logs/game.txt";
    };
    log_file = dir.createFile(io, full, .{}) catch null;
}

pub fn deinit() void {
    if (log_file) |*f| f.close(io);
    log_file = null;
}

pub fn log(comptime mod: Module, comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    if ((mod_enabled >> @intFromEnum(mod)) & 1 == 0) return;
    const label = comptime switch (level) {
        .debug => "DEBG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERRO",
    };
    const mod_name = comptime @tagName(mod);
    const ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const sec = @divFloor(ns, 1_000_000_000);
    const ms = @divFloor(@mod(ns, 1_000_000_000), 1_000_000);
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[{d}.{d:0>3}] [{s}] [{s}] " ++ fmt ++ "\n", .{ sec, ms, label, mod_name } ++ args) catch return;
    if (!reentrant) {
        reentrant = true;
        log_mutex.lockUncancelable(io);
        if (log_file) |*f| {
            f.writeStreamingAll(io, buf[0..msg.len]) catch {};
        }
        log_mutex.unlock(io);
        reentrant = false;
    }
    std.debug.print("{s}", .{msg});
}

pub inline fn debug(comptime mod: Module, comptime fmt: []const u8, args: anytype) void {
    log(mod, .debug, fmt, args);
}
pub inline fn info(comptime mod: Module, comptime fmt: []const u8, args: anytype) void {
    log(mod, .info, fmt, args);
}
pub inline fn warn(comptime mod: Module, comptime fmt: []const u8, args: anytype) void {
    log(mod, .warn, fmt, args);
}
pub inline fn err(comptime mod: Module, comptime fmt: []const u8, args: anytype) void {
    log(mod, .err, fmt, args);
}
