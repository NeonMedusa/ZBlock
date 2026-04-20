//main.zig:
pub fn main() !void {
    // 创建内存分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化游戏
    var game = try Game.init(allocator);
    defer game.deinit();
    try game.start();
}

const std = @import("std");
const Imports = @import("imports.zig");
const Game = Imports.Game;
const zigimg = @import("zigimg");
const Stb = @import("stb").c;

const Algebra = @import("algebra.zig");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
