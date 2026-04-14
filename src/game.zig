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
rts_map: RTSMap,
player_id: u32 = 0,

next_constraint_id: u32 = 1, // 从1开始，0预留给地图边界

constraint_start: ?Vec2 = null, // 右键按下时记录的第一个点

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
        if (!main_menu.visible) {
            // 更新摄像头
            self.camera.update(self);

            // 鼠标点击插入点
            if (self.input.isMouseButtonDown(.mouse_left)) {
                const ray = self.camera.getForwardRay();
                if (self.rts_map.raycast(ray.origin, ray.direction)) |hit| {
                    const pt = Vec2.new(hit.point.x, hit.point.z);
                    const tolerance = 0.5;
                    _ = try self.rts_map.cdt.findOrAddVertex(pt, tolerance);
                    try self.rts_map.updateMeshBuffers();
                }
            }

            // 鼠标右键按下：记录起点
            if (self.input.isMouseButtonDown(.mouse_right)) {
                const ray = self.camera.getForwardRay();
                if (self.rts_map.raycast(ray.origin, ray.direction)) |hit| {
                    const pt = Vec2.new(hit.point.x, hit.point.z);
                    if (self.constraint_start == null) {
                        self.constraint_start = pt;
                        std.debug.print("Constraint edge starting point: ({d:.2}, {d:.2})\n", .{ pt.x, pt.y });
                    }
                } // 如果未击中，什么也不做
            }

            // 在鼠标释放逻辑中修改
            if (self.input.isMouseButtonReleased(.mouse_right)) {
                if (self.constraint_start) |start_pt| {
                    const ray = self.camera.getForwardRay();
                    if (self.rts_map.raycast(ray.origin, ray.direction)) |hit| {
                        const end = Vec2.new(hit.point.x, hit.point.z);
                        if (!start_pt.eql(end)) {
                            const tolerance = 0.5;
                            const v1 = try self.rts_map.cdt.findOrAddVertex(start_pt, tolerance);
                            const v2 = try self.rts_map.cdt.findOrAddVertex(end, tolerance);

                            // 分配新约束ID
                            const new_id = self.next_constraint_id;
                            self.next_constraint_id += 1;

                            // 使用正确的函数名
                            try self.rts_map.cdt.insertConstraintSegment(v1, v2, new_id);
                            try self.rts_map.updateMeshBuffers();
                        }
                    }
                    self.constraint_start = null;
                }
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

pub fn deinit(self: *@This()) void {
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
    self.rts_map.deinit();
    self.allocator.destroy(self);
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

const RTSMap = @import("rts_map.zig").RTSMap;

const WireframePipeline = @import("wireframe_pipeline.zig").WireframePipeline;
