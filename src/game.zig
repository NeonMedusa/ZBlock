allocator: std.mem.Allocator,
window: Window,
gctx: Gctx,
input: Input,
world: World,
ui_system: UiSystem,
res_manager: ResourceManager,
render_pipeline: RenderPipeline,
camera: Camera3D,
ubo: SceneUniform,
pub fn deinit(self: *@This()) void {
    self.window.deinit();
    self.gctx.deinit();
    self.res_manager.deinit(self.allocator);
    self.render_pipeline.deinit();
    self.world.deinit();
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
    const res_manager = try ResourceManager.init(allocator, self.gctx);
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
    const world = World.init(allocator);
    self.world = world;
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

    // 将世界初始化为测试场景
    try initTestWorld(self);

    // 主循环
    while (!self.window.shouldClose()) {
        // 先重置输入状态
        self.input.beginFrame();
        // 再更新窗口事件
        self.window.pollEvents();
        // 如果主菜单不可见，则更新世界和摄像头
        if (!main_menu.visible) {
            self.world.update(self.window.delta_time);
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
        try Render.draw(self);
    }
}

fn initTestWorld(game: *Game) !void {
    const player1 = try game.world.createPlayer(
        .CesiumMan,
        Vec3.new(0, 0, 0),
        2.0, // 基础速度
        100.0, // 生命值
        1,
        &game.input,
    );
    _ = player1;

    const entity1 = try game.world.createBaseEntity(
        .Wolf,
        Vec3.new(0, 0, 0),
        2.0, // 基础速度
        100.0, // 生命值
    );
    try game.world.moving_targets.set(entity1, Vec3.new(10, 0, 0));

    const entity2 = try game.world.createBaseEntity(
        .BarramundiFish,
        Vec3.new(0, 0, 0),
        1.5,
        80.0,
    );
    try game.world.moving_targets.set(entity2, Vec3.new(-10, 0, 0));
}

const Game = @This();
const std = @import("std");

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
const ResourceManager = @import("resource_manager.zig");
const RenderPipeline = @import("render_pipeline.zig");
const ModelName = @import("model.zig").ModelName;

const UiSystem = @import("ui_system.zig");
const Input = @import("input.zig");

const ECS = @import("ecs.zig");
const World = ECS.World;

const ShaderType = @import("shader_types.zig");
const SceneUniform = ShaderType.SceneUniform;
