const io = @import("imports.zig").io;
const winsock = @import("winsock.zig");
// game.zig
//
// ⚠️ 重要：Zig 的 allocator.create() 不应用结构体字段默认值。
//    所有 `= default_value` 的字段都必须在 init() 中显式初始化，
//    否则字段值为内存垃圾（不是默认值）。
//    已在此踩坑的字段：player_id, remote_player, flying, network_mode
//    新增字段时务必检查 init() 是否有对应初始化。
const Algebra = @import("algebra.zig");
const Gctx = @import("gctx.zig");
const Window = @import("window.zig");
const Render = @import("render.zig");
const Camera3D = @import("camera3d.zig");
const RenderPipeline = @import("render_pipeline.zig");
const UiSystem = @import("ui_system.zig");
const Input = @import("input.zig");
const ECS = @import("zigecs");
const RendCTX = @import("rend_ctx.zig");
const Comps = @import("components.zig").Components;
const Wgpu = @import("imports.zig").Wgpu;
const Glfw = @import("imports.zig").Glfw;
const Gltf = @import("imports.zig").Gltf;
const Vec3 = @import("algebra.zig").Vec3;
const ResManager = @import("rend_ctx.zig").ResManager;
const Model = @import("rend_ctx.zig").Model;
const SceneUniform = @import("rend_ctx.zig").SceneUniform;

allocator: std.mem.Allocator,
window: Window,
gctx: Gctx,
input: Input,
server: Server,
ui_system: UiSystem,
res_manager: ResManager,
wireframe_pipeline: WireframePipeline,
render_pipeline: RenderPipeline,
sky_pipeline: SkyPipeline,
shadow_pipeline: ShadowPipeline,
camera: Camera3D,
ubo: SceneUniform,
player_name: []const u8 = "", // 当前用户名
hotbar: Hotbar,
inventory: PlayerInventory = .{},
selected_item: ?SelectedItem = null,
save_manager: SaveManager,
icon_atlas: IconAtlas,
accumulator: f32 = 0, // 物理 tick 时间余量，用于渲染插值
frame_timer: std.Io.Timestamp, // 帧计时器，独立于 GLFW
fps_buffer: [120]f32 = undefined, // 2 秒 FPS 窗口
fps_idx: u32 = 0,
fps_avg: f32 = 0,
keybinds: Keybinds,
save_initialized: bool = false, // 延迟初始化：选存档后才加载游戏
game_cleaned: bool = false, // returnToMenu 已清理 gameplay 资源，阻止 deinit 重复释放
menu_state: MenuState = .MainMenu,

// 联机网络
network_mode: NetworkMode = .single,
listen_fd: winsock.socket_t = undefined,
net_listening: bool = false, // listen_fd 是否有效

clients: std.ArrayListUnmanaged(ClientInfo) = .empty,
next_player_id: u32 = 1,

client_fd: winsock.socket_t = undefined, // 客机端：主机 fd
client_connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
remote_player: ?ECS.Entity = null, // 客机端：自身玩家实体
snapshot_info: std.AutoHashMapUnmanaged(u64, struct { entity: ECS.Entity, player_id: u32 }) = .{}, // 客机端：快照索引→(实体, player_id)
net_thread: ?std.Thread = null,
net_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
net_mutex: std.Io.Mutex = .init, // 保护 net_cam_yaw/pitch
net_saved_client_pos: Vec3 = Vec3.zero, // 客机断线时保存的位置（重连后恢复）
server_wants_fly: bool = false, // 主循环检测到双击空格后设置，collectPlayerInput 消费
fly_timer: f64 = 0, // 飞行双击计时器（用真实帧时间递减）
break_once: bool = false, // 鼠标左键单击标志
place_once: bool = false, // 鼠标右键单击标志
net_cam_yaw: f32 = 0, // 主机相机的朝向（给网络线程读）
net_cam_pitch: f32 = 0,
last_snapshot_serial: u64 = std.math.maxInt(u64),

/// 渲染用快照缓冲区（主线程独有，无竞态，主机/客机共用）
render_snapshots: [64]Network.EntitySnapshot = undefined,
render_snapshot_count: u32 = 0,
host_snap_valid: bool = false,

/// 上次快照到达时间（实体 time-alpha 用）
last_snapshot_time_ns: i64 = 0,

/// DEBUG: 客机统计
chunk_count: u64 = 0,
state_count: u64 = 0,
noop_count: u64 = 0,
state_serial_last: u32 = 0,
state_serial_gaps: u64 = 0,
latency_min_ns: i64 = 999_999_999,
latency_max_ns: i64 = 0,
latency_sum_ns: i64 = 0,
latency_samples: u64 = 0,
_tick_start_ns: i64 = 0,
_last_latency_print: u64 = 0,

// 开始游戏
pub fn start(self: *Game) !void {
    var main_menu = @import("ui/main_menu.zig"){};
    var save_menu = @import("ui/save_menu.zig"){};
    var pause_menu = @import("ui/pause_menu.zig"){};

    // 主循环（仅菜单，游戏初始化推迟到选存档后）
    while (!self.window.shouldClose()) {
        self.input.beginFrame();
        self.window.pollEvents();

        self.icon_atlas.reset();
        self.ui_system.beginFrame();

        switch (self.menu_state) {
            .MainMenu => {
                const prev = self.menu_state;
                main_menu.update(self);
                if (self.menu_state != prev and self.menu_state == .SaveSelect)
                    save_menu.refresh(self.allocator);
            },
            .SaveSelect => save_menu.update(self),
            .Gameplay => {
                if (self.keybinds.isJustPressed(&self.input, .pause_menu))
                    self.menu_state = .Pause;
                if (self.keybinds.isJustPressed(&self.input, .toggle_inventory))
                    self.menu_state = .Inventory;

                // - 时间倒退 0.5 小时，= 时间前进 0.5 小时
                if (self.input.isKeyJustPressed(.minus)) {
                    const half_hour = @as(u64, @intFromFloat(self.sky_pipeline.day_length / TICK_DT / 48));
                    self.server.tick_count -|= half_hour;
                    self.accumulator = 0;
                }
                if (self.input.isKeyJustPressed(.equal)) {
                    const half_hour = @as(u64, @intFromFloat(self.sky_pipeline.day_length / TICK_DT / 48));
                    self.server.tick_count += half_hour;
                    self.accumulator = 0;
                }
            },
            .Inventory => {
                if (self.keybinds.isJustPressed(&self.input, .pause_menu) or self.keybinds.isJustPressed(&self.input, .toggle_inventory)) {
                    self.selected_item = null;
                    self.menu_state = .Gameplay;
                    self.input.setCursorToCenter();
                }
                @import("ui/inventory_screen.zig").update(self);
                @import("ui/inventory_screen.zig").drawBg(self);
            },
            .Pause => pause_menu.update(self),
        }

        // 游戏初始化后才运行物理和渲染
        if (self.save_initialized) {
            const now = std.Io.Timestamp.now(io, .awake);
            const dt_ns = now.nanoseconds - self.frame_timer.nanoseconds;
            self.frame_timer = now;
            const dt = @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000.0;
            self.fps_buffer[self.fps_idx] = dt;
            self.fps_idx = (self.fps_idx + 1) % 120;
            {
                var sum: f32 = 0;
                for (&self.fps_buffer) |t| {
                    sum += t;
                }
                self.fps_avg = @as(f32, @floatFromInt(120)) / sum;
            }
            self.accumulator += dt;
            if (self.accumulator > TICK_DT * 5) self.accumulator = TICK_DT * 5;

            if (self.accumulator >= TICK_DT) {
                // 保存 prev=vec（客机相机 lerp 用）
                if (self.network_mode == .client) {
                    var pv = self.server.registry.view(.{Comps.Position}, .{});
                    var pi = pv.entityIterator();
                    while (pi.next()) |e| {
                        var p = pv.get(e);
                        p.prev = p.vec;
                    }
                }
                // 骨骼矩阵 double buffer 交换
                self.server.animation_system.swapBuffers();
            }

            while (self.accumulator >= TICK_DT) {
                self.accumulator -= TICK_DT;
                if (self.menu_state != .Pause or self.network_mode != .single) {
                    if (self.network_mode == .client) {
                        try self.clientTick(); // 30Hz 发输入
                    } else {
                        try self.tick();
                    }
                }
            }
            // 客机：每帧收包，不等 30Hz tick
            if (self.network_mode == .client and self.save_initialized and self.client_connected.load(.acquire)) {
                self.clientReceivePackets();
            }
            // 如果 tick 内触发了 returnToMenu，跳过当前帧
            if (!self.save_initialized) continue;

            // 根据水平速度更新实体朝向（跳过远程玩家，其朝向来自客机输入）
            {
                var fv = self.server.registry.view(.{ Comps.Velocity, Comps.Facing }, .{});
                var fi = fv.entityIterator();
                while (fi.next()) |entity| {
                    // 跳过客机玩家（player_id=1），其朝向由客机鼠标控制
                    if (self.server.registry.tryGet(Comps.Player, entity)) |p| {
                        if (p.id != self.server.player_id) continue;
                    }
                    const vel = fv.get(Comps.Velocity, entity);
                    const facing = fv.get(Comps.Facing, entity);
                    const h_speed = @sqrt(vel.vec.x * vel.vec.x + vel.vec.z * vel.vec.z);
                    if (h_speed > 0.01) {
                        facing.yaw = std.math.atan2(vel.vec.x, vel.vec.z); // atan2 返回弧度
                    }
                }
            }

            if (self.menu_state == .Gameplay or self.menu_state == .Inventory or (self.menu_state == .Pause and self.network_mode != .single)) {
                // 骨骼矩阵插值并上传到 GPU（多人模式下暂停时也不停止）
                self.server.animation_system.upload(self.gctx.queue, self.accumulator / TICK_DT);
                if (self.network_mode != .client) {
                    self.pollServerSnapshot();
                    syncCameraFromPlayer(self);
                } else {
                    syncCameraFromPlayer(self);
                }
            }

            if (self.menu_state == .Gameplay) {
                self.camera.updateFromMouse(self);

                // DEBUG: 每 ~3 秒打印一次客机延迟统计（仅打印一次，防止重复）
                if (self.network_mode == .client and self.state_count > 0 and self.state_count % 90 == 0 and self._last_latency_print != self.state_count) {
                    self._last_latency_print = self.state_count;
                    const avg_ns = if (self.latency_samples > 0) @divTrunc(self.latency_sum_ns, @as(i64, @intCast(self.latency_samples))) else 0;
                    Log.info("[LATENCY] states={d} chunks={d} gaps={d}  min={d}us avg={d}us max={d}us", .{
                        self.state_count,
                        self.chunk_count,
                        self.state_serial_gaps,
                        @divTrunc(self.latency_min_ns, 1000),
                        @divTrunc(avg_ns, 1000),
                        @divTrunc(self.latency_max_ns, 1000),
                    });
                }
                // 飞行切换（每帧检测，不依赖 tick）
                if (self.input.isKeyJustPressed(.space)) {
                    if (self.fly_timer > 0 and self.fly_timer < 0.4) {
                        self.server_wants_fly = true;
                        self.fly_timer = 0;
                    } else if (self.fly_timer <= 0) {
                        self.fly_timer = 0.3;
                    }
                }
                if (self.fly_timer > 0) {
                    self.fly_timer -= self.window.delta_time;
                    if (self.fly_timer < 0) self.fly_timer = 0;
                }

                if (self.keybinds.isJustPressed(&self.input, .sprint_toggle))
                    self.server.sprint_toggled = !self.server.sprint_toggled;
                // 主机玩家的 break/place 由服务端线程处理（通过 PlayerInput）
                // 主循环只做边缘检测并设置标志
                self.break_once = self.break_once or self.keybinds.isJustPressed(&self.input, .break_block);
                self.place_once = self.place_once or self.keybinds.isJustPressed(&self.input, .place_block);

                // - 时间倒退 0.5 小时，= 时间前进 0.5 小时
                if (self.input.isKeyJustPressed(.minus)) {
                    const half_hour = @as(u64, @intFromFloat(self.sky_pipeline.day_length / TICK_DT / 48));
                    self.server.tick_count -|= half_hour;
                    self.accumulator = 0;
                }
                if (self.input.isKeyJustPressed(.equal)) {
                    const half_hour = @as(u64, @intFromFloat(self.sky_pipeline.day_length / TICK_DT / 48));
                    self.server.tick_count += half_hour;
                    self.accumulator = 0;
                }
            }
        }

        if (self.save_initialized and (self.menu_state == .Gameplay or self.menu_state == .Inventory)) {
            self.handleHotbarInput();
            self.ui_system.drawHotbarBg(&self.hotbar);
        }
        // 下层（背景）→ 分层 → 上层（图标+文字）
        self.ui_system.splitLayer();
        if (self.save_initialized and (self.menu_state == .Gameplay or self.menu_state == .Inventory)) {
            self.ui_system.drawHotbarFg(&self.hotbar, &self.icon_atlas);
        }
        if (self.menu_state == .Inventory) {
            @import("ui/inventory_screen.zig").drawFg(self);
        }
        if (self.selected_item) |sel| {
            const pos = self.input.getCursorPos();
            if (self.icon_atlas.getOrLoad(sel.item.item_id)) |slot_i| {
                self.icon_atlas.addQuad(IconAtlas.slotUV(slot_i), pos.x - 16, pos.y - 16, 32);
            }
        }
        // 显示 FPS（右上角）
        if (self.save_initialized) {
            var fps_buf: [32]u8 = undefined;
            const fps_str = std.fmt.bufPrint(&fps_buf, "FPS: {d:.1}", .{self.fps_avg}) catch "FPS: ?";
            const screen_w = @as(f32, @floatFromInt(self.gctx.surface_config.width));
            const text_w = self.ui_system.measureText(&self.gctx, fps_str, 24);
            self.ui_system.drawText(&self.gctx, screen_w - text_w - 8, 8, fps_str, 24, .{ 1, 1, 1, 1 });
        }
        try self.ui_system.endFrame(&self.gctx);
        if (self.save_initialized) {
            try self.server.block_world.processCompletedBuilds();
            try self.server.block_world.processCompletedLoads();
            self.server.block_world.processCompletedSaves();
            Render.draw(self);
        } else if (self.ui_system.index_count > 0) {
            Render.drawUI(self);
        }
    }
    save_menu.deinit(self.allocator);
}

/// 重建投影矩阵。窗口缩放后调用。
pub fn rebuildProjMatrix(self: *Game) void {
    const aspect = self.window.width / self.window.height;
    const far = @as(f32, @floatFromInt(self.server.chunk_radius)) * @as(f32, @floatFromInt(BlockWorld.CHUNK_WIDTH)) * 1.5 + BlockWorld.CHUNK_WIDTH * 4;
    self.ubo.proj_matrix = Mat4.perspectiveReversedZ(70, aspect, 0.01, far);
}

/// 选存档后初始化游戏世界（玩家实体、区块、存档数据）
fn initGame(self: *Game) !void {
    // 默认出生点 (0, getSurfaceY(0,0), 0)，存档有保存位置则后续覆盖
    const default_y = if (self.server.block_world.getSurfaceY(0, 0)) |y| @as(f32, @floatFromInt(y)) else 130;
    const default_spawn = Vec3.new(0, default_y, 0);

    const player_entity = self.server.registry.create();
    self.server.registry.add(player_entity, Comps.Player{ .id = self.server.player_id, .mode = .creative });
    self.server.registry.add(player_entity, Comps.Position{ .vec = default_spawn, .prev = Vec3.zero });
    if (self.server.registry.tryGet(Comps.Position, player_entity)) |pp| pushEntityPos(pp, default_spawn);
    self.server.registry.add(player_entity, Comps.Velocity{ .vec = Vec3.zero });
    self.server.registry.add(player_entity, Comps.Collider{ .width = 0.6, .height = 1.8 });
    self.server.registry.add(player_entity, Comps.MoveSpeed{ .value = 4.0 });
    self.server.registry.add(player_entity, Comps.JumpVelocity{ .value = 14.0 });
    self.server.registry.add(player_entity, Comps.OnGround{ .value = false });
    self.server.registry.add(player_entity, Comps.Facing{});
    self.server.registry.add(player_entity, Comps.MoveIntent{});
    self.server.registry.add(player_entity, Comps.Health{ .current = 100, .max = 100 });
    self.server.registry.add(player_entity, Comps.SpawnPos{ .pos = default_spawn });

    // 玩家模型（统一实体类型，主机客机都能看见对方）
    const pinfo = EntityTypeId.fromName("player").info();
    self.server.registry.add(player_entity, Comps.ModelName{ .id = pinfo.model_id });

    // 先恢复玩家存档位置（如果有存档）--- 必须在加载区块之前
    // 原因：区块需要围绕玩家实际所在位置加载，而不是硬编码的 (8,8)。
    // 如果调换顺序，玩家位置附近的区块未加载 → getBlockAt 全返回 air → 自由落体。
    if (try self.save_manager.loadPlayer(self.player_name, &self.hotbar, &self.inventory, &self.server.registry)) |tc| {
        self.server.tick_count = tc;
    }

    // 以玩家实际位置为中心加载区块
    {
        const player_center: Vec3 = blk: {
            var pv = self.server.registry.view(.{ Comps.Player, Comps.Position }, .{});
            var pi = pv.entityIterator();
            if (pi.next()) |entity| {
                const p = pv.get(Comps.Player, entity);
                if (p.id == self.server.player_id) {
                    break :blk pv.get(Comps.Position, entity).vec;
                }
            }
            break :blk default_spawn;
        };
        const player_origin = BlockWorld.BlockWorld.chunkOrigin(
            @intFromFloat(@floor(player_center.x)),
            @intFromFloat(@floor(player_center.z)),
        );
        const load_range: i32 = self.server.chunk_radius;
        const load_range_sq = load_range * load_range;
        var dx: i32 = -load_range;
        while (dx <= load_range) : (dx += 1) {
            var dz: i32 = -load_range;
            while (dz <= load_range) : (dz += 1) {
                if (dx * dx + dz * dz > load_range_sq) continue;
                try self.server.block_world.loadChunk(.new(
                    player_origin.x + dx * BlockWorld.CHUNK_WIDTH_I32,
                    0,
                    player_origin.z + dz * BlockWorld.CHUNK_WIDTH_I32,
                ));
            }
        }
    }

    // 同步等待所有异步 IO + mesh 构建完成
    // pollEvents 确保加载期间窗口仍可拖拽缩放，不会被 Windows 标记为"无响应"
    {
        const Loading = @import("ui/loading_screen.zig");
        var last_pending: usize = 0;
        while (self.server.block_world.pendingIOCount() > 0 or self.server.block_world.pendingCount() > 0) {
            self.window.pollEvents();
            self.server.block_world.processCompletedLoads() catch {};
            self.server.block_world.processCompletedBuilds() catch {};
            self.server.block_world.processCompletedSaves();
            std.Thread.yield() catch {};
            const cur = self.server.block_world.pendingIOCount();
            if (cur != last_pending) {
                last_pending = cur;
                self.ui_system.beginFrame();
                Loading.draw(self);
                self.ui_system.endFrame(&self.gctx) catch {};
                Render.drawUI(self);
            }
        }
    }

    // 新存档：把玩家放到地面上（区块已加载）
    {
        var pv = self.server.registry.view(.{ Comps.Player, Comps.Position }, .{});
        var pi = pv.entityIterator();
        if (pi.next()) |entity| {
            const pos = pv.get(Comps.Position, entity);
            const sx: i32 = @intFromFloat(@floor(pos.vec.x));
            const sz: i32 = @intFromFloat(@floor(pos.vec.z));
            if (self.server.block_world.getSurfaceY(sx, sz)) |y| {
                pos.vec.y = @as(f32, @floatFromInt(y));
                pos.prev.y = pos.vec.y;
            }
        }
    }

    {
        var view = self.server.registry.view(.{ Comps.Player, Comps.Flying }, .{});
        var iter = view.entityIterator();
        if (iter.next()) |_| self.server.flying = true;
    }

    self.save_manager.loadAllEntities(&self.server.registry) catch |err| std.debug.print("loadEntities error: {}\n", .{err});

    // 为存档加载的实体补加动画状态
    {
        var anim_view = self.server.registry.view(.{Comps.ModelName}, .{});
        var anim_iter = anim_view.entityIterator();
        while (anim_iter.next()) |ent| {
            if (!self.server.registry.has(Comps.AnimationState, ent)) {
                if (self.server.animation_system.allocBoneSlot()) |bone_offset| {
                    self.server.registry.add(ent, Comps.AnimationState{
                        .clip_name = @import("rend_ctx.zig").ClipName.walk,
                        .bone_offset = bone_offset,
                    });
                }
            }
        }
    }

    // 启动服务端线程（单人/主机的物理、AI、动画）
    try self.server.start(&self.res_manager);

    // 联机模式：启动网络线程
    if (self.network_mode == .host) {
        self.net_running.store(true, .release);
        self.net_thread = try std.Thread.spawn(.{}, hostNetworkThread, .{self});
    }

    self.save_initialized = true;
}

pub fn init(allocator: std.mem.Allocator) !*@This() {
    if (@import("builtin").os.tag == .windows) winsock.startup();
    var self = try allocator.create(@This());
    self.allocator = allocator;
    self.server = Server.init(allocator);
    self.net_mutex = .init;
    self.network_mode = .single;
    self.net_saved_client_pos = Vec3.zero;
    self.net_thread = null;
    self.clients = .empty;
    self.next_player_id = 1;
    self.remote_player = null;
    self.snapshot_info = .{};
    self.server.player_id = 0;
    self.server.flying = false;

    self.last_snapshot_serial = std.math.maxInt(u64);
    self.host_snap_valid = false;
    self.render_snapshot_count = 0;
    self.last_snapshot_time_ns = 0;
    // 创建窗口
    const window = try Window.init(self, "ZBlock", 1280, 720);
    self.window = window;

    // 初始化输入系统
    const input = Input.init(self);
    self.input = input;
    self.frame_timer = std.Io.Timestamp.now(io, .awake);
    self.fps_idx = 0;

    // 初始化wgpu
    const gctx = try Gctx.init(self.window);
    self.gctx = gctx;

    // 初始化噪声系统
    const noise = @import("noise.zig");
    noise.init(99);

    // 初始化资源管理器
    const res_manager = try ResManager.init(allocator, &self.gctx, &self.render_pipeline);
    self.res_manager = res_manager;

    // 阴影管线（方向光 shadow map）
    self.shadow_pipeline = try ShadowPipeline.init(&self.gctx);

    // 创建渲染管线
    self.render_pipeline = try RenderPipeline.init(
        self,
        "resources/shaders/render_shader.wgsl",
    );

    // 将阴影深度贴图 + 比较采样器绑定到渲染管线 group 2
    const shadow_bind_group = Wgpu.wgpuDeviceCreateBindGroup(self.gctx.device, &.{
        .layout = self.render_pipeline.shadow_bgl,
        .entryCount = 2,
        .entries = &[_]Wgpu.WGPUBindGroupEntry{
            .{ .binding = 0, .textureView = self.shadow_pipeline.depth_texture_view },
            .{ .binding = 1, .sampler = self.shadow_pipeline.depth_sampler },
        },
    });
    self.render_pipeline.setShadowBindGroup(shadow_bind_group);

    // 线框管线（调试用）
    self.wireframe_pipeline = try WireframePipeline.init(
        self,
        "resources/shaders/wireframe_shader.wgsl",
    );

    // 程序化天空
    self.sky_pipeline = try SkyPipeline.init(&self.gctx, 42);

    // 初始化摄像头
    self.camera = Camera3D.init(self);
    // 初始化ubo
    self.ubo = SceneUniform.init(self.window);
    // 初始化世界
    const registry = ECS.Registry.init(allocator);
    self.server.registry = registry;
    // 初始化UI系统
    const ui_system = try UiSystem.init(allocator, &self.gctx, self, "resources/fonts/wqy-microhei.ttc");
    self.ui_system = ui_system;

    // 物品栏
    self.hotbar = .{};
    self.inventory = .{};
    self.selected_item = null;

    // 按键绑定（加载配置文件，不存在则使用默认值）
    self.keybinds = try Keybinds.load(allocator, "config/keybinds.json");
    self.menu_state = .MainMenu;

    // 注册表哈希表（运行时名称查找用）
    registries.init(allocator);

    // 初始化动画系统
    self.server.animation_system = try AnimationSystem.init(allocator, self.gctx.device);

    // 为渲染管线设置骨骼矩阵缓冲
    self.render_pipeline.setBoneBuffer(self, self.server.animation_system.bone_pool_buffer);

    // 图标缓存 + 图标管线（传入 uniform 缓冲）
    self.icon_atlas = try IconAtlas.init(allocator, &self.gctx, self.ui_system.uniform_buffer);
    // 存档系统、BlockWorld、worker 线程在用户选择存档后才初始化（initGame/startSave）

    // 生成随机用户名（每次启动不同，避免联机重名）
    {
        var rand_buf: [4]u8 = undefined;
        io.random(&rand_buf);
        const suffix = std.mem.readInt(u32, &rand_buf, .little) % 10000;
        self.player_name = try std.fmt.allocPrint(allocator, "user_{d}", .{suffix});
    }

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
    self.shadow_pipeline.deinit();
    self.sky_pipeline.deinit();
    self.wireframe_pipeline.deinit();
    self.ui_system.deinit();
    if (self.player_name.len > 0) self.allocator.free(self.player_name);
    self.icon_atlas.deinit();

    if (!self.game_cleaned and self.save_initialized and self.network_mode != .client) {
        self.save_manager.savePlayer(self.player_name, &self.hotbar, &self.inventory, &self.server.registry, self.server.tick_count) catch |err| std.debug.print("savePlayer error: {}\n", .{err});
        self.save_manager.saveAllEntities(&self.server.registry) catch |err| std.debug.print("saveEntities error: {}\n", .{err});
        self.save_manager.saveAllChunks(&self.server.block_world) catch |err| std.debug.print("saveChunks error: {}\n", .{err});
        {
            var view = self.server.registry.view(.{Comps.AIAgent}, .{});
            var iter = view.entityIterator();
            while (iter.next()) |entity| {
                self.server.block_world.cleanupEntity(&self.server.registry, entity);
            }
        }
        self.server.block_world.deinit();
        self.save_manager.deinit();
    }
    self.server.deinit();
    self.server.animation_system.deinit();
    registries.deinit(self.allocator);
}

/// 切换存档（由存档管理界面调用）
pub fn startSave(self: *Game, name: []const u8) !void {
    Log.info("startSave begin '{s}'", .{name});
    self.server.chunk_radius = 4;
    rebuildProjMatrix(self);
    self.save_manager = try SaveManager.init(self.allocator, name);
    // 如果是从 returnToMenu 回来的，Server 已经被重建，只需要重建 BlockWorld
    self.server.block_world = try BlockWorld.BlockWorld.init(self.allocator, &self.gctx, &self.render_pipeline, self.server.chunk_radius, name);
    try self.server.block_world.spawnWorker();
    try self.server.block_world.spawnAStarWorker();
    try self.server.block_world.spawnSaveWorker();
    self.hotbar = .{};
    self.inventory = .{};
    self.game_cleaned = false;

    self.last_snapshot_serial = std.math.maxInt(u64);
    self.host_snap_valid = false;
    try self.initGame();
}

/// 联机客户端模式：不加载存档，只连接主机（极小化，跳过 ECS 避免崩溃）
pub fn startClient(self: *Game, host_ip: [4]u8) !void {
    self.game_cleaned = false;

    self.last_snapshot_serial = std.math.maxInt(u64);
    self.host_snap_valid = false;
    self.server.chunk_radius = 4;
    self.network_mode = .client;

    self.net_thread = null;
    self.net_running.store(true, .release);
    self.client_connected.store(false, .release);
    self.client_fd = undefined;

    const cfd = Network.connect(host_ip, Network.SERVER_PORT);
    if (cfd < 0) {
        Log.info("connect failed", .{});
        return;
    }
    self.client_fd = cfd;
    self.client_connected.store(true, .release);

    // 接收 welcome 消息，获取分配的 player_id
    const assigned_id = Network.recvWelcome(cfd);
    Log.info("recvWelcome raw={}\n", .{assigned_id});
    self.server.player_id = assigned_id;
    Log.info("connected as player_id={}", .{assigned_id});

    // 清空快照实体映射
    self.snapshot_info = .{};
    // DEBUG: 重置计数器
    self.state_count = 0;
    self.chunk_count = 0;
    self.noop_count = 0;
    self.state_serial_last = 0;
    self.state_serial_gaps = 0;
    self.latency_min_ns = 999_999_999;
    self.latency_max_ns = 0;
    self.latency_sum_ns = 0;
    self.latency_samples = 0;

    // 初始化空的 block_world（渲染需要）
    self.server.block_world = try BlockWorld.BlockWorld.init(self.allocator, &self.gctx, &self.render_pipeline, self.server.chunk_radius, "");

    // 启动 mesh worker（区块通过动态加载到达）
    self.server.block_world.spawnWorker() catch {};
    // 设置非阻塞超时
    Network.setRecvTimeout(@as(winsock.socket_t, @intCast(self.client_fd)));

    // 创建本地玩家实体（第一人称，不可见，用于接收主机发回的自身位置）
    {
        const entity = self.server.registry.create();
        self.server.registry.add(entity, Comps.Player{ .id = self.server.player_id, .mode = .survival });
        self.server.registry.add(entity, Comps.Position{ .vec = Vec3.new(0, 130, 0), .prev = Vec3.new(0, 130, 0) });
        if (self.server.registry.tryGet(Comps.Position, entity)) |pp| pushEntityPos(pp, Vec3.new(0, 130, 0));
        self.server.registry.add(entity, Comps.Velocity{ .vec = Vec3.zero });
        self.server.registry.add(entity, Comps.Collider{ .width = 0.6, .height = 1.8 });
        self.server.registry.add(entity, Comps.MoveSpeed{ .value = 4.0 });
        self.server.registry.add(entity, Comps.JumpVelocity{ .value = 14.0 });
        self.server.registry.add(entity, Comps.OnGround{ .value = false });
        self.server.registry.add(entity, Comps.MoveIntent{});
        self.server.registry.add(entity, Comps.Facing{});
        self.remote_player = entity;
    }

    self.menu_state = .Gameplay;
    self.save_initialized = true;
    self.accumulator = TICK_DT; // 强制第一帧执行一次 clientTick，设置相机位置
}

/// 返回主菜单（由暂停菜单调用）
pub fn returnToMenu(self: *Game) void {
    Log.info("returnToMenu CALLED, mode={any}, save_initialized={}, menu_state={}", .{ self.network_mode, self.save_initialized, @intFromEnum(self.menu_state) });
    if (self.network_mode != .client) {
        self.save_manager.savePlayer(self.player_name, &self.hotbar, &self.inventory, &self.server.registry, self.server.tick_count) catch |err| std.debug.print("savePlayer error: {}\n", .{err});
        self.save_manager.saveAllEntities(&self.server.registry) catch |err| std.debug.print("saveEntities error: {}\n", .{err});
        self.save_manager.saveAllChunks(&self.server.block_world) catch |err| std.debug.print("saveChunks error: {}\n", .{err});
    }
    self.hotbar = .{};
    self.inventory = .{};
    // 停止网络线程
    if (self.net_thread) |t| {
        self.net_running.store(false, .release);
        if (self.net_listening) {
            self.net_listening = false;
            _ = winsock.closesocket(self.listen_fd);
        }
        t.join();
        self.net_thread = null;
    }
    // 关闭所有客户端连接
    for (self.clients.items) |c| _ = winsock.closesocket(c.fd);
    self.clients.deinit(self.allocator);
    self.clients = .empty;
    self.next_player_id = 1;
    self.render_snapshot_count = 0;
    self.last_snapshot_time_ns = 0;
    self.host_snap_valid = false;
    self.server.animation_system.next_bone_offset = 0;
    self.server.animation_system.max_bone_slot = 0;
    const was_client = self.network_mode == .client;
    self.network_mode = .single;
    self.client_connected.store(false, .release);

    // 客机：关闭 socket + 清理快照映射（主机由网络线程的 defer close 处理）
    if (was_client) {
        _ = winsock.closesocket(self.client_fd);
        self.snapshot_info.deinit(self.allocator);
        self.snapshot_info = .{};
    }
    self.client_fd = undefined;

    // 停止服务端线程
    self.server.stop();

    // 清理 AI 实体的寻路状态和路径内存（非客户端模式，此时 server 线程已停）
    if (self.network_mode != .client) {
        var view = self.server.registry.view(.{Comps.AIAgent}, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            self.server.block_world.cleanupEntity(&self.server.registry, entity);
        }
    }

    // 释放 gameplay 子系统
    self.server.block_world.deinit();
    self.server.input_queue.deinit(self.allocator);
    self.server.pending_chunks.deinit(self.allocator);
    self.server.pending_unloads.deinit(self.allocator);
    {
        var it = self.server.player_chunks.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
    }
    self.server.player_chunks.deinit(self.allocator);
    self.server.registry.deinit();
    // 重建 registry（zig-ecs handles 有 128B 泄漏，但不清空会导致实体残留）
    self.server.registry = ECS.Registry.init(self.allocator);
    self.server.input_queue = .empty;
    self.server.pending_chunks = .empty;
    self.server.pending_unloads = .empty;
    self.server.player_chunks = .empty;
    self.server.snapshot_count = 0;
    self.server.snapshot_serial = 0;
    if (!was_client) self.save_manager.deinit();
    self.game_cleaned = true;
    self.save_initialized = false;
    self.server.player_id = 0;
    self.server.flying = false;
}

/// 运行一个物理 tick（纯逻辑，不碰渲染/输入）
fn tick(self: *Game) !void {
    // 收集玩家输入并投递到服务端线程
    const input = collectHostActions(self);
    try self.server.pushInput(input);

    // ── 联机：主机更新共享数据（供网络线程读取）──
    if (self.network_mode == .host) {
        // 客机断线清理（网络线程已标记 disconnect，tick 中清理 ECS）
        var ci: usize = 0;
        while (ci < self.clients.items.len) {
            if (self.clients.items[ci].disconnect) {
                const c = &self.clients.items[ci];
                if (self.server.registry.tryGet(Comps.Position, c.entity)) |pos| {
                    self.net_saved_client_pos = pos.vec;
                }
                self.server.block_world.cleanupEntity(&self.server.registry, c.entity);
                if (self.server.registry.valid(c.entity)) self.server.registry.destroy(c.entity);
                _ = self.clients.swapRemove(ci);
                Log.info("client id={} cleaned up", .{c.player_id});
            } else {
                ci += 1;
            }
        }

        // 主机相机朝向（网络线程需读取，用于主机玩家快照）
        self.net_mutex.lockUncancelable(io);
        defer self.net_mutex.unlock(io);
        self.net_cam_yaw = self.camera.yaw;
        self.net_cam_pitch = self.camera.pitch;
    }
}

/// 联机：主机网络线程（接受客户端 + 循环收发）
fn hostNetworkThread(self: *Game) void {
    self.listen_fd = Network.listen(Network.SERVER_PORT);
    if (self.listen_fd < 0) {
        Log.err("network: listen failed", .{});
        return;
    }
    self.net_listening = true;
    defer {
        if (self.net_listening) {
            self.net_listening = false;
            _ = winsock.closesocket(self.listen_fd);
        }
    }

    var print_timer: u32 = 0;
    while (self.net_running.load(.acquire)) {
        if (print_timer == 0) {
            Log.info("network: {} client(s) connected", .{self.clients.items.len});
            print_timer = 200; // 每 ~6 秒打印一次（select 通常 ~33ms 返回一次）
        }
        print_timer -= 1;

        // ── 构建 fd_set（listen + 所有客户端） ──
        var readfds = winsock.fd_set{
            .fd_count = 0,
            .fd_array = [_]usize{0} ** winsock.FD_SETSIZE,
        };
        var max_fd: winsock.socket_t = self.listen_fd;
        winsock.FD_SET(self.listen_fd, &readfds);
        for (self.clients.items) |c| {
            winsock.FD_SET(c.fd, &readfds);
            if (c.fd > max_fd) max_fd = c.fd;
        }
        var tv = winsock.timeval{ .sec = 0, .usec = 100000 };
        const sel_rc = winsock.select(max_fd + 1, &readfds, null, null, &tv);
        if (sel_rc < 0) {
            if (self.net_running.load(.acquire)) Log.err("network: select error", .{});
            return;
        }

        // ── 处理新连接 ──
        if (winsock.FD_ISSET(self.listen_fd, &readfds)) {
            const cfd = winsock.accept(self.listen_fd, null, null);
            if (cfd >= 0 and self.net_running.load(.acquire)) {
                const pid = self.next_player_id;
                self.next_player_id += 1;

                // 创建远程玩家实体
                const pinfo = EntityTypeId.fromName("player").info();
                const entity = self.server.registry.create();
                self.server.registry.add(entity, Comps.Player{ .id = pid, .mode = .survival });
                self.server.registry.add(entity, Comps.ModelName{ .id = pinfo.model_id });
                const spawn_pos = if (self.net_saved_client_pos.x != 0 or self.net_saved_client_pos.y != 0 or self.net_saved_client_pos.z != 0)
                    self.net_saved_client_pos
                else blk: {
                    var pv = self.server.registry.view(.{ Comps.Player, Comps.Position }, .{});
                    var pi = pv.entityIterator();
                    var found = Vec3.zero;
                    while (pi.next()) |pe| {
                        if (pv.get(Comps.Player, pe).id == 0) {
                            found = pv.get(Comps.Position, pe).vec;
                            break;
                        }
                    }
                    break :blk found;
                };
                self.server.registry.add(entity, Comps.Position{ .vec = spawn_pos, .prev = spawn_pos });
                if (self.server.registry.tryGet(Comps.Position, entity)) |pp| pushEntityPos(pp, spawn_pos);
                self.server.registry.add(entity, Comps.Velocity{ .vec = Vec3.zero });
                self.server.registry.add(entity, Comps.Collider{ .width = pinfo.collider_width, .height = pinfo.collider_height });
                self.server.registry.add(entity, Comps.Facing{});
                // 不加 MoveIntent/MoveSpeed/JumpVelocity/OnGround，服务端不对远程客机玩家跑物理解算
                if (self.server.animation_system.allocBoneSlot()) |bone_offset| {
                    self.server.registry.add(entity, Comps.AnimationState{
                        .clip_name = @import("rend_ctx.zig").ClipName.idle,
                        .bone_offset = bone_offset,
                    });
                }
                self.clients.append(self.server.allocator, .{
                    .fd = cfd,
                    .entity = entity,
                    .player_id = pid,
                    .disconnect = false,
                    .saved_pos = spawn_pos,
                }) catch {};
                Network.sendWelcome(cfd, pid);
                Log.info("network: player joined as id={}, fd={}", .{ pid, cfd });
            } else if (cfd >= 0) {
                _ = winsock.closesocket(cfd);
            }
        }

        // ── 处理客户端输入 ──
        for (self.clients.items) |*c| {
            if (!winsock.FD_ISSET(c.fd, &readfds)) continue;
            var input: Network.ClientInput = undefined;
            const got = Network.recvInput(c.fd, &input);
            if (!got) {
                c.disconnect = true;
                continue;
            }
            self.server.pushInput(.{
                .player_id = c.player_id,
                .pos = input.pos,
                .cam_yaw = input.cam_yaw,
                .cam_pitch = input.cam_pitch,
                .break_block = input.break_block,
                .place_block = input.place_block,
                .hotbar_slot = input.hotbar_slot,
                .place_block_id = self.hotbar.slots[if (input.hotbar_slot < 9) input.hotbar_slot else self.hotbar.selected].item_id,
                .target = input.target,
                .place_face = input.place_face,
            }) catch {};
        }

        // ── 读取共享数据（一次拷贝，遍历发送） ──
        self.net_mutex.lockUncancelable(io);
        const cam_yaw = self.net_cam_yaw;
        const cam_pitch = self.net_cam_pitch;
        self.server.pending_chunks_mutex.lockUncancelable(io);
        var chunks_to_send = self.server.pending_chunks;
        self.server.pending_chunks = .empty;
        self.server.pending_chunks_mutex.unlock(io);
        self.net_mutex.unlock(io);

        var snapshots: [64]Network.EntitySnapshot = undefined;
        var count: usize = 0;
        var snap_tick: u64 = 0;
        {
            self.server.snapshot_mutex.lockUncancelable(io);
            defer self.server.snapshot_mutex.unlock(io);
            count = self.server.snapshot_count;
            snap_tick = self.server.snapshot_tick;
            if (count > 0) {
                @memcpy(std.mem.sliceAsBytes(snapshots[0..count]), std.mem.sliceAsBytes(self.server.snapshots[0..count]));
                for (snapshots[0..count]) |*s| {
                    if (s.player_id == 0) {
                        s.facing_yaw = -cam_yaw + std.math.pi / 2.0;
                        s.facing_pitch = cam_pitch;
                    }
                }
            }
        }

        // 取出方块更新（一次读出，所有客户端共享）
        self.server.pending_block_updates_mutex.lockUncancelable(io);
        var block_updates = self.server.pending_block_updates;
        self.server.pending_block_updates = .empty;
        self.server.pending_block_updates_mutex.unlock(io);

        // ── 遍历所有客户端，各自发送 ──
        var ci: usize = 0;
        while (ci < self.clients.items.len) {
            const c = &self.clients.items[ci];
            if (c.disconnect) {
                // 断线清理
                _ = winsock.closesocket(c.fd);
                if (self.server.registry.valid(c.entity)) {
                    self.server.block_world.cleanupEntity(&self.server.registry, c.entity);
                    self.server.registry.destroy(c.entity);
                }
                // 从 player_chunks 中移除
                _ = self.server.player_chunks.remove(c.player_id);
                Log.info("client id={} disconnected", .{c.player_id});
                _ = self.clients.swapRemove(ci);
                continue;
            }

            // ── 发送属于该客户的区块 ──
            var chunk_i: usize = 0;
            while (chunk_i < chunks_to_send.items.len) {
                const entry = chunks_to_send.items[chunk_i];
                if (entry.player_id == c.player_id) {
                    if (self.server.block_world.chunks.getPtr(entry.origin)) |loaded| {
                        const pal_json = buildPaletteJson(loaded.chunk.palette.items, std.heap.page_allocator);
                        const bpi = loaded.chunk.index_bits;
                        const data_size = (BlockWorld.CHUNK_WIDTH * BlockWorld.CHUNK_HEIGHT * BlockWorld.CHUNK_WIDTH * @as(u32, @intCast(bpi)) + 7) / 8;
                        _ = Network.sendChunk(c.fd, 0, entry.origin.x, entry.origin.z, pal_json, loaded.chunk.index_data[0..data_size]);
                        std.heap.page_allocator.free(pal_json);
                    }
                    _ = chunks_to_send.swapRemove(chunk_i);
                } else {
                    chunk_i += 1;
                }
            }

            c.saved_pos = self.net_saved_client_pos;
            ci += 1;
        }
        chunks_to_send.deinit(self.server.allocator);

        // ── 发送 state 给所有在线客户端 ──
        const now_ns = @as(i64, @truncate(std.Io.Timestamp.now(io, .awake).nanoseconds));
        for (self.clients.items) |*c| {
            const state_serial = self.server.tick_count;
            // 过滤掉 origin=自己的 block_update（已由本地预测处理）
            var filtered: std.ArrayListUnmanaged(Network.BlockUpdate) = .empty;
            defer filtered.deinit(self.server.allocator);
            for (block_updates.items) |*u| {
                if (u.origin_player_id != c.player_id)
                    filtered.append(self.server.allocator, u.*) catch {};
            }
            Network.sendState(c.fd, &.{
                .serial = @truncate(state_serial),
                .tick_count = snap_tick,
                .host_time = now_ns,
                .entities = snapshots[0..count],
                .block_updates = filtered.items,
            });
        }
        block_updates.deinit(self.server.allocator);
    }
}

/// 将 palette 序列化为 JSON 字符串（与存档格式一致）
fn buildPaletteJson(palette: []const BlockState, allocator: std.mem.Allocator) []u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    buf.append(allocator, '[') catch unreachable;
    for (palette, 0..) |bs, i| {
        if (i > 0) buf.append(allocator, ',') catch unreachable;
        buf.append(allocator, '"') catch unreachable;
        buf.appendSlice(allocator, bs.block_id.name()) catch unreachable;
        buf.append(allocator, '_') catch unreachable;
        buf.append(allocator, @as(u8, '0') + @intFromEnum(bs.facing)) catch unreachable;
        buf.append(allocator, '"') catch unreachable;
    }
    buf.append(allocator, ']') catch unreachable;
    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// 读取 WASD/跳/潜行/冲刺，直接写入 MoveIntent 组件（主机/客机共用）
fn produceMoveIntent(self: *Game) void {
    var view = self.server.registry.view(.{ Comps.Player, Comps.MoveIntent }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const player = view.get(Comps.Player, entity);
        if (player.id != self.server.player_id) continue;
        var intent = view.get(Comps.MoveIntent, entity);

        const front_h = Vec3.new(self.camera.front.x, 0, self.camera.front.z).norm();
        const camera_right = self.camera.front.cross(self.camera.up);
        const right_h = Vec3.new(camera_right.x, 0, camera_right.z).norm();

        var move_dir = Vec3.zero;
        if (self.keybinds.isHeld(&self.input, .forward)) move_dir = move_dir.add(front_h);
        if (self.keybinds.isHeld(&self.input, .back)) move_dir = move_dir.sub(front_h);
        if (self.keybinds.isHeld(&self.input, .left)) move_dir = move_dir.sub(right_h);
        if (self.keybinds.isHeld(&self.input, .right)) move_dir = move_dir.add(right_h);

        if (self.keybinds.isHeld(&self.input, .jump)) {
            intent.jump = true;
            move_dir.y = 1.0;
        }
        if (self.keybinds.isHeld(&self.input, .swim_down)) {
            move_dir.y = -1.0;
        }

        const has_movement = self.keybinds.isHeld(&self.input, .forward) or
            self.keybinds.isHeld(&self.input, .back) or
            self.keybinds.isHeld(&self.input, .left) or
            self.keybinds.isHeld(&self.input, .right);
        if (!has_movement) {
            intent.sprint = false;
            self.server.sprint_toggled = false;
        } else {
            intent.sprint = self.server.sprint_toggled;
        }

        if (self.keybinds.isHeld(&self.input, .sneak)) {
            intent.sneak = true;
            if (!self.server.flying) intent.sprint = false;
        } else {
            intent.sneak = false;
        }

        if (move_dir.len2() > 0.001) move_dir = move_dir.norm();
        intent.direction = move_dir;
    }
}

/// 本地预测 + 返回目标坐标（主机/客机共用）
fn predictBlockAction(self: *Game, target: *Vec3i, place_face: *u8) void {
    if (self.break_once) {
        const ray = Raycast.Ray.init(self.camera.position, self.camera.front);
        const hit = Raycast.raycastWorld(&self.server.block_world, ray, 8.0);
        if (hit.hit) {
            target.* = hit.block_pos;
            self.server.block_world.setBlock(hit.block_pos, BlockState.fromName("air")) catch {};
        }
    }
    if (self.place_once) {
        const ray = Raycast.Ray.init(self.camera.position, self.camera.front);
        const hit = Raycast.raycastWorld(&self.server.block_world, ray, 8.0);
        if (hit.hit) {
            const place_pos = Vec3i.new(
                hit.block_pos.x + hit.face_normal.x,
                hit.block_pos.y + hit.face_normal.y,
                hit.block_pos.z + hit.face_normal.z,
            );
            const sel = self.hotbar.slots[self.hotbar.selected];
            if (sel.item_id > 0) {
                const facing: Direction = blk: {
                    const fn_ = hit.face_normal;
                    if (fn_.y != 0) break :blk if (fn_.y > 0) Direction.up else Direction.down;
                    if (fn_.x != 0) break :blk if (fn_.x > 0) Direction.west else Direction.east;
                    break :blk if (fn_.z > 0) Direction.south else Direction.north;
                };
                target.* = place_pos;
                place_face.* = @intFromEnum(facing);
                self.server.block_world.setBlock(place_pos, BlockState{ .block_id = BlockId.fromInt(sel.item_id), .facing = facing }) catch {};
            }
        }
    }
}

/// 采集主机玩家的动作（break/place/fly/camera），通过服务端队列处理
fn collectHostActions(self: *Game) PlayerInput {
    const wants_fly = self.server_wants_fly;
    self.server_wants_fly = false;
    defer {
        self.break_once = false;
        self.place_once = false;
    }

    var target = Vec3i.zero;
    var place_face: u8 = 0;
    predictBlockAction(self, &target, &place_face);

    // 写入 MoveIntent（与 clientTick 一致，主机玩家移动不再经过服务端队列）
    produceMoveIntent(self);

    return .{
        .player_id = self.server.player_id,
        .cam_yaw = self.camera.yaw,
        .cam_pitch = self.camera.pitch,
        .break_block = self.break_once,
        .place_block = self.place_once,
        .wants_fly = wants_fly,
        .hotbar_slot = self.hotbar.selected,
        .place_block_id = self.hotbar.slots[self.hotbar.selected].item_id,
        .target = target,
        .place_face = place_face,
    };
}

/// 从本地输入设备（键盘/鼠标）采集移动意图（客户端专用）
/// 客户端 tick：不跑物理，只发输入 + 收状态
/// 客机：发输入（30Hz，跟随物理 tick）
fn clientTick(self: *Game) !void {
    self._tick_start_ns = @as(i64, @truncate(std.Io.Timestamp.now(io, .awake).nanoseconds));

    var intent: Network.ClientInput = undefined;
    intent.serial = @truncate(self.server.tick_count);
    // 清零目标坐标/朝向（避免 undefined 垃圾被发给服务器）
    intent.target = Vec3i.zero;
    intent.place_face = 0;

    // 设置移动意图（WASD），复用服务端物理系统
    // 键盘 → MoveIntent（与主机/单人游戏一致的逻辑）
    produceMoveIntent(self);
    // 飞行切换（双击空格）
    if (self.server_wants_fly) {
        self.server_wants_fly = false;
        const rp = self.remote_player.?;
        if (self.server.registry.has(Comps.Flying, rp)) {
            _ = self.server.registry.remove(Comps.Flying, rp);
        } else {
            self.server.registry.add(rp, Comps.Flying{});
        }
    }
    // 跑本地物理（碰撞、重力）
    self.server.block_world.updatePhysics(&self.server.registry, TICK_DT);
    // 推入环缓冲（相机插值用，与主机逻辑统一）
    if (self.server.registry.tryGet(Comps.Position, self.remote_player.?)) |pos2| pushEntityPos(pos2, pos2.vec);
    // 读取物理运算后的位置，提交给服务器
    if (self.server.registry.tryGet(Comps.Position, self.remote_player.?)) |pos| {
        intent.pos = pos.vec;
    }
    intent.cam_yaw = self.camera.yaw;
    intent.cam_pitch = self.camera.pitch;

    // 本地预测（与主机 collectHostActions 共用 predictBlockAction）
    predictBlockAction(self, &intent.target, &intent.place_face);
    intent.break_block = self.break_once;
    intent.place_block = self.place_once;
    self.break_once = false;
    self.place_once = false;
    intent.hotbar_slot = self.hotbar.selected;

    Network.sendInput(@as(winsock.socket_t, @intCast(self.client_fd)), &intent);
}

/// 客机：每帧收包，更新实体位置（独立于 30Hz clientTick）
fn clientReceivePackets(self: *Game) void {
    var state: Network.ServerState = undefined;
    var state_initialized = false;

    // 一次性读完所有可用的包
    while (true) {
        var readfds = winsock.fd_set{
            .fd_count = 1,
            .fd_array = [_]usize{@as(usize, @intCast(self.client_fd))} ** winsock.FD_SETSIZE,
        };
        var tv = winsock.timeval{ .sec = 0, .usec = 0 };
        const sel_rc = winsock.select(0, &readfds, null, null, &tv);
        if (sel_rc < 0) break;
        if (sel_rc == 0) break; // 无数据，下帧再试
        const tag = Network.peekTag(self.client_fd);
        if (tag == 0) {
            // select 说有数据但 peekTag 返回 0 → 连接已关闭
            self.disconnectClient();
            return;
        }
        if (tag == 2) {
            self.chunk_count += 1;
            const result = Network.recvChunk(self.client_fd, self.allocator);
            if (result == null) {
                self.disconnectClient();
                return;
            }
            if (result) |chunk| {
                if (chunk.palette.len > 2) {
                    self.server.block_world.insertChunkFromNetwork(chunk.origin_x, chunk.origin_z, chunk.palette, chunk.data) catch {};
                }
                self.allocator.free(chunk.palette);
                self.allocator.free(chunk.data);
            }
        } else if (tag == 1) {
            // 释放上一个 state 的 entities
            if (state_initialized) self.allocator.free(state.entities);

            const got = Network.recvState(self.client_fd, self.allocator, &state);
            if (!got) {
                self.disconnectClient();
                return;
            }
            state_initialized = true;

            // 立即应用 block_updates（不等到循环结束，避免被后续 state 覆盖）
            for (state.block_updates) |upd| {
                const block_state = if (upd.block_id == 0)
                    BlockState.fromName("air")
                else
                    BlockState{ .block_id = BlockId.fromInt(upd.block_id), .facing = @enumFromInt(upd.facing) };
                self.server.block_world.setBlock(Vec3i.new(upd.x, @as(i32, @intCast(upd.y)), upd.z), block_state) catch {};
            }
            // block_updates 已应用，立即释放
            if (state.block_updates.len > 0) {
                self.allocator.free(state.block_updates);
                state.block_updates = &.{}; // 防止后续 defer 重复释放
            }
        } else if (tag == 3) {
            const unload = Network.recvChunkUnload(self.client_fd);
            if (unload) |u| {
                self.server.block_world.unloadChunk(Vec3i.new(u.x, 0, u.z));
            }
        } else break;
    }

    if (!state_initialized) return;
    defer self.allocator.free(state.entities);

    // 复制到渲染快照缓冲区
    self.render_snapshot_count = @as(u32, @intCast(state.entities.len));
    @memcpy(std.mem.sliceAsBytes(self.render_snapshots[0..self.render_snapshot_count]), std.mem.sliceAsBytes(state.entities));

    // 记录插值时间基准
    self.last_snapshot_time_ns = @as(i64, @truncate(std.Io.Timestamp.now(io, .awake).nanoseconds));
    const now_ns = self.last_snapshot_time_ns;
    const latency_ns = now_ns - state.host_time;
    if (latency_ns >= 0) {
        self.latency_min_ns = @min(self.latency_min_ns, latency_ns);
        self.latency_max_ns = @max(self.latency_max_ns, latency_ns);
        self.latency_sum_ns += latency_ns;
        self.latency_samples += 1;
    }

    for (state.entities, 0..) |snap, i| {
        if (snap.player_id == self.server.player_id) {
            // 不覆盖 pos.vec（本地物理已算好），也不推环缓冲（clientTick 已推）
            if (self.server.registry.tryGet(Comps.Facing, self.remote_player.?)) |facing| {
                facing.yaw = snap.facing_yaw;
                facing.pitch = snap.facing_pitch;
            }
            continue;
        }
        const key = @as(u64, @intCast(i));
        const gop = self.snapshot_info.getOrPut(self.allocator, key) catch continue;
        if (!gop.found_existing) {
            const is_player = snap.player_id != std.math.maxInt(u32);
            const einfo = if (is_player) EntityTypeId.fromName("player").info() else EntityTypeId.fromName("zombie").info();
            const entity = self.server.registry.create();
            self.server.registry.add(entity, Comps.ModelName{ .id = einfo.model_id });
            self.server.registry.add(entity, Comps.Position{ .vec = snap.pos, .prev = snap.pos });
            if (self.server.registry.tryGet(Comps.Position, entity)) |pp| pushEntityPos(pp, snap.pos);
            self.server.registry.add(entity, Comps.Collider{ .width = einfo.collider_width, .height = einfo.collider_height });
            self.server.registry.add(entity, Comps.Facing{});
            gop.value_ptr.* = .{ .entity = entity, .player_id = snap.player_id };
        } else {
            if (self.server.registry.tryGet(Comps.Position, gop.value_ptr.*.entity)) |pos| {
                pushEntityPos(pos, snap.pos);
                pos.prev = pos.vec;
                pos.vec = snap.pos;
            }
            if (self.server.registry.tryGet(Comps.Facing, gop.value_ptr.*.entity)) |facing| {
                facing.yaw = snap.facing_yaw;
                facing.pitch = snap.facing_pitch;
            }
        }
    }

    // 清理已不存在的实体
    {
        var keys_to_remove: std.ArrayListUnmanaged(u64) = .empty;
        defer keys_to_remove.deinit(self.allocator);
        var iter = self.snapshot_info.keyIterator();
        while (iter.next()) |k| {
            if (k.* >= state.entities.len) {
                keys_to_remove.append(self.allocator, k.*) catch {};
            } else if (self.snapshot_info.getPtr(k.*)) |info| {
                if (state.entities[k.*].player_id != info.player_id) {
                    keys_to_remove.append(self.allocator, k.*) catch {};
                }
            }
        }
        for (keys_to_remove.items) |k| {
            if (self.snapshot_info.getPtr(k)) |e| {
                self.server.registry.destroy(e.*.entity);
            }
            _ = self.snapshot_info.remove(k);
        }
    }

    // 为主线程创建的实体补充 AnimationState
    {
        var av = self.server.registry.view(.{Comps.ModelName}, .{});
        var ai = av.entityIterator();
        while (ai.next()) |ent| {
            if (!self.server.registry.has(Comps.AnimationState, ent)) {
                if (self.server.animation_system.allocBoneSlot()) |bone_offset| {
                    self.server.registry.add(ent, Comps.AnimationState{
                        .clip_name = @import("rend_ctx.zig").ClipName.idle,
                        .bone_offset = bone_offset,
                    });
                }
            }
        }
    }
    self.server.animation_system.update(&self.server.registry, &self.res_manager, TICK_DT);
}

/// 客户端断开连接，回到主菜单
pub fn disconnectClient(self: *Game) void {
    Log.info("client disconnected", .{});
    self.snapshot_info.deinit(self.allocator);
    self.snapshot_info = .{};
    if (self.client_connected.load(.acquire)) {
        _ = winsock.closesocket(self.client_fd);
        self.client_fd = undefined;
        self.client_connected.store(false, .release);
    }
    self.server.block_world.deinit();
    self.server.registry.deinit();
    self.server.registry = ECS.Registry.init(self.allocator);
    self.net_running.store(false, .release);
    self.save_initialized = false;
    self.menu_state = .MainMenu;
    self.snapshot_info = .{}; // 已在上方 deinit，重置标记
    Log.info("returned to menu\n", .{});
}

/// 物品栏输入处理：数字键切换到、滚轮切换、中键拾取方块
fn handleHotbarInput(self: *Game) void {
    // 数字键 1-9 选中对应槽位
    const hotbar_actions = [_]KeyAction{
        .hotbar_1, .hotbar_2, .hotbar_3, .hotbar_4, .hotbar_5,
        .hotbar_6, .hotbar_7, .hotbar_8, .hotbar_9,
    };
    inline for (hotbar_actions, 0..) |action, slot| {
        if (self.keybinds.isJustPressed(&self.input, action)) {
            self.hotbar.selected = @intCast(slot);
        }
    }

    // 滚轮切换选中槽位
    if (self.keybinds.isJustPressed(&self.input, .hotbar_scroll_up)) {
        self.hotbar.selected = (self.hotbar.selected + 8) % 9;
    } else if (self.keybinds.isJustPressed(&self.input, .hotbar_scroll_down)) {
        self.hotbar.selected = (self.hotbar.selected + 1) % 9;
    }

    // 鼠标中键：拾取瞄准的方块到当前槽位
    if (self.keybinds.isJustPressed(&self.input, .pick_block)) {
        const ray = self.camera.getCursorRay();
        const hit = Raycast.raycastWorld(&self.server.block_world, ray, 8.0);
        if (hit.hit) {
            const block = self.server.block_world.getBlockAt(Vec3.new(
                @as(f32, @floatFromInt(hit.block_pos.x)) + 0.5,
                @as(f32, @floatFromInt(hit.block_pos.y)) + 0.5,
                @as(f32, @floatFromInt(hit.block_pos.z)) + 0.5,
            ));
            if (block.id == 0) return;
            const block_id = block.id;

            for (&self.hotbar.slots, 0..) |slot, i| {
                if (slot.item_id == block_id) {
                    self.hotbar.selected = @as(u32, @intCast(i));
                    return;
                }
            }

            self.hotbar.slots[self.hotbar.selected] = .{
                .item_id = block_id,
                .count = 1,
            };
        }
    }
}

fn pollServerSnapshot(self: *Game) void {
    const serial = self.server.snapshot_serial;
    if (serial == self.last_snapshot_serial) return;
    self.last_snapshot_serial = serial;

    self.server.snapshot_mutex.lockUncancelable(io);
    defer self.server.snapshot_mutex.unlock(io);
    const snapshots = self.server.snapshots[0..self.server.snapshot_count];

    // 复制到渲染快照缓冲区（供 render.zig 使用，避免 ECS view 迭代竞态）
    self.render_snapshot_count = @as(u32, @intCast(snapshots.len));
    @memcpy(std.mem.sliceAsBytes(self.render_snapshots[0..self.render_snapshot_count]), std.mem.sliceAsBytes(snapshots));

    // 主机：推入实体 3 槽环形缓冲区
    if (self.network_mode != .client) {
        for (snapshots) |s| {
            const entity = s.entity;
            if (!self.server.registry.valid(entity)) continue;
            if (self.server.registry.tryGet(Comps.Position, entity)) |pos| {
                if (!self.host_snap_valid) {
                    // 第一次快照：推入三次确保缓冲区填满
                    pushEntityPos(pos, s.pos);
                    pushEntityPos(pos, s.pos);
                    pushEntityPos(pos, s.pos);
                } else {
                    pushEntityPos(pos, s.pos);
                }
            }
            if (self.server.registry.tryGet(Comps.Facing, entity)) |facing| {
                facing.yaw = s.facing_yaw;
                facing.pitch = s.facing_pitch;
            }
        }
        self.last_snapshot_time_ns = @as(i64, @truncate(std.Io.Timestamp.now(io, .awake).nanoseconds));
        self.host_snap_valid = true;
    }

    // 主机/单人：动画更新（主线程，与服务端分离）
    if (self.network_mode != .client) {
        // ── AnimationState 修复 ──
        // zig-ecs 非线程安全。服务端线程每 tick 写 Position/Velocity 等组件时，
        // 内部数据结构可能踩到 AnimationState 的存储区域，使 bone_offset 变为
        // DebugAllocator 填充值 0xAAAAAAAA。此修复在每次 pollServerSnapshot 中
        // 检测被踩坏的 bone_offset 并重新分配合法 slot。
        {
            var av = self.server.registry.view(.{Comps.AnimationState}, .{});
            var ai = av.entityIterator();
            while (ai.next()) |ent| {
                const st = av.get(ent);
                if (st.bone_offset >= 0xFFFF0000) {
                    const new_bo = self.server.animation_system.allocBoneSlot() orelse continue;
                    st.bone_offset = new_bo;
                }
            }
        }
        self.server.animation_system.update(&self.server.registry, &self.res_manager, TICK_DT);
    }
}

/// 推入实体 3 槽环形缓冲区
fn pushEntityPos(pos: *Comps.Position, new_pos: Vec3) void {
    const h = pos.render_buf_head;
    pos.render_buf_pos[h] = new_pos;
    pos.render_buf_time[h] = @as(i64, @truncate(std.Io.Timestamp.now(io, .awake).nanoseconds));
    pos.render_buf_head = (h + 1) % 3;
    if (pos.render_buf_count < 3) pos.render_buf_count += 1;
}

fn syncCameraFromPlayer(self: *Game) void {
    var view = self.server.registry.view(.{ Comps.Player, Comps.Position }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const p = view.get(Comps.Player, entity);
        if (p.id == self.server.player_id) {
            const pos = view.get(Comps.Position, entity);
            // 从实体 3 槽环形缓冲区查插值位置（主机/客机统一）
            const rend_now = @as(i64, @truncate(std.Io.Timestamp.now(io, .awake).nanoseconds));
            const rend_time = rend_now -| 33_000_000;
            var rend_pos: Vec3 = undefined;
            var found = false;
            if (pos.render_buf_count >= 2 and pos.render_buf_count <= 3) {
                const newest = (pos.render_buf_head + 2) % 3;
                var ri: u32 = 0;
                while (ri < pos.render_buf_count - 1) {
                    const ni = (newest + 3 - ri) % 3;
                    const oi = (ni + 2) % 3;
                    if (pos.render_buf_time[oi] <= rend_time and pos.render_buf_time[ni] > rend_time) {
                        const interval = pos.render_buf_time[ni] - pos.render_buf_time[oi];
                        if (interval > 0) {
                            const alpha = @min(@max(@as(f32, @floatFromInt(rend_time - pos.render_buf_time[oi])) / @as(f32, @floatFromInt(interval)), 0.0), 1.0);
                            rend_pos = Vec3.lerp(pos.render_buf_pos[oi], pos.render_buf_pos[ni], alpha);
                        } else rend_pos = pos.render_buf_pos[ni];
                        found = true;
                        break;
                    }
                    ri += 1;
                }
            }
            const render_pos = if (found) rend_pos else if (pos.render_buf_count > 0) pos.render_buf_pos[(pos.render_buf_head + 2) % 3] else Vec3.zero;
            const eye = render_pos.add(Vec3.new(0, 1.6, 0));
            self.camera.position = eye;
            self.ubo.camera_pos = eye;
            self.ubo.view_matrix = Mat4.lookAt(eye, eye.add(self.camera.front), self.camera.up);
            break;
        }
    }
}

/// 尝试将物品加入热栏/背包（优先堆叠，次优先空位）
fn tryItemToInventory(self: *Game, item_id: u32, count: u32) void {
    var remaining = count;
    const max_stack = item_infos[@as(usize, @intCast(item_id))].max_stack;

    // 1. 热栏已有堆叠
    for (&self.hotbar.slots) |*slot| {
        if (slot.item_id == item_id and slot.count < max_stack) {
            const space = max_stack - slot.count;
            const move = @min(remaining, space);
            slot.count += move;
            remaining -= move;
            if (remaining == 0) return;
        }
    }

    // 2. 热栏空格
    for (&self.hotbar.slots) |*slot| {
        if (slot.item_id == 0) {
            const put = @min(remaining, max_stack);
            slot.* = .{ .item_id = item_id, .count = put };
            remaining -= put;
            if (remaining == 0) return;
        }
    }

    // 3. 背包已有堆叠
    for (&self.inventory.slots) |*slot| {
        if (slot.item_id == item_id and slot.count < max_stack) {
            const space = max_stack - slot.count;
            const move = @min(remaining, space);
            slot.count += move;
            remaining -= move;
            if (remaining == 0) return;
        }
    }

    // 4. 背包空格
    for (&self.inventory.slots) |*slot| {
        if (slot.item_id == 0) {
            const put = @min(remaining, max_stack);
            slot.* = .{ .item_id = item_id, .count = put };
            remaining -= put;
            if (remaining == 0) return;
        }
    }

    if (remaining > 0) {
        std.debug.print("背包已满，丢失 {d}x item_id={d}\n", .{ remaining, item_id });
    }
}

fn spawnEnemy(self: *Game, comptime type_name: []const u8, pos: Vec3) !void {
    const eid = EntityTypeId.fromName(type_name);
    const info = eid.info();
    const entity = self.server.registry.create();
    self.server.registry.add(entity, Comps.AIAgent{ .type_id = eid, .target = pos });
    self.server.registry.add(entity, Comps.ModelName{ .id = info.model_id });
    self.server.registry.add(entity, Comps.Position{ .vec = pos, .prev = pos });
    if (self.server.registry.tryGet(Comps.Position, entity)) |pp| pushEntityPos(pp, pos);
    self.server.registry.add(entity, Comps.Velocity{ .vec = Vec3.zero });
    self.server.registry.add(entity, Comps.Collider{ .width = info.collider_width, .height = info.collider_height });
    self.server.registry.add(entity, Comps.MoveSpeed{ .value = info.move_speed });
    self.server.registry.add(entity, Comps.JumpVelocity{ .value = info.jump_vel });
    self.server.registry.add(entity, Comps.OnGround{ .value = false });
    self.server.registry.add(entity, Comps.Facing{});
    self.server.registry.add(entity, Comps.MoveIntent{});
    self.server.registry.add(entity, Comps.Health{ .current = info.health, .max = info.health });
    self.server.registry.add(entity, Comps.AttackCooldown{ .interval = info.attack_interval });
}

const Game = @This();

pub const MenuState = enum {
    MainMenu,
    SaveSelect,
    Gameplay,
    Pause,
    Inventory,
};

pub const NetworkMode = enum {
    single,
    host,
    client,
};

pub const SlotSource = enum { hotbar, inventory };

pub const SelectedItem = struct {
    source: SlotSource,
    slot_idx: usize,
    item: ItemStack,
};

const std = @import("std");
const Mat4 = @import("algebra.zig").Mat4;
const Vec3i = @import("algebra.zig").Vec3i;
const Raycast = @import("raycast.zig");

const WireframePipeline = @import("wireframe_pipeline.zig").WireframePipeline;
const SkyPipeline = @import("sky.zig").SkyPipeline;
const ShadowPipeline = @import("shadow.zig").ShadowPipeline;

const BlockWorld = @import("block_world.zig");
const TICK_DT = BlockWorld.TICK_DT;
const BlockRegistry = @import("block_registry.zig");
const BlockState = BlockRegistry.BlockState;
const BlockId = BlockRegistry.BlockId;
const Direction = @import("direction.zig").Direction;
const AABB = @import("aabb.zig").AABB;
const EntityTypeId = @import("entity_registry.zig").EntityTypeId;
const Hotbar = @import("inventory.zig").Hotbar;
const PlayerInventory = @import("inventory.zig").PlayerInventory;
const ItemStack = @import("inventory.zig").ItemStack;
const registries = @import("registries.zig");
const item_infos = @import("item_registry.zig").item_infos;
const ItemId = @import("item_registry.zig").ItemId;
const IconAtlas = @import("icon_atlas.zig").IconAtlas;
const SaveManager = @import("save_manager.zig").SaveManager;
const Keybinds = @import("keybinds.zig").Keybinds;
const KeyAction = @import("keybinds.zig").Action;
const AnimationSystem = @import("animation.zig").AnimationSystem;
const Server = @import("server.zig").Server;
const PlayerInput = @import("server.zig").PlayerInput;
const Network = @import("network.zig");
const Log = @import("log.zig");

pub const ClientInfo = struct {
    fd: winsock.socket_t,
    entity: ECS.Entity,
    player_id: u32,
    disconnect: bool,
    saved_pos: Vec3,
};
