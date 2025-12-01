//main.zig:
pub fn main() !void {
    // 创建内存分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建窗口（NO_API模式）
    var window = try Window.init("ZigGame", 640, 480);
    defer window.deinit();

    // 初始化wgpu
    var gctx = try Gctx.init(&window);
    defer gctx.deinit();

    // 初始化资源管理器
    var rm = try ResourceManager.init(allocator, &gctx);
    defer rm.deinit(allocator);

    // 创建渲染管线
    const render_pipeline = try RenderPipeline.init(
        &gctx,
        "resources/shaders/render_shader.wgsl",
        &rm,
    );
    defer render_pipeline.deinit();

    var scene = Scene.init(allocator, &window);
    defer scene.deinit();

    // 初始化UI系统
    var ui_system = try UiSystem.init(allocator, &gctx, &window);
    defer ui_system.deinit();

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

    // 主循环
    while (window.shouldClose()) {
        // ESC键关闭窗口
        if (window.isKeyPressed(.escape))
            window.setWindowShouldClose();
        Window.pollEvents();

        // 更新场景
        try scene.update();

        // UI开始新帧
        ui_system.beginFrame();
        // 绘制UI
        if (ui_system.button(20, 20)) {
            std.debug.print("button_is_pressed\n", .{});
        }
        // UI帧结束
        try ui_system.endFrame(&gctx);

        // 渲染
        try Render.draw(&gctx, &render_pipeline, &scene, &rm, &ui_system);
    }
}
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
const Input = @import("input.zig");
const Entity = @import("entity.zig");
const Scene = @import("scene.zig");
const ResourceManager = @import("resource_manager.zig");
const RenderPipeline = @import("render_pipeline.zig");
const ModelName = @import("model.zig").ModelName;

const UiSystem = @import("ui_system.zig");
