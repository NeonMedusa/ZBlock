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

constraint_start: ?Vec2 = null, // 右键按下时记录的第一个点

buildings: std.ArrayListUnmanaged(Building),

const Building = struct {
    fixed_edge_ids: std.ArrayListUnmanaged(u32),
    vertex_indices: std.ArrayListUnmanaged(u32), // 新增：记录使用的顶点

    pub fn deinit(self: *Building, allocator: std.mem.Allocator) void {
        self.fixed_edge_ids.deinit(allocator);
        self.vertex_indices.deinit(allocator);
    }
};

// 开始游戏
pub fn start(self: *Game) !void {
    // 初始化主菜单
    var main_menu = @import("ui/main_menu.zig"){};
    self.buildings = std.ArrayListUnmanaged(Building){};

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

            // // 鼠标左键按下：放置正方形建筑
            // if (self.input.isMouseButtonDown(.mouse_left)) {
            //     const ray = self.camera.getForwardRay();
            //     if (self.rts_map.raycast(ray.origin, ray.direction)) |hit| {
            //         const center = Vec2.new(hit.point.x, hit.point.z);
            //         const half_size = 2.5; // 边长 5.0 的正方形
            //         // 计算四个顶点（逆时针：左下 → 右下 → 右上 → 左上）
            //         const corners = [_]Vec2{
            //             Vec2.new(center.x - half_size, center.y - half_size),
            //             Vec2.new(center.x + half_size, center.y - half_size),
            //             Vec2.new(center.x + half_size, center.y + half_size),
            //             Vec2.new(center.x - half_size, center.y + half_size),
            //         };

            //         const tolerance = 0.5;
            //         var verts: [4]u32 = undefined;
            //         for (corners, 0..) |pt, i| {
            //             verts[i] = try self.rts_map.cdt.findOrAddVertex(pt, tolerance);
            //         }

            //         // 创建建筑记录
            //         var building = Building{
            //             .fixed_edge_ids = .{},
            //         };
            //         errdefer building.deinit(self.allocator);

            //         // 插入四条边（逆时针方向）
            //         const edges = [_][2]u32{
            //             .{ verts[0], verts[1] },
            //             .{ verts[1], verts[2] },
            //             .{ verts[2], verts[3] },
            //             .{ verts[3], verts[0] },
            //         };
            //         for (edges) |pair| {
            //             const id = try self.rts_map.cdt.insertConstraintEdge(pair[0], pair[1]);
            //             try building.fixed_edge_ids.append(self.allocator, id);
            //         }

            //         // 保存建筑
            //         try self.buildings.append(self.allocator, building);
            //         try self.rts_map.updateMeshBuffers();

            //         std.debug.print("Placed building with {} edges, total buildings: {}\n", .{
            //             building.fixed_edge_ids.items.len,
            //             self.buildings.items.len,
            //         });
            //     }
            // }
            // // 鼠标右键按下：删除最后一个建筑
            // if (self.input.isMouseButtonDown(.mouse_right)) {
            //     if (self.buildings.items.len > 0) {
            //         var building = self.buildings.pop().?;
            //         defer building.deinit(self.allocator);

            //         // 移除该建筑的所有约束边标记
            //         for (building.fixed_edge_ids.items) |id|
            //             try self.rts_map.cdt.removeConstraintsById(id);

            //         try self.rts_map.updateMeshBuffers();

            //         std.debug.print("Removed building, remaining: {}\n", .{self.buildings.items.len});
            //     } else {
            //         std.debug.print("No building to remove\n", .{});
            //     }
            // }

            // // 鼠标右键按下：记录起点
            // if (self.input.isMouseButtonDown(.mouse_right)) {
            //     const ray = self.camera.getForwardRay();
            //     if (self.rts_map.raycast(ray.origin, ray.direction)) |hit| {
            //         const pt = Vec2.new(hit.point.x, hit.point.z);
            //         if (self.constraint_start == null) {
            //             self.constraint_start = pt;
            //             std.debug.print("Constraint edge starting point: ({d:.2}, {d:.2})\n", .{ pt.x, pt.y });
            //         }
            //     } // 如果未击中，什么也不做
            // }
            // if (self.input.isMouseButtonReleased(.mouse_right)) {
            //     if (self.constraint_start) |start_pt| {
            //         const ray = self.camera.getForwardRay();
            //         if (self.rts_map.raycast(ray.origin, ray.direction)) |hit| {
            //             const end = Vec2.new(hit.point.x, hit.point.z);
            //             // 避免起点和终点相同
            //             if (!start_pt.eql(end)) {
            //                 std.debug.print("Insert constraint edge: ({d:.2}, {d:.2}) -> ({d:.2}, {d:.2})\n", .{ start_pt.x, start_pt.y, end.x, end.y });
            //                 // 将两个端点加入顶点列表并插入网格
            //                 const tolerance = 0.5; // 根据你的地图尺度调整，例如网格间距的 1/10
            //                 const v1 = try self.rts_map.cdt.findOrAddVertex(start_pt, tolerance);
            //                 const v2 = try self.rts_map.cdt.findOrAddVertex(end, tolerance);
            //                 _ = try self.rts_map.cdt.insertConstraintEdge(v1, v2);
            //                 // 插入约束边
            //                 _ = try self.rts_map.cdt.insertConstraintEdge(v1, v2);
            //                 // 更新渲染缓冲区
            //                 try self.rts_map.updateMeshBuffers();
            //             }
            //         }
            //         // 清除状态
            //         self.constraint_start = null;
            //     }
            // }
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
    self.rts_map.deinit();

    for (self.buildings.items) |*building|
        building.deinit(self.allocator);
    self.buildings.deinit(self.allocator);
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
