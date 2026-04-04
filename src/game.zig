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
rts_map: RTSMap,
player_id: u32 = 0,
pub fn deinit(self: *@This()) void {
    // 清理所有未完成的 MoveOrder 组件
    var view = self.registry.view(.{Comps.MoveOrder}, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        var order = self.registry.get(Comps.MoveOrder, entity);
        order.deinit();
        self.registry.remove(Comps.MoveOrder, entity);
    }

    // 原有的清理代码
    self.window.deinit();
    self.gctx.deinit();
    self.res_manager.deinit(self.allocator);
    self.render_pipeline.deinit();
    self.registry.deinit();
    self.ui_system.deinit();
    self.rts_map.deinit();
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
    self.camera = Camera3D.init(self);
    // 初始化ubo
    self.ubo = SceneUniform.init(self.window);
    // 初始化世界
    const registry = ECS.Registry.init(allocator);
    self.registry = registry;
    // 初始化UI系统
    const ui_system = try UiSystem.init(allocator, &self.gctx, self);
    self.ui_system = ui_system;

    const rts_map = try RTSMap.init(
        self.allocator,
        &self.gctx,
        32,
        32,
        &self.render_pipeline,
    );
    // rts_map.terrain.generateRandom(1);
    self.rts_map = rts_map;

    // 返回实例
    return self;
}
// 开始游戏
pub fn start(self: *Game) !void {
    // 初始化主菜单
    var main_menu = @import("ui/main_menu.zig"){};

    // 创建用于测试的实体
    const e1 = self.registry.create();
    self.registry.add(e1, Comps.ModelName{ .string = "CesiumMan" });
    self.registry.add(e1, Comps.Position{ .vec = .new(1, 3, 0) });
    self.registry.add(e1, Comps.Velocity{ .vec = Vec3.zero });

    self.registry.add(e1, Comps.Player{ .id = self.player_id });
    self.registry.add(e1, Comps.Speed{ .value = 3 });

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

            Physys.update(self);
            try PlayerMoveSys.update(self);

            if (self.input.isKeyPressed(.equal)) {
                self.rts_map.terrain.rotation_y += self.window.delta_time;
            }
            if (self.input.isKeyPressed(.minus)) {
                self.rts_map.terrain.rotation_y -= self.window.delta_time;
            }

            // 地形编辑
            if (self.input.isMouseButtonPressed(.mouse_left)) {
                const ray = self.camera.getForwardRay();
                const hit = Raycast.raycast(ray, 100.0, &self.rts_map.terrain);
                if (hit.hit and hit.hit_type == .terrain) {
                    self.rts_map.terrain.modifyHeightWorld(Vec2.new(hit.point.x, hit.point.z), 2.0, 0.01);
                }
            }
            if (self.input.isMouseButtonPressed(.mouse_right)) {
                const ray = self.camera.getForwardRay();
                const hit = Raycast.raycast(ray, 100.0, &self.rts_map.terrain);
                if (hit.hit and hit.hit_type == .terrain) {
                    self.rts_map.terrain.modifyHeightWorld(Vec2.new(hit.point.x, hit.point.z), 2.0, -0.01);
                }
            }

            // 创建不可达区域
            if (self.input.isKeyPressed(.b)) {
                const ray = self.camera.getForwardRay();
                const hit = Raycast.raycast(ray, 100.0, &self.rts_map.terrain);
                if (hit.hit and hit.hit_type == .terrain) {
                    self.rts_map.sculptAndBlock(Vec2.new(hit.point.x, hit.point.z), 3.0, 0.01);
                }
            }

            // 设置层级
            if (self.input.isKeyPressed(.num1)) {
                const ray = self.camera.getForwardRay();
                const hit = Raycast.raycast(ray, 100.0, &self.rts_map.terrain);
                if (hit.hit and hit.hit_type == .terrain)
                    self.rts_map.setLayer(Vec2.new(hit.point.x, hit.point.z), 3.0, 1);
            }
            // 创建斜坡
            if (self.input.isKeyPressed(.r)) {
                const ray = self.camera.getForwardRay();
                const hit = Raycast.raycast(ray, 100.0, &self.rts_map.terrain);
                if (hit.hit and hit.hit_type == .terrain) {
                    self.rts_map.createRampBrush(Vec2.new(hit.point.x, hit.point.z), 3.0);
                }
            }

            if (self.input.isKeyPressed(.num2)) {
                const ray = self.camera.getForwardRay();
                const hit = Raycast.raycast(ray, 100.0, &self.rts_map.terrain);
                if (hit.hit and hit.hit_type == .terrain)
                    self.rts_map.setLayer(Vec2.new(hit.point.x, hit.point.z), 3.0, 2);
            }
            if (self.input.isKeyPressed(.num3)) {
                const ray = self.camera.getForwardRay();
                const hit = Raycast.raycast(ray, 100.0, &self.rts_map.terrain);
                if (hit.hit and hit.hit_type == .terrain)
                    self.rts_map.setLayer(Vec2.new(hit.point.x, hit.point.z), 3.0, 3);
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

const RTSMap = Imports.RTSMap;
