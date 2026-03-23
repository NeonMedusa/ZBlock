allocator: std.mem.Allocator,
window: Window,
gctx: Gctx,
input: Input,
registry: ECS.Registry,
ui_system: UiSystem,
res_manager: ResManager,
render_pipeline: RenderPipeline,
camera: Camera3D,
ubo: SceneUniform,
pub fn deinit(self: *@This()) void {
    self.window.deinit();
    self.gctx.deinit();
    self.res_manager.deinit(self.allocator);
    self.render_pipeline.deinit();
    self.registry.deinit();
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
    const input = Input.init(self);
    self.input = input;
    // 初始化wgpu
    const gctx = try Gctx.init(self.window);
    self.gctx = gctx;
    // 初始化资源管理器
    const res_manager = try ResManager.init(allocator, self.gctx);
    self.res_manager = res_manager;
    // 创建渲染管线
    const render_pipeline = try RenderPipeline.init(
        self,
        "resources/shaders/render_shader.wgsl",
    );
    self.render_pipeline = render_pipeline;
    // 初始化摄像头
    self.camera = Camera3D.init();
    // 初始化ubo
    self.ubo = SceneUniform.init(self.window);
    // 初始化世界
    const registry = ECS.Registry.init(allocator);
    self.registry = registry;
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

    // 加载一个模型并使其成为一个实体的组件
    var model_1 = try Model.load(self.allocator, self.gctx, "Wolf", self.render_pipeline);
    defer model_1.deinit(self.allocator);
    const e1 = self.registry.create();
    self.registry.add(e1, model_1);
    self.registry.add(e1, Comps.Position{ .vec = .new(0, 0, 0) });
    // 另一个实体
    const e2 = self.registry.create();
    self.registry.add(e2, model_1);
    self.registry.add(e2, Comps.Position{ .vec = .new(0, 1, 0) });

    var model_2 = try Model.load(self.allocator, self.gctx, "BarramundiFish", self.render_pipeline);
    defer model_2.deinit(self.allocator);
    // 第三个实体
    const e3 = self.registry.create();
    self.registry.add(e3, model_2);
    self.registry.add(e3, Comps.Position{ .vec = .new(0, 2, 0) });
    // 第四个实体
    const e4 = self.registry.create();
    self.registry.add(e4, model_2);
    self.registry.add(e4, Comps.Position{ .vec = .new(0, 3, 0) });
    // 主循环
    while (!self.window.shouldClose()) {
        // 先重置输入状态
        self.input.beginFrame();
        // 再更新窗口事件
        self.window.pollEvents();
        // 如果主菜单不可见，则更新世界和摄像头
        if (!main_menu.visible) {
            // 更新摄像头
            self.camera.update(self);
            self.ubo.view_matrix = self.camera.getViewMatrix();
        }
        // UI开始新帧
        self.ui_system.beginFrame();
        // 如果主菜单可见，则渲染主菜单
        main_menu.update(self);
        // UI帧结束
        try self.ui_system.endFrame(&self.gctx);
        // 渲染
        Render.draw(self);
    }
}

const Game = @This();
const std = @import("std");

const Wgpu = @import("imports.zig").Wgpu;
const Glfw = @import("imports.zig").Glfw;
const Gltf = @import("zgltf");

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;

const Gctx = @import("gctx.zig");
const Window = @import("window.zig");
const Render = @import("render.zig");
const Camera3D = @import("camera3d.zig");
const ResManager = @import("rend_ctx.zig").ResManager;
const RenderPipeline = @import("render_pipeline.zig");

const UiSystem = @import("ui_system.zig");
const Input = @import("input.zig");

const ECS = @import("zigecs");

const SceneUniform = @import("rend_ctx.zig").SceneUniform;
const Comps = @import("components.zig").Components;

const Model = @import("rend_ctx.zig").Model;
