//scene.zig:
ubo: SceneUniform,
allocator: std.mem.Allocator,
main_camera: Camera3D,
entities: std.ArrayList(Entity),
window: *Window,
last_frame_time: f64 = 0,
current_frame_time: f64 = 0,
delta_time_f64: f64 = 0,
delta_time_f32: f32 = 0,
// 可以添加 map 字段，等你有地图系统时
pub fn init(allocator: std.mem.Allocator, window: *Window) @This() {
    var camera = Camera3D.init();
    camera.movement_speed = 5.0;
    var ubo = SceneUniform.init(window.*);
    ubo.view_matrix = camera.getViewMatrix();
    return .{
        .ubo = ubo,
        .allocator = allocator,
        .main_camera = camera,
        .entities = std.ArrayList(Entity){},
        .window = window,
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
    self.current_frame_time = glfw.glfwGetTime();
    self.delta_time_f64 = self.current_frame_time - self.last_frame_time;
    self.delta_time_f32 = @floatCast(self.delta_time_f64);
    self.last_frame_time = self.current_frame_time;
    self.ubo.time = @floatCast(self.current_frame_time);
    // 更新实例数量
    self.ubo.active_entity_count = @intCast(self.entities.items.len);
    // 更新摄像头
    self.main_camera.updateFromMouse(self.window.*);
    self.main_camera.updateFromKeyboard(self.window.*, self.delta_time_f32);
    self.ubo.view_matrix = self.main_camera.getViewMatrix();
    // entity移动
    // self.entities.items[0].rotation = Vec3.new(1, @floatCast(self.current_frame_time * 100), 1);
    // self.entities.items[1].rotation = Vec3.new(1, @floatCast(self.current_frame_time * 100), 1);
    // self.entities.items[2].rotation = Vec3.new(1, @floatCast(self.current_frame_time * 100), 1);
    // self.entities.items[3].rotation = Vec3.new(1, @floatCast(self.current_frame_time * 100), 1);
}

const std = @import("std");
const wgpu = @import("cimprots.zig").wgpu;
const glfw = @import("cimprots.zig").glfw;

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");

const ShaderTypes = @import("shader_types.zig");
const SceneUniform = ShaderTypes.SceneUniform;

const Camera3D = @import("camera3d.zig");
const Entity = @import("entity.zig");
