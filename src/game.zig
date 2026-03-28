// game.zig
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
terrain: Terrain,
player_id: u32 = 0,
pub fn deinit(self: *@This()) void {
    self.window.deinit();
    self.gctx.deinit();
    self.res_manager.deinit(self.allocator);
    self.render_pipeline.deinit();
    self.registry.deinit();
    self.ui_system.deinit();
    self.terrain.deinit();
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
    const res_manager = try ResManager.init(allocator, &self.gctx, &self.render_pipeline);
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

    var terrain = try Terrain.init(
        self.allocator,
        &self.gctx,
        Vec3.new(4, 4, 4),
        45.0 * std.math.pi / 180.0,
        32.0,
        32.0,
        64,
        -2.0,
        2.0,
        &self.render_pipeline,
    );
    terrain.generateRandom(1);
    self.terrain = terrain;

    // 返回实例
    return self;
}
// 开始游戏
pub fn start(self: *Game) !void {
    // 初始化主菜单
    var main_menu = @import("ui/main_menu.zig"){};

    // 加载一个模型并使其成为一个实体的组件
    const e1 = self.registry.create();
    self.registry.add(e1, Comps.ModelName{ .string = "CesiumMan" });
    self.registry.add(e1, Comps.Position{ .vec = .new(1, 3, 0) });
    self.registry.add(e1, Comps.Velocity{ .vec = Vec3.zero });

    self.registry.add(e1, Comps.Player{ .id = self.player_id });
    self.registry.add(e1, Comps.Speed{ .value = 3 });

    // 另一个实体
    const e2 = self.registry.create();
    self.registry.add(e2, Comps.ModelName{ .string = "CesiumMan" });
    self.registry.add(e2, Comps.Position{ .vec = .new(3, 3, 0) });
    self.registry.add(e2, Comps.Velocity{ .vec = Vec3.zero });

    // 第三个实体
    const e3 = self.registry.create();
    self.registry.add(e3, Comps.ModelName{ .string = "BarramundiFish" });
    self.registry.add(e3, Comps.Position{ .vec = .new(5, 3, 0) });
    self.registry.add(e3, Comps.Velocity{ .vec = Vec3.zero });
    // 第四个实体
    const e4 = self.registry.create();
    self.registry.add(e4, Comps.ModelName{ .string = "BarramundiFish" });
    self.registry.add(e4, Comps.Position{ .vec = .new(7, 3, 0) });
    self.registry.add(e4, Comps.Velocity{ .vec = Vec3.zero });

    const Physys = @import("systems/physics_sys.zig").PhysicsSystem;
    const PlayerMoveSys = @import("systems/player_movement_system.zig").PlayerSystem;
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

            Physys.update(self);
            PlayerMoveSys.update(self);

            // if (self.input.isKeyPressed(.right)) {
            //     self.terrain.position.x += self.window.delta_time;
            // }
            // if (self.input.isKeyPressed(.left)) {
            //     self.terrain.position.x -= self.window.delta_time;
            // }
            if (self.input.isKeyPressed(.equal)) {
                self.terrain.rotation_y += self.window.delta_time;
            }
            if (self.input.isKeyPressed(.minus)) {
                self.terrain.rotation_y -= self.window.delta_time;
            }
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
const Imports = @import("imports.zig");

const Wgpu = Imports.Wgpu;
const Glfw = Imports.Glfw;
const Gltf = Imports.Gltf;

const Algebra = Imports.Algebra;
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

const Terrain = Imports.Terrain;
