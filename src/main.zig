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

    // 创建pipeline
    const pipeline = try Pipeline.init(&gctx, "resources/shader.wgsl");
    defer pipeline.deinit();

    // 模型管理器测试
    var model_manager = try ModelManager.init(gctx, allocator);
    defer model_manager.deinit();

    var scene = Scene.init(allocator, &window);
    defer scene.deinit();

    const cesium_man = Entity{
        .model = "CesiumMan",
        .position = Vec3.zero(),
    };
    try scene.addEntity(cesium_man);

    const buggy = Entity{
        .model = "Buggy",
        .position = Vec3{ .data = .{ 5, 0, 0 } },
        .scale = Vec3{ .data = .{ 0.05, 0.05, 0.05 } },
    };
    try scene.addEntity(buggy);

    // 主循环
    while (window.shouldClose()) {
        // ESC键关闭窗口
        if (window.input.isKeyPressed(.escape))
            window.setWindowShouldClose();
        Window.pollEvents();
        try scene.update();
        // 渲染
        try Render.draw(gctx, pipeline, scene, model_manager);
    }
}

const std = @import("std");
const wgpu = @cImport({
    @cInclude("wgpu.h");
});
const glfw = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cDefine("GLFW_EXPOSE_NATIVE_WIN32", "1");
    @cInclude("glfw3.h");
    @cInclude("glfw3native.h");
});

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Gltf = @import("zgltf");

const Gctx = @import("gctx.zig");
const Window = @import("window.zig");
const Pipeline = @import("pipeline.zig");
const Mesh = @import("mesh.zig");
const Render = @import("render.zig");
const Camera3D = @import("camera3d.zig");
const Input = @import("input.zig");
const Entity = @import("entity.zig");
const Scene = @import("scene.zig");
const ModelManager = @import("zgltf_wapper.zig").ModelManager;
