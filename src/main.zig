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
const ECS = @import("ecs.zig");
const World = ECS.World;
const std = @import("std");
const Game = @import("game.zig");
const zigimg = @import("zigimg");
const Stb = @import("stb").c;

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
