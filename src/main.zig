//main.zig:
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
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
const Imports = @import("imports.zig");
const Game = Imports.Game;
