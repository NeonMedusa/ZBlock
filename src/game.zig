// game.zig
allocator: std.mem.Allocator,
window: Window,
gctx: Gctx,
input: Input,
registry: ECS.Registry,
ui_system: UiSystem,
res_manager: ResManager,
wireframe_pipeline: WireframePipeline,
render_pipeline: RenderPipeline,
camera: Camera3D,
ubo: SceneUniform,
player_id: u32 = 0,

// 开始游戏
pub fn start(self: *Game) !void {
    // 初始化主菜单
    var main_menu = @import("ui/main_menu.zig"){};

    // 创建用于测试的实体
    const e1 = self.registry.create();
    self.registry.add(e1, Comps.ModelName{ .string = "CesiumMan" });
    self.registry.add(e1, Comps.Position{ .vec = .new(0, 0, 0) });
    self.registry.add(e1, Comps.Velocity{ .vec = Vec3.zero });
    self.registry.add(e1, Comps.Player{ .id = self.player_id });
    self.registry.add(e1, Comps.Speed{ .value = 3 });

    // 主循环
    while (!self.window.shouldClose()) {
        // 先重置输入状态
        self.input.beginFrame();
        // 再更新窗口事件
        self.window.pollEvents();
        // 如果主菜单不可见，则更新世界和摄像头
        if (!main_menu.visible)
            // 更新摄像头
            self.camera.update(self);

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
    const res_manager = try ResManager.init(allocator, &self.gctx, &self.render_pipeline);
    self.res_manager = res_manager;

    // 创建渲染管线
    self.render_pipeline = try RenderPipeline.init(
        self,
        "resources/shaders/render_shader.wgsl",
    );
    // 线框管线（调试用）
    self.wireframe_pipeline = try WireframePipeline.init(
        self,
        "resources/shaders/wireframe_shader.wgsl",
    );

    // 初始化摄像头
    self.camera = Camera3D.init(self);
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

pub fn deinit(self: *@This()) void {
    // 最后释放自己
    defer self.allocator.destroy(self);

    // 清理所有未完成的 MoveOrder 组件
    var view = self.registry.view(.{Comps.MoveOrder}, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        var order = self.registry.get(Comps.MoveOrder, entity);
        order.deinit();
        self.registry.remove(Comps.MoveOrder, entity);
    }
    self.window.deinit();
    self.gctx.deinit();
    self.res_manager.deinit(self.allocator);
    self.render_pipeline.deinit();
    self.render_pipeline.deinit();
    self.registry.deinit();
    self.ui_system.deinit();
}

const Game = @This();

const std = @import("std");
const Imports = @import("imports.zig");

const Wgpu = Imports.Wgpu;
const Glfw = Imports.Glfw;
const Gltf = Imports.Gltf;

const Algebra = Imports.Algebra;
const Vec2 = Algebra.Vec2;
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;

const Gctx = Imports.Gctx;
const Window = Imports.Window;
const Render = Imports.Render;
const Camera3D = Imports.Camera3D;

const RenderPipeline = Imports.RenderPipeline;

const UiSystem = Imports.UiSystem;
const Input = Imports.Input;

const ECS = Imports.ECS;

const RendCTX = Imports.RendCTX;
const ResManager = RendCTX.ResManager;
const Model = RendCTX.Model;
const SceneUniform = RendCTX.SceneUniform;

const Comps = Imports.Comps;

const Raycast = @import("raycast.zig");

const WireframePipeline = @import("wireframe_pipeline.zig").WireframePipeline;
