//main.zig:
const std = @import("std");
const Log = @import("log.zig");
const Game = @import("game.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    Log.info("ZBlock starting...", .{});
    var game = try Game.init(allocator);
    defer game.deinit();
    try game.start();
    Log.info("ZBlock exited normally", .{});
}
