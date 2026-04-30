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
block_world: BlockWorld.BlockWorld,

// 开始游戏
pub fn start(self: *Game) !void {
    var main_menu = @import("ui/main_menu.zig"){};

    // 创建玩家实体
    const player_entity = self.registry.create();
    self.registry.add(player_entity, Comps.Player{ .id = self.player_id });
    self.registry.add(player_entity, Comps.Position{ .vec = Vec3.new(8, 130, 8) });
    self.registry.add(player_entity, Comps.Velocity{ .vec = Vec3.zero });
    self.registry.add(player_entity, Comps.Collider{});
    self.registry.add(player_entity, Comps.MoveSpeed{ .value = 4.0 });
    self.registry.add(player_entity, Comps.JumpVelocity{ .value = 8.0 });
    self.registry.add(player_entity, Comps.OnGround{ .value = false });
    self.registry.add(player_entity, Comps.MoveIntent{});

    // 加载初始区块
    {
        const player_sx: i32 = @intFromFloat(@floor(8.0));
        const player_sz: i32 = @intFromFloat(@floor(8.0));
        const chunk_size_x: i32 = @intCast(BlockWorld.CHUNK_SIZE_X);
        const chunk_size_z: i32 = @intCast(BlockWorld.CHUNK_SIZE_Z);
        const pcx = @divFloor(player_sx, chunk_size_x);
        const pcz = @divFloor(player_sz, chunk_size_z);
        const range: i32 = 1;
        var dx: i32 = -range;
        while (dx <= range) : (dx += 1) {
            var dz: i32 = -range;
            while (dz <= range) : (dz += 1) {
                try self.block_world.loadChunk(.new((pcx + dx) * chunk_size_x, 0, (pcz + dz) * chunk_size_z));
            }
        }
    }

    // 测试用静态模型实体
    const e2 = self.registry.create();
    self.registry.add(e2, Comps.ModelName{ .string = "CesiumMan" });
    self.registry.add(e2, Comps.Position{ .vec = Vec3.new(8, 100, 8) });
    self.registry.add(e2, Comps.Velocity{ .vec = Vec3.zero });
    self.registry.add(e2, Comps.Collider{});
    self.registry.add(e2, Comps.MoveSpeed{ .value = 4.0 });
    self.registry.add(e2, Comps.JumpVelocity{ .value = 8.0 });
    self.registry.add(e2, Comps.OnGround{ .value = false });
    self.registry.add(e2, Comps.MoveIntent{});

    const e3 = self.registry.create();
    self.registry.add(e3, Comps.ModelName{ .string = "CesiumMan" });
    self.registry.add(e3, Comps.Position{ .vec = .new(0, 2, 0) });

    // 主循环
    while (!self.window.shouldClose()) {
        self.input.beginFrame();
        self.window.pollEvents();
        if (!main_menu.visible) {
            // 1. 输入 -> MoveIntent
            produceMoveIntent(self);
            // 2. 物理
            self.block_world.updatePhysics(&self.registry, self.window.delta_time);
            // 3. 摄像机同步
            syncCameraFromPlayer(self);

            // 4. 动态加载/卸载区块
            try updateChunks(self);

            if (self.input.isMouseButtonDown(.mouse_left)) {
                try tryBreakBlock(self); // 左键破坏
            }
            if (self.input.isMouseButtonDown(.mouse_right)) {
                try tryPlaceBlock(self); // 右键放置
            }
        }
        self.ui_system.beginFrame();
        main_menu.update(self);
        try self.ui_system.endFrame(&self.gctx);
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
    self.block_world = try BlockWorld.BlockWorld.init(self.allocator, &self.gctx, &self.render_pipeline);

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
    self.registry.deinit();
    self.ui_system.deinit();
    self.block_world.deinit();
}

fn produceMoveIntent(self: *Game) void {
    var view = self.registry.view(.{ Comps.Player, Comps.MoveIntent }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const player = view.get(Comps.Player, entity);
        if (player.id != self.player_id) continue;
        var intent = view.get(Comps.MoveIntent, entity);

        var move_dir = Vec3.zero;
        const front_h = Vec3.new(self.camera.front.x, 0, self.camera.front.z).norm();
        const right_h = Vec3.new(
            self.camera.front.cross(self.camera.up).x,
            0,
            self.camera.front.cross(self.camera.up).z,
        ).norm();

        if (self.input.isKeyPressed(.w)) move_dir = move_dir.add(front_h);
        if (self.input.isKeyPressed(.s)) move_dir = move_dir.sub(front_h);
        if (self.input.isKeyPressed(.a)) move_dir = move_dir.sub(right_h);
        if (self.input.isKeyPressed(.d)) move_dir = move_dir.add(right_h);

        if (self.input.isKeyPressed(.space)) {
            intent.jump = true; // 物理系统会根据地面/水中决定行为
            move_dir.y = 1.0; // 水中上浮指示符
        }
        if (self.input.isKeyPressed(.left_control) or self.input.isKeyPressed(.right_control)) {
            move_dir.y = -1.0; // 水中下潜指示符
        }

        if (move_dir.len2() > 0.001) move_dir = move_dir.norm();
        intent.direction = move_dir;
    }
}

fn syncCameraFromPlayer(self: *Game) void {
    var view = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const player = view.get(Comps.Player, entity);
        if (player.id == self.player_id) {
            const pos = view.get(Comps.Position, entity);
            const eye_offset = Vec3.new(0, 1.6, 0);
            self.camera.position = pos.vec.add(eye_offset);
            self.camera.updateFromMouse(self);
            self.ubo.camera_pos = self.camera.position;
            break;
        }
    }
}

fn tryBreakBlock(self: *Game) !void {
    const ray = self.camera.getCursorRay();
    const hit = Raycast.raycastWorld(&self.block_world, ray, 8.0);
    if (hit.hit) {
        try self.block_world.setBlock(hit.block_pos, .fromName("air"));
    }
}

fn tryPlaceBlock(self: *Game) !void {
    const ray = self.camera.getCursorRay();
    const hit = Raycast.raycastWorld(&self.block_world, ray, 8.0);
    if (!hit.hit) return;

    const place_pos = Vec3i.new(
        hit.block_pos.x + hit.face_normal.x,
        hit.block_pos.y + hit.face_normal.y,
        hit.block_pos.z + hit.face_normal.z,
    );

    // 检查目标位置的块是否已有方块
    if (self.block_world.getBlockAt(Vec3.new(
        @as(f32, @floatFromInt(place_pos.x)) + 0.5,
        @as(f32, @floatFromInt(place_pos.y)) + 0.5,
        @as(f32, @floatFromInt(place_pos.z)) + 0.5,
    )) != BlockWorld.BlockId.fromName("air")) return;

    // 放置方块的 AABB
    const block_box = BlockWorld.AABB{
        .min_x = @floatFromInt(place_pos.x),
        .max_x = @floatFromInt(place_pos.x + 1),
        .min_y = @floatFromInt(place_pos.y),
        .max_y = @floatFromInt(place_pos.y + 1),
        .min_z = @floatFromInt(place_pos.z),
        .max_z = @floatFromInt(place_pos.z + 1),
    };

    // 检查是否与任何有碰撞体积的实体重叠
    var view = self.registry.view(.{ Comps.Position, Comps.Collider }, .{});
    var iter = view.entityIterator();
    var can_place = true;
    while (iter.next()) |entity| {
        const pos = view.get(Comps.Position, entity);
        const collider = view.get(Comps.Collider, entity);
        const half_w = collider.width / 2.0;
        const entity_box = BlockWorld.AABB{
            .min_x = pos.vec.x - half_w,
            .max_x = pos.vec.x + half_w,
            .min_y = pos.vec.y,
            .max_y = pos.vec.y + collider.height,
            .min_z = pos.vec.z - half_w,
            .max_z = pos.vec.z + half_w,
        };
        if (entity_box.min_x < block_box.max_x and entity_box.max_x > block_box.min_x and
            entity_box.min_y < block_box.max_y and entity_box.max_y > block_box.min_y and
            entity_box.min_z < block_box.max_z and entity_box.max_z > block_box.min_z)
        {
            can_place = true;
            break;
        }
    }

    if (!can_place) return;

    try self.block_world.setBlock(place_pos, .fromName("foo"));
}

fn updateChunks(self: *Game) !void {
    var view = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const player = view.get(Comps.Player, entity);
        if (player.id != self.player_id) continue;
        const pos = view.get(Comps.Position, entity);

        const chunk_size_x: i32 = @intCast(BlockWorld.CHUNK_SIZE_X);
        const chunk_size_z: i32 = @intCast(BlockWorld.CHUNK_SIZE_Z);
        const pcx = @divFloor(@as(i32, @intFromFloat(@floor(pos.vec.x))), chunk_size_x);
        const pcz = @divFloor(@as(i32, @intFromFloat(@floor(pos.vec.z))), chunk_size_z);

        const load_range: i32 = 5;
        var dx: i32 = -load_range;
        while (dx <= load_range) : (dx += 1) {
            var dz: i32 = -load_range;
            while (dz <= load_range) : (dz += 1) {
                try self.block_world.loadChunk(.new((pcx + dx) * chunk_size_x, 0, (pcz + dz) * chunk_size_z));
            }
        }

        // 卸载远处区块
        var to_unload = std.ArrayListUnmanaged(Vec3i){};
        defer to_unload.deinit(self.allocator);
        var chunk_it = self.block_world.chunks.keyIterator();
        while (chunk_it.next()) |key| {
            const kcx = @divFloor(key.x, chunk_size_x);
            const kcz = @divFloor(key.z, chunk_size_z);
            const dist = @max(@abs(pcx - kcx), @abs(pcz - kcz));
            if (dist > load_range + 2) {
                to_unload.append(self.allocator, key.*) catch continue;
            }
        }
        for (to_unload.items) |key| {
            self.block_world.unloadChunk(key);
        }
        break;
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
const Vec3i = Algebra.Vec3i;
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

const BlockWorld = @import("block_world.zig");
