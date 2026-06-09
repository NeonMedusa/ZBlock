//main.zig:
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var game = try Game.init(allocator);
    defer game.deinit();
    try game.start();
}

const std = @import("std");
const Imports = @import("imports.zig");
const Game = Imports.Game;
