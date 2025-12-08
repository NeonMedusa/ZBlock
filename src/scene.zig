//scene.zig:
ubo: SceneUniform,
allocator: std.mem.Allocator,
main_camera: Camera3D,
entities: std.ArrayList(Entity),
game_ptr: *Game,
// 可以添加 map 字段，等有地图系统时
pub fn init(allocator: std.mem.Allocator, game_ptr: *Game) @This() {
    var camera = Camera3D.init();
    camera.movement_speed = 5.0;
    var ubo = SceneUniform.init(game_ptr.window);
    ubo.view_matrix = camera.getViewMatrix();
    return .{
        .ubo = ubo,
        .allocator = allocator,
        .main_camera = camera,
        .entities = std.ArrayList(Entity){},
        .game_ptr = game_ptr,
    };
}
pub fn deinit(self: *@This()) void {
    self.entities.deinit(self.allocator);
}
pub fn addEntity(self: *@This(), entity: Entity) !void {
    try self.entities.append(self.allocator, entity);
}
pub fn update(self: *@This()) !void {
    // 获取帧间延迟
    self.ubo.time = self.game_ptr.window.time;
    // 更新摄像头
    self.main_camera.updateFromMouse(self.game_ptr);
    self.main_camera.updateFromKeyboard(self.game_ptr, self.game_ptr.window.delta_time);
    self.ubo.view_matrix = self.main_camera.getViewMatrix();
    // entity移动（测试用，需要更完善的实现和包装）
    self.entities.items[0].rotation = Vec3.new(1, @floatCast(self.game_ptr.window.time * 100), 1);
    // 动画更新（测试用，需要更完善的实现和包装）
    for (self.entities.items) |*entity|
        entity.cur_anime_time += self.game_ptr.window.delta_time * entity.anime_speed;
}

const std = @import("std");
const Wgpu = @import("cimports.zig").Wgpu;
const Glfw = @import("cimports.zig").Glfw;

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Game = @import("game.zig");

const ShaderTypes = @import("shader_types.zig");
const SceneUniform = ShaderTypes.SceneUniform;

const Camera3D = @import("camera3d.zig");
const Entity = @import("entity.zig");
