//main.zig:
pub fn main() !void {
const Game = @import("game.zig");
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化日志
    try Log.init(allocator);
    defer Log.deinit();

    Log.info("ZBlock starting...", .{});
    var game = try Game.init(allocator);
    defer game.deinit();
    try game.start();
    Log.info("ZBlock exited normally", .{});
}

const std = @import("std");
const Log = @import("log.zig");
