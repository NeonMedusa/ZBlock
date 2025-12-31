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
movement_system: MovementSystem,
player_system: PlayerControlSystem,
health_system: HealthSystem,
pub fn deinit(self: *@This()) void {
    self.window.deinit();
    self.gctx.deinit();
    self.res_manager.deinit(self.allocator);
    self.render_pipeline.deinit();
    self.world.deinit();
    self.ui_system.deinit();

    self.movement_system.deinit();
    self.player_system.deinit();
    self.health_system.deinit();

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

    // 初始化噪声系统
    const perlin = @import("perlin.zig");
    perlin.init(99);
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
    self.world = World.init(allocator);
    // 初始化系统
    self.movement_system = MovementSystem.init(allocator);
    self.player_system = PlayerControlSystem.init(allocator);
    self.health_system = HealthSystem.init(allocator);
    // 2. 注册系统
    try self.world.system_manager.registerSystem(&self.movement_system.base);
    try self.world.system_manager.registerSystem(&self.player_system.base);
    try self.world.system_manager.registerSystem(&self.health_system.base);
    std.debug.print("regist:{d}\n", .{self.world.system_manager.systems.items.len});
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
    std.debug.print("start:{d}\n", .{self.world.system_manager.systems.items.len});
    // 将世界初始化为测试场景
    try initTestWorld(self);
    var pos_offset: f32 = 0;
    // 主循环
    while (!self.window.shouldClose()) {
        // 先重置输入状态
        self.input.beginFrame();
        // 再更新窗口事件
        self.window.pollEvents();
        // 如果主菜单不可见，则更新世界和摄像头
        if (!main_menu.visible) {

            // 测试实例增删
            if (self.input.isKeyDown(.minus)) {
                var it = self.world.healths.iterator();
                while (it.next()) |entry| {
                    entry.@"1".current -= 1;
                    const entity = entry.@"0";
                    const name = self.world.models.get(entity).?.*;
                    std.debug.print("{}.health:{d}\n", .{ name, entry.@"1".current });
                }
                std.debug.print("dense.len:{d}\n", .{self.world.models.iterator().storage.dense.items.len});
                var models_it = self.world.models.iterator();
                var models_it_next_is_null = true;
                if (models_it.next()) |model| {
                    _ = model;
                    models_it_next_is_null = true;
                }
                std.debug.print("it_next_is_null:{}\n", .{models_it_next_is_null});
            }
            if (self.input.isKeyDown(.equal)) {
                _ = try self.world.createBaseEntity(
                    .CesiumMan,
                    .{ .vec = Vec3.new(0, 0, -pos_offset) },
                    .{ .value = 1 },
                    .{ .current = 3, .max = 3 },
                );
                pos_offset += 1;
            }

            // 更新世界系统
            self.player_system.update(&self.world, self.window.delta_time);
            try self.movement_system.update(&self.world, self.window.delta_time);
            try self.health_system.update(&self.world, self.window.delta_time);
            // 在所有系统更新完成后处理实体删除
            try self.world.processPendingRemovals();
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
        try Render.draw(self);
    }
}

fn initTestWorld(game: *Game) !void {
    const player1 = try game.world.createPlayer(
        .CesiumMan,
        .{ .vec = Vec3.new(0, 0, 0) },
        .{ .value = 2.0 }, // 基础速度
        .{ .current = 3.0, .max = 3.0 }, // 生命值
        .{ .input = &game.input, .player_id = 1 },
    );
    _ = player1;

    const entity1 = try game.world.createBaseEntity(
        .Wolf,
        .{ .vec = Vec3.new(0, 0, 0) },
        .{ .value = 2.0 }, // 基础速度
        .{ .current = 5.0, .max = 100.0 }, // 生命值
    );
    try game.world.setComponent(entity1, ECS.MovingTarget{ .vec = Vec3.new(10, 0, 0) });

    const entity2 = try game.world.createBaseEntity(
        .BarramundiFish,
        .{ .vec = Vec3.new(0, 0, 0) },
        .{ .value = 1.5 }, // 基础速度
        .{ .current = 4.0, .max = 80.0 }, // 生命值
    );
    try game.world.setComponent(entity2, ECS.MovingTarget{ .vec = Vec3.new(-10, 0, 0) });
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
const MovementSystem = ECS.MovementSystem;
const PlayerControlSystem = ECS.PlayerControlSystem;
const HealthSystem = ECS.HealthSystem;

const ShaderType = @import("shader_types.zig");
const SceneUniform = ShaderType.SceneUniform;
