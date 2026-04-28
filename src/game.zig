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
block_world: BlockWorld,

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
    self.registry.add(e1, Comps.MoveSpeed{ .value = 3 });
    self.registry.add(e1, Comps.JumpVelocity{ .value = 8.0 });
    self.registry.add(e1, Comps.OnGround{ .value = false });
    self.registry.add(e1, Comps.AABB{});
    self.registry.add(e1, Comps.MoveIntent{});

    const e2 = self.registry.create();
    self.registry.add(e2, Comps.ModelName{ .string = "CesiumMan" });
    self.registry.add(e2, Comps.Position{ .vec = .new(0, 2, 0) });

    // 主循环
    while (!self.window.shouldClose()) {
        // 先重置输入状态
        self.input.beginFrame();
        // 再更新窗口事件
        self.window.pollEvents();
        // 如果主菜单不可见，则更新世界和摄像头
        if (!main_menu.visible) {
            self.updatePlayerMovement();
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

pub fn init(allocator: std.mem.Allocator) !*@This() {
    var self = try allocator.create(@This());
    self.allocator = allocator;
    // 创建窗口
    const window = try Window.init(self, "ZigGame", 1280, 720);
    self.window = window;
    // 初始化输入系统
    const input = Input.init(self);
    self.input = input;
    // 初始化wgpu
    const gctx = try Gctx.init(self.window);
    self.gctx = gctx;

    // 初始化噪声系统
    const perlin = @import("perlin.zig");
    perlin.init(99);
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

    // 测试方块世界
    self.block_world = try BlockWorld.init(self.allocator, &self.gctx, &self.render_pipeline);

    // 返回实例
    return self;
}

pub fn deinit(self: *@This()) void {
    // 最后释放自己
    defer self.allocator.destroy(self);

    self.window.deinit();
    self.gctx.deinit();
    self.res_manager.deinit(self.allocator);
    self.render_pipeline.deinit();
    self.render_pipeline.deinit();
    self.registry.deinit();
    self.ui_system.deinit();
    self.block_world.deinit();
}

fn updatePlayerMovement(self: *Game) void {
    var move_dir = Vec3.zero;
    var input = self.input;

    // 水平方向投影
    const front_h = Vec3.new(self.camera.front.x, 0, self.camera.front.z).norm();
    const right_h = Vec3.new(
        self.camera.front.cross(self.camera.up).x,
        0,
        self.camera.front.cross(self.camera.up).z,
    ).norm();

    if (input.isKeyPressed(.w)) move_dir = move_dir.add(front_h);
    if (input.isKeyPressed(.s)) move_dir = move_dir.sub(front_h);
    if (input.isKeyPressed(.a)) move_dir = move_dir.sub(right_h);
    if (input.isKeyPressed(.d)) move_dir = move_dir.add(right_h);

    // 游泳/跳跃
    if (input.isKeyPressed(.space)) {
        if (self.block_world.physics.on_ground) {
            self.block_world.physics.jump();
        } else if (self.block_world.physics.isInSwimmable()) {
            move_dir.y = 1.0;
        }
    }

    // 水中下潜
    if (input.isKeyPressed(.left_control) or input.isKeyPressed(.right_control)) {
        if (self.block_world.physics.isInSwimmable()) {
            move_dir.y = -1.0;
        }
    }

    if (move_dir.len2() > 0.001) move_dir = move_dir.norm();

    self.block_world.tick(move_dir, self.window.delta_time);

    // 摄像机跟随
    const eye_offset = Vec3.new(0, 1.6, 0);
    self.camera.position = self.block_world.physics.position.add(eye_offset);
    self.camera.updateFromMouse(self);
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

const BlockWorld = @import("block_world.zig").BlockWorld;
