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

    // 测试GPU资源管理器
    const grm = try ResourceManager.init(allocator, &gctx);

    // 创建渲染管线
    const render_pipeline = try RenderPipeline.init(
        &gctx,
        "resources/shaders/render_shader.wgsl",
        &grm,
    );
    defer render_pipeline.deinit();

    var scene = Scene.init(allocator, &window);
    defer scene.deinit();

    const entity0 = Entity{
        .model = 0,
        .position = Vec3.zero(),
        .scale = Vec3{ .data = .{ 15, 15, 15 } },
    };
    try scene.addEntity(entity0);

    const entity1 = Entity{
        .model = 1,
        .position = Vec3{ .data = .{ 3, 0, 0 } },
        .scale = Vec3{ .data = .{ 4, 4, 4 } },
    };
    try scene.addEntity(entity1);

    const entity2 = Entity{
        .model = 2,
        .position = Vec3{ .data = .{ 6, 0, 0 } },
        .scale = Vec3{ .data = .{ 0.025, 0.025, 0.025 } },
    };
    try scene.addEntity(entity2);

    const entity3 = Entity{
        .model = 3,
        .position = Vec3{ .data = .{ 9, 0, 0 } },
    };
    try scene.addEntity(entity3);

    // 主循环
    while (window.shouldClose()) {
        // ESC键关闭窗口
        if (window.input.isKeyPressed(.escape))
            window.setWindowShouldClose();
        Window.pollEvents();
        // 更新场景
        try scene.update();
        // 渲染
        try Render.draw(&gctx, &render_pipeline, &scene, &grm);
    }
}

const std = @import("std");
const wgpu = @import("cimprots.zig").wgpu;
const glfw = @import("cimprots.zig").glfw;

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
const ComputePipeline = @import("compute_pipeline.zig");
const RenderPipeline = @import("render_pipeline.zig");
