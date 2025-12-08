allocator: std.mem.Allocator,
window: Window,
gctx: Gctx,
input: Input,
scene: Scene,
ui_system: UiSystem,
res_manager: ResourceManager,
render_pipeline: RenderPipeline,
pub fn deinit(self: *@This()) void {
    self.window.deinit();
    self.gctx.deinit();
    self.res_manager.deinit(self.allocator);
    self.render_pipeline.deinit();
    self.scene.deinit();
    self.ui_system.deinit();
    self.allocator.destroy(self);
}
pub fn init(allocator: std.mem.Allocator) !*@This() {
    var self = try allocator.create(@This());
    self.allocator = allocator;
    // 创建窗口
    const window = try Window.init(self, "ZigGame", 640, 480);
    self.window = window;
    // 初始化输入系统
    const input = Input.init(&self.window);
    self.input = input;
    // 初始化wgpu
    var gctx = try Gctx.init(&self.window);
    self.gctx = gctx;
    // 初始化资源管理器
    var grm = try ResourceManager.init(allocator, &self.gctx);
    self.res_manager = grm;
    // 创建渲染管线
    const render_pipeline = try RenderPipeline.init(
        &gctx,
        "resources/shaders/render_shader.wgsl",
        &grm,
    );
    self.render_pipeline = render_pipeline;
    // 初始化场景
    const scene = Scene.init(allocator, self);
    self.scene = scene;
    // 初始化UI系统
    const ui_system = try UiSystem.init(allocator, &self.gctx, self);
    self.ui_system = ui_system;
    // 返回实例
    return self;
}
// 开始游戏
pub fn start(self: *@This()) !void {
    // 初始化主菜单
    var main_menu = @import("ui/main_menu.zig"){};
    // // 为场景添加一些实例（仅用于调试）
    try initScene(&self.scene);
    // 主循环
    while (!self.window.shouldClose()) {
        // 先重置输入状态
        self.input.beginFrame();
        // 再更新窗口事件
        self.window.pollEvents();
        // 如果主菜单不可见，则更新场景
        if (!main_menu.visible)
            try self.scene.update();
        // UI开始新帧
        self.ui_system.beginFrame();
        // 如果主菜单可见，则渲染主菜单
        main_menu.update(self);
        // UI帧结束
        try self.ui_system.endFrame(&self.gctx);
        // 渲染
        try Render.draw(self);
    }
}

// 为场景添加一些实例（仅用于调试）
fn initScene(scene: *Scene) !void {
    for (0..100) |value| {
        const entity0 = Entity{
            .model = .Avocado,
            .position = Vec3{ .data = .{ 0, 0, @floatFromInt(value * 2) } },
            .scale = Vec3{ .data = .{ 15, 15, 15 } },
        };
        try scene.addEntity(entity0);
    }
    for (0..100) |value| {
        const entity1 = Entity{
            .model = .BarramundiFish,
            .position = Vec3{ .data = .{ 3, 0, @floatFromInt(value * 2) } },
            .scale = Vec3{ .data = .{ 3, 3, 3 } },
        };
        try scene.addEntity(entity1);
    }
    // for (0..100) |value| {
    //     const entity2 = Entity{
    //         .model = .Buggy,
    //         .position = Vec3{ .data = .{ 6, 0, @floatFromInt(value) } },
    //         .scale = Vec3{ .data = .{ 0.025, 0.025, 0.025 } },
    //     };
    //     try scene.addEntity(entity2);
    // }
    for (0..100) |value| {
        const entity3 = Entity{
            .model = .Wolf,
            .cur_anime_time = @floatFromInt(value + 1),
            .anime_speed = 1 + @as(f32, @floatFromInt(value)),
            .position = Vec3{ .data = .{ 6, 0, @floatFromInt(value * 2) } },
        };
        try scene.addEntity(entity3);
    }
    for (0..100) |value| {
        const entity3 = Entity{
            .model = .CesiumMan,
            .cur_anime_time = @floatFromInt(value + 1),
            .anime_speed = 1 + @as(f32, @floatFromInt(value)),
            .position = Vec3{ .data = .{ 9, 0, @floatFromInt(value * 2) } },
        };
        try scene.addEntity(entity3);
    }
}

const Game = @This();
const std = @import("std");

const World = @import("world.zig").World;
const Wgpu = @import("cimports.zig").Wgpu;
const Glfw = @import("cimports.zig").Glfw;

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Gltf = @import("zgltf");

const Gctx = @import("gctx.zig");
const Window = @import("window.zig");
const Render = @import("render.zig");
const Camera3D = @import("camera3d.zig");
const Entity = @import("entity.zig");
const Scene = @import("scene.zig");
const ResourceManager = @import("resource_manager.zig");
const RenderPipeline = @import("render_pipeline.zig");
const ModelName = @import("model.zig").ModelName;

const UiSystem = @import("ui_system.zig");
const Input = @import("input.zig");
