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

    // const file_path = try std.fs.path.join(allocator, &.{ "resources", "models", "Wolf.json" });
    // defer allocator.free(file_path);

    // var wolf_model_info: ModelInfo = undefined;
    // wolf_model_info.animations = try loadAnimConfig(allocator, file_path);

    // if (wolf_model_info.animations.get(.idle)) |idel_anim| {
    //     std.debug.print("{s}\n", .{idel_anim.clip_name.?});
    // }
}

const World = @import("world.zig").World;
const std = @import("std");
const Game = @import("game.zig");
const zigimg = @import("zigimg");
const Stb = @import("stb").c;

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
