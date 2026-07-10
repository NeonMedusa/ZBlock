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
const WaterPipeline = @import("water_pipeline.zig");
const UiSystem = @import("ui_system.zig");
const Input = @import("input.zig");
const ECS = @import("zigecs");
const RendCTX = @import("rend_ctx.zig");
const ClipName = RendCTX.ClipName;
const Comps = @import("components.zig").Components;
const Wgpu = @import("imports.zig").Wgpu;
const Glfw = @import("imports.zig").Glfw;
const Gltf = @import("imports.zig").Gltf;
const Vec3 = @import("algebra.zig").Vec3;
const ResManager = @import("rend_ctx.zig").ResManager;
const Model = @import("rend_ctx.zig").Model;
const SceneUniform = @import("rend_ctx.zig").SceneUniform;
const zigimg = @import("zigimg");

allocator: std.mem.Allocator,
window: Window,
gctx: Gctx,
input: Input,
server: Server,
ui_system: UiSystem,
res_manager: ResManager,
wireframe_pipeline: WireframePipeline,
render_pipeline: RenderPipeline,
water_pipeline: WaterPipeline,
ssr_color_texture: Wgpu.WGPUTexture,
ssr_color_view: Wgpu.WGPUTextureView,
ssr_bgl: Wgpu.WGPUBindGroupLayout,
ssr_sampler: Wgpu.WGPUSampler,
ssr_bind_group: Wgpu.WGPUBindGroup,
depth_copy_texture: Wgpu.WGPUTexture,
depth_copy_view: Wgpu.WGPUTextureView,
noise_texture: Wgpu.WGPUTexture,
noise_texture_view: Wgpu.WGPUTextureView,
noise_sampler: Wgpu.WGPUSampler,
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
network: Network.NetworkManager,
break_once: bool = false, // mouse left click
place_once: bool = false, // mouse right click

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
                if (self.network.mode == .client) {
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
                if (self.menu_state != .Pause or self.network.mode != .single) {
                    if (self.network.mode == .client) {
                        try self.clientTick(); // 30Hz 发输入
                    } else {
                        try self.tick();
                    }
                }
            }
            // 客机：每帧收包，不等 30Hz tick
            if (self.network.mode == .client and self.save_initialized and self.network.client_connected.load(.acquire)) {
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
                        const target = std.math.atan2(vel.vec.x, vel.vec.z);
                        facing.yaw = facing.yaw + 0.3 * (target - facing.yaw);
                    }
                }
            }

            if (self.menu_state == .Gameplay or self.menu_state == .Inventory or (self.menu_state == .Pause and self.network.mode != .single)) {
                // 骨骼矩阵插值并上传到 GPU（多人模式下暂停时也不停止）
                self.server.animation_system.upload(self.gctx.queue, self.accumulator / TICK_DT);
                if (self.network.mode != .client) self.pollServerSnapshot();
                syncCameraFromPlayer(self);
            }

            if (self.menu_state == .Gameplay) {
                self.camera.updateFromMouse(self);

                // DEBUG: 每 ~3 秒打印一次客机延迟统计（仅打印一次，防止重复）
                if (self.network.mode == .client and self.network.state_count > 0 and self.network.state_count % 90 == 0 and self.network._last_latency_print != self.network.state_count) {
                    self.network._last_latency_print = self.network.state_count;
                    const avg_ns = if (self.network.latency_samples > 0) @divTrunc(self.network.latency_sum_ns, @as(i64, @intCast(self.network.latency_samples))) else 0;
                    Log.info(.latency, "[LATENCY] states={d} chunks={d} gaps={d}  min={d}us avg={d}us max={d}us", .{
                        self.network.state_count,
                        self.network.chunk_count,
                        self.network.state_serial_gaps,
                        @divTrunc(self.network.latency_min_ns, 1000),
                        @divTrunc(avg_ns, 1000),
                        @divTrunc(self.network.latency_max_ns, 1000),
                    });
                }
                // 飞行切换（每帧检测，不依赖 tick）
                if (self.input.isKeyJustPressed(.space)) {
                    if (self.network.fly_timer > 0 and self.network.fly_timer < 0.4) {
                        self.network.server_wants_fly = true;
                        self.network.fly_timer = 0;
                    } else if (self.network.fly_timer <= 0) {
                        self.network.fly_timer = 0.3;
                    }
                }
                if (self.network.fly_timer > 0) {
                    self.network.fly_timer -= self.window.delta_time;
                    if (self.network.fly_timer < 0) self.network.fly_timer = 0;
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

/// 窗口缩放后重建 SSR 离屏纹理和 bind group
pub fn resizeSSR(self: *Game) void {
    // 释放旧资源
    Wgpu.wgpuTextureRelease(self.ssr_color_texture);
    Wgpu.wgpuTextureViewRelease(self.ssr_color_view);
    Wgpu.wgpuTextureRelease(self.depth_copy_texture);
    Wgpu.wgpuTextureViewRelease(self.depth_copy_view);
    Wgpu.wgpuBindGroupRelease(self.ssr_bind_group);

    // 重建 SSR 颜色纹理
    self.ssr_color_texture = Wgpu.wgpuDeviceCreateTexture(self.gctx.device, &.{
        .usage = Wgpu.WGPUTextureUsage_RenderAttachment | Wgpu.WGPUTextureUsage_TextureBinding | Wgpu.WGPUTextureUsage_CopySrc,
        .dimension = Wgpu.WGPUTextureDimension_2D,
        .size = .{ .width = self.gctx.surface_config.width, .height = self.gctx.surface_config.height, .depthOrArrayLayers = 1 },
        .format = Wgpu.WGPUTextureFormat_BGRA8UnormSrgb,
        .mipLevelCount = 1,
        .sampleCount = 1,
    });
    self.ssr_color_view = Wgpu.wgpuTextureCreateView(self.ssr_color_texture, null);

    // 重建深度拷贝纹理
    self.depth_copy_texture = Wgpu.wgpuDeviceCreateTexture(self.gctx.device, &.{
        .usage = Wgpu.WGPUTextureUsage_TextureBinding | Wgpu.WGPUTextureUsage_CopyDst,
        .dimension = Wgpu.WGPUTextureDimension_2D,
        .size = .{ .width = self.gctx.surface_config.width, .height = self.gctx.surface_config.height, .depthOrArrayLayers = 1 },
        .format = Wgpu.WGPUTextureFormat_Depth24Plus,
        .mipLevelCount = 1,
        .sampleCount = 1,
    });
    self.depth_copy_view = Wgpu.wgpuTextureCreateView(self.depth_copy_texture, null);

    // 重建 SSR bind group（含噪声纹理）
    self.ssr_bind_group = Wgpu.wgpuDeviceCreateBindGroup(self.gctx.device, &Wgpu.WGPUBindGroupDescriptor{
        .layout = self.ssr_bgl,
        .entryCount = 5,
        .entries = &[_]Wgpu.WGPUBindGroupEntry{
            .{ .binding = 0, .textureView = self.ssr_color_view },
            .{ .binding = 1, .sampler = self.ssr_sampler },
            .{ .binding = 2, .textureView = self.depth_copy_view },
            .{ .binding = 3, .textureView = self.noise_texture_view },
            .{ .binding = 4, .sampler = self.noise_sampler },
        },
    });
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
                        .clip_name = ClipName.walk.toString(),
                        .bone_offset = bone_offset,
                    });
                }
            }
        }
    }

    // 启动服务端线程（单人/主机的物理、AI、动画）
    try self.server.start(&self.res_manager);

    // 联机模式：启动网络线程
    if (self.network.mode == .host) {
        self.network.net_running.store(true, .release);
        self.network.net_thread = try std.Thread.spawn(.{}, hostNetworkThread, .{self});
    }

    self.save_initialized = true;
}

pub fn init(allocator: std.mem.Allocator) !*@This() {
    if (@import("builtin").os.tag == .windows) winsock.startup();
    var self = try allocator.create(@This());
    self.allocator = allocator;
    self.server = Server.init(allocator);
    self.network.net_mutex = .init;
    self.network.mode = .single;
    self.network.net_saved_client_pos = Vec3.zero;
    self.network.net_thread = null;
    self.network.clients = .empty;
    self.network.next_player_id = 1;
    self.network.remote_player = null;
    self.network.snapshot_info = .{};
    self.server.player_id = 0;
    self.server.flying = false;

    self.network.last_snapshot_serial = std.math.maxInt(u64);
    self.network.host_snap_valid = false;
    self.network.render_snapshot_count = 0;
    self.network.last_snapshot_time_ns = 0;
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
    self.render_pipeline = try RenderPipeline.init(self, "shaders/render_shader.wgsl");

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
    self.wireframe_pipeline = try WireframePipeline.init(self, "shaders/wireframe_shader.wgsl");

    // SSR 离屏纹理（不透明场景颜色，水面反射用）
    const ssr_format = Wgpu.WGPUTextureFormat_BGRA8UnormSrgb;
    self.ssr_color_texture = Wgpu.wgpuDeviceCreateTexture(self.gctx.device, &.{
        .usage = Wgpu.WGPUTextureUsage_RenderAttachment | Wgpu.WGPUTextureUsage_TextureBinding | Wgpu.WGPUTextureUsage_CopySrc,
        .dimension = Wgpu.WGPUTextureDimension_2D,
        .size = .{ .width = self.gctx.surface_config.width, .height = self.gctx.surface_config.height, .depthOrArrayLayers = 1 },
        .format = ssr_format,
        .mipLevelCount = 1,
        .sampleCount = 1,
    });
    self.ssr_color_view = Wgpu.wgpuTextureCreateView(self.ssr_color_texture, null);

    // SSR bind group layout + 采样器（含离屏颜色 + 深度 + 噪声纹理，用于SSR+波法线）
    self.ssr_bgl = Wgpu.wgpuDeviceCreateBindGroupLayout(self.gctx.device, &Wgpu.WGPUBindGroupLayoutDescriptor{
        .entryCount = 5,
        .entries = &[_]Wgpu.WGPUBindGroupLayoutEntry{
            .{ .binding = 0, .visibility = Wgpu.WGPUShaderStage_Fragment, .texture = .{ .sampleType = Wgpu.WGPUTextureSampleType_Float, .viewDimension = Wgpu.WGPUTextureViewDimension_2D } },
            .{ .binding = 1, .visibility = Wgpu.WGPUShaderStage_Fragment, .sampler = .{ .type = Wgpu.WGPUSamplerBindingType_Filtering } },
            .{ .binding = 2, .visibility = Wgpu.WGPUShaderStage_Fragment, .texture = .{ .sampleType = Wgpu.WGPUTextureSampleType_Depth, .viewDimension = Wgpu.WGPUTextureViewDimension_2D } },
            .{ .binding = 3, .visibility = Wgpu.WGPUShaderStage_Fragment, .texture = .{ .sampleType = Wgpu.WGPUTextureSampleType_Float, .viewDimension = Wgpu.WGPUTextureViewDimension_2D } },
            .{ .binding = 4, .visibility = Wgpu.WGPUShaderStage_Fragment, .sampler = .{ .type = Wgpu.WGPUSamplerBindingType_Filtering } },
        },
    });
    self.ssr_sampler = Wgpu.wgpuDeviceCreateSampler(self.gctx.device, &.{
        .addressModeU = Wgpu.WGPUAddressMode_ClampToEdge,
        .addressModeV = Wgpu.WGPUAddressMode_ClampToEdge,
        .addressModeW = Wgpu.WGPUAddressMode_ClampToEdge,
        .magFilter = Wgpu.WGPUFilterMode_Nearest,
        .minFilter = Wgpu.WGPUFilterMode_Nearest,
        .maxAnisotropy = 1,
    });
    // 深度拷贝纹理（水 Pass 写入深度时不与 SSR 冲突）
    self.depth_copy_texture = Wgpu.wgpuDeviceCreateTexture(self.gctx.device, &.{
        .usage = Wgpu.WGPUTextureUsage_TextureBinding | Wgpu.WGPUTextureUsage_CopyDst,
        .dimension = Wgpu.WGPUTextureDimension_2D,
        .size = .{ .width = self.gctx.surface_config.width, .height = self.gctx.surface_config.height, .depthOrArrayLayers = 1 },
        .format = Wgpu.WGPUTextureFormat_Depth24Plus,
        .mipLevelCount = 1,
        .sampleCount = 1,
    });
    self.depth_copy_view = Wgpu.wgpuTextureCreateView(self.depth_copy_texture, null);

    // 生成随机噪声纹理（256x256，R/G 独立随机）
    {
        const ns: u32 = 256;
        const nw = ns;
        const nh = ns;
        const nbytes = try std.heap.page_allocator.alloc(u8, nw * nh * 4);
        defer std.heap.page_allocator.free(nbytes);
        var rng = std.Random.DefaultPrng.init(42);
        for (0..nh) |iy| {
            for (0..nw) |ix| {
                const idx = (iy * nw + ix) * 4;
                nbytes[idx + 0] = rng.random().int(u8); // R 通道随机
                nbytes[idx + 1] = rng.random().int(u8); // G 通道随机
                nbytes[idx + 2] = 0;
                nbytes[idx + 3] = 255;
            }
        }
        self.noise_texture = Wgpu.wgpuDeviceCreateTexture(self.gctx.device, &.{
            .usage = Wgpu.WGPUTextureUsage_CopyDst | Wgpu.WGPUTextureUsage_TextureBinding,
            .dimension = Wgpu.WGPUTextureDimension_2D,
            .size = .{ .width = nw, .height = nh, .depthOrArrayLayers = 1 },
            .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        Wgpu.wgpuQueueWriteTexture(
            self.gctx.queue,
            &Wgpu.WGPUTexelCopyTextureInfo{ .texture = self.noise_texture, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = 0 } },
            nbytes.ptr,
            nbytes.len,
            &Wgpu.WGPUTexelCopyBufferLayout{ .offset = 0, .bytesPerRow = nw * 4, .rowsPerImage = nh },
            &Wgpu.WGPUExtent3D{ .width = nw, .height = nh, .depthOrArrayLayers = 1 },
        );
        self.noise_texture_view = Wgpu.wgpuTextureCreateView(self.noise_texture, null);
    }
    self.noise_sampler = Wgpu.wgpuDeviceCreateSampler(self.gctx.device, &.{
        .addressModeU = Wgpu.WGPUAddressMode_Repeat,
        .addressModeV = Wgpu.WGPUAddressMode_Repeat,
        .addressModeW = Wgpu.WGPUAddressMode_Repeat,
        .magFilter = Wgpu.WGPUFilterMode_Linear,
        .minFilter = Wgpu.WGPUFilterMode_Linear,
        .maxAnisotropy = 1,
    });

    // SSR bind group：含颜色 + 深度 + 噪声纹理
    self.ssr_bind_group = Wgpu.wgpuDeviceCreateBindGroup(self.gctx.device, &Wgpu.WGPUBindGroupDescriptor{
        .layout = self.ssr_bgl,
        .entryCount = 5,
        .entries = &[_]Wgpu.WGPUBindGroupEntry{
            .{ .binding = 0, .textureView = self.ssr_color_view },
            .{ .binding = 1, .sampler = self.ssr_sampler },
            .{ .binding = 2, .textureView = self.depth_copy_view },
            .{ .binding = 3, .textureView = self.noise_texture_view },
            .{ .binding = 4, .sampler = self.noise_sampler },
        },
    });

    // 程序化天空（必须先于水管初始化，水管需引用其 bind_group_layout）
    self.sky_pipeline = try SkyPipeline.init(&self.gctx);

    // 水面管线（共享场景 uniform、阴影 bind group、天空 uniform）
    self.water_pipeline = try WaterPipeline.init(&self.gctx, self.render_pipeline.global_bgl, self.render_pipeline.shadow_bgl, self.ssr_bgl, self.sky_pipeline.bind_group_layout);

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

    // 加载游戏设置（含语言、玩家名）
    {
        const lang = loadSettingsLang(allocator);
        defer allocator.free(lang);
        // 加载语言文件，失败时逐级回退：指定语言 → en → key 本身
        if (i18n.init(allocator, lang)) {} else |_| {
            if (i18n.init(allocator, "en")) {} else |_| {}
        }
        self.player_name = loadSettingsName(allocator);
    }

    self.menu_state = .MainMenu;

    // 注册表哈希表（运行时名称查找用）
    registries.init(allocator);

    // 初始化动画系统
    self.server.animation_system = try AnimationSystem.init(allocator, self.gctx.device);

    // 为渲染管线设置骨骼矩阵缓冲
    self.render_pipeline.setBoneBuffer(self, self.server.animation_system.bone_pool_buffer);

    // 图标缓存 + 图标管线（传入 uniform 缓冲）
    self.icon_atlas = try IconAtlas.init(allocator, &self.gctx, self.ui_system.uniform_buffer);

    return self;
}

pub fn deinit(self: *@This()) void {
    // 最后释放自己
    defer self.allocator.destroy(self);

    self.res_manager.deinit(self.allocator);
    self.render_pipeline.deinit();
    self.water_pipeline.deinit(&self.gctx);
    Wgpu.wgpuTextureRelease(self.ssr_color_texture);
    Wgpu.wgpuTextureViewRelease(self.ssr_color_view);
    Wgpu.wgpuTextureRelease(self.depth_copy_texture);
    Wgpu.wgpuTextureViewRelease(self.depth_copy_view);
    Wgpu.wgpuTextureRelease(self.noise_texture);
    Wgpu.wgpuTextureViewRelease(self.noise_texture_view);
    Wgpu.wgpuSamplerRelease(self.noise_sampler);
    Wgpu.wgpuSamplerRelease(self.ssr_sampler);
    Wgpu.wgpuBindGroupRelease(self.ssr_bind_group);
    self.shadow_pipeline.deinit();
    self.sky_pipeline.deinit();
    self.wireframe_pipeline.deinit();
    self.ui_system.deinit();
    self.icon_atlas.deinit();
    self.gctx.deinit();
    self.window.deinit();
    i18n.deinit();
    if (self.player_name.len > 0) self.allocator.free(self.player_name);

    if (!self.game_cleaned and self.save_initialized and self.network.mode != .client) {
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
    Log.info(.startup, "startSave begin '{s}'", .{name});
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

    self.network.last_snapshot_serial = std.math.maxInt(u64);
    self.network.host_snap_valid = false;
    try self.initGame();
}

/// 联机客户端模式：不加载存档，只连接主机（极小化，跳过 ECS 避免崩溃）
pub fn startClient(self: *Game, host_ip: [4]u8) !void {
    self.game_cleaned = false;

    self.network.last_snapshot_serial = std.math.maxInt(u64);
    self.network.host_snap_valid = false;
    self.server.chunk_radius = 4;
    self.network.mode = .client;

    self.network.net_thread = null;
    self.network.net_running.store(true, .release);
    self.network.client_connected.store(false, .release);
    self.network.client_fd = undefined;

    const cfd = Network.connect(host_ip, Network.SERVER_PORT);
    if (cfd < 0) {
        Log.info(.startup, "connect failed", .{});
        return;
    }
    self.network.client_fd = cfd;
    self.network.client_connected.store(true, .release);

    // 接收 welcome 消息，获取分配的 player_id
    const assigned_id = Network.recvWelcome(cfd);
    Log.info(.game, "recvWelcome raw={}\n", .{assigned_id});
    self.server.player_id = assigned_id;
    Log.info(.startup, "connected as player_id={}", .{assigned_id});

    // 清空快照实体映射
    self.network.snapshot_info = .{};
    // DEBUG: 重置计数器
    self.network.state_count = 0;
    self.network.chunk_count = 0;
    self.network.noop_count = 0;
    self.network.state_serial_last = 0;
    self.network.state_serial_gaps = 0;
    self.network.latency_min_ns = 999_999_999;
    self.network.latency_max_ns = 0;
    self.network.latency_sum_ns = 0;
    self.network.latency_samples = 0;

    // 初始化空的 block_world（渲染需要）
    self.server.block_world = try BlockWorld.BlockWorld.init(self.allocator, &self.gctx, &self.render_pipeline, self.server.chunk_radius, "");

    // 启动 mesh worker（区块通过动态加载到达）
    self.server.block_world.spawnWorker() catch {};
    // 设置非阻塞超时
    Network.setRecvTimeout(@as(winsock.socket_t, @intCast(self.network.client_fd)));

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
        self.network.remote_player = entity;
    }

    self.menu_state = .Gameplay;
    self.save_initialized = true;
    self.accumulator = TICK_DT; // 强制第一帧执行一次 clientTick，设置相机位置
}

/// 返回主菜单（由暂停菜单调用）
pub fn returnToMenu(self: *Game) void {
    Log.info(.game, "returnToMenu CALLED, mode={any}, save_initialized={}, menu_state={}", .{ self.network.mode, self.save_initialized, @intFromEnum(self.menu_state) });
    if (self.network.mode != .client) {
        self.save_manager.savePlayer(self.player_name, &self.hotbar, &self.inventory, &self.server.registry, self.server.tick_count) catch |err| std.debug.print("savePlayer error: {}\n", .{err});
        self.save_manager.saveAllEntities(&self.server.registry) catch |err| std.debug.print("saveEntities error: {}\n", .{err});
        self.save_manager.saveAllChunks(&self.server.block_world) catch |err| std.debug.print("saveChunks error: {}\n", .{err});
    }
    self.hotbar = .{};
    self.inventory = .{};
    // 停止网络线程
    if (self.network.net_thread) |t| {
        self.network.net_running.store(false, .release);
        if (self.network.listening) {
            self.network.listening = false;
            _ = winsock.closesocket(self.network.listen_fd);
        }
        t.join();
        self.network.net_thread = null;
    }
    // 关闭所有客户端连接
    for (self.network.clients.items) |c| _ = winsock.closesocket(c.fd);
    self.network.clients.deinit(self.allocator);
    self.network.clients = .empty;
    self.network.next_player_id = 1;
    self.network.render_snapshot_count = 0;
    self.network.last_snapshot_time_ns = 0;
    self.network.host_snap_valid = false;
    self.server.animation_system.next_bone_offset = 0;
    self.server.animation_system.max_bone_slot = 0;
    const was_client = self.network.mode == .client;
    self.network.mode = .single;
    self.network.client_connected.store(false, .release);

    // 客机：关闭 socket + 清理快照映射（主机由网络线程的 defer close 处理）
    if (was_client) {
        _ = winsock.closesocket(self.network.client_fd);
        self.network.snapshot_info.deinit(self.allocator);
        self.network.snapshot_info = .{};
    }
    self.network.client_fd = undefined;

    // 停止服务端线程
    self.server.stop();

    // 清理 AI 实体的寻路状态和路径内存（非客户端模式，此时 server 线程已停）
    if (self.network.mode != .client) {
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
    self.server.pending_block_updates.deinit(self.allocator);
    self.server.pending_drops.deinit(self.allocator);
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
    self.server.pending_block_updates = .empty;
    self.server.pending_drops = .empty;
    self.server.pending_unloads = .empty;
    self.server.player_chunks = .empty;
    self.server.snapshot_count = 0;
    self.server.snapshot_serial = 0;
    if (!was_client) self.save_manager.deinit();
    self.game_cleaned = true;
    self.save_initialized = false;
    self.server.player_id = 0;
    self.server.flying = false;
    self.menu_state = .MainMenu;
}

/// 运行一个物理 tick（纯逻辑，不碰渲染/输入）
fn tick(self: *Game) !void {
    // 收集玩家输入并投递到服务端线程
    const input = collectHostActions(self);
    try self.server.pushInput(input);

    // ── 联机：主机更新共享数据（供网络线程读取）──
    if (self.network.mode == .host) {
        // 客机断线由网络线程处理（关 socket + registry 清理 + 移出 clients 列表）
        // 主线程不做任何 ECS 操作，避免双重释放

        // 主机相机朝向（网络线程需读取，用于主机玩家快照）
        self.network.net_mutex.lockUncancelable(io);
        defer self.network.net_mutex.unlock(io);
        self.network.net_cam_yaw = self.camera.yaw;
        self.network.net_cam_pitch = self.camera.pitch;
    }
}

/// 联机：主机网络线程（接受客户端 + 循环收发）
fn hostNetworkThread(self: *Game) void {
    self.network.listen_fd = Network.listen(Network.SERVER_PORT);
    if (self.network.listen_fd < 0) {
        Log.err(.network, "network: listen failed", .{});
        return;
    }
    self.network.listening = true;
    defer {
        if (self.network.listening) {
            self.network.listening = false;
            _ = winsock.closesocket(self.network.listen_fd);
        }
    }

    var print_timer: u32 = 0;
    while (self.network.net_running.load(.acquire)) {
        if (print_timer == 0) {
            Log.info(.network, "network: {} client(s) connected", .{self.network.clients.items.len});
            print_timer = 200; // 每 ~6 秒打印一次（select 通常 ~33ms 返回一次）
        }
        print_timer -= 1;

        // ── 构建 fd_set（listen + 所有客户端） ──
        var readfds = winsock.fd_set{
            .fd_count = 0,
            .fd_array = [_]usize{0} ** winsock.FD_SETSIZE,
        };
        var max_fd: winsock.socket_t = self.network.listen_fd;
        winsock.FD_SET(self.network.listen_fd, &readfds);
        for (self.network.clients.items) |c| {
            winsock.FD_SET(c.fd, &readfds);
            if (c.fd > max_fd) max_fd = c.fd;
        }
        var tv = winsock.timeval{ .sec = 0, .usec = 100000 };
        const sel_rc = winsock.select(max_fd + 1, &readfds, null, null, &tv);
        if (sel_rc < 0) {
            if (self.network.net_running.load(.acquire)) Log.err(.network, "network: select error", .{});
            return;
        }

        // ── 处理新连接 ──
        if (winsock.FD_ISSET(self.network.listen_fd, &readfds)) {
            const cfd = winsock.accept(self.network.listen_fd, null, null);
            if (cfd >= 0 and self.network.net_running.load(.acquire)) {
                const pid = self.network.next_player_id;
                self.network.next_player_id += 1;

                // 创建远程玩家实体
                const pinfo = EntityTypeId.fromName("player").info();
                const entity = self.server.registry.create();
                self.server.registry.add(entity, Comps.Player{ .id = pid, .mode = .survival });
                self.server.registry.add(entity, Comps.ModelName{ .id = pinfo.model_id });
                const spawn_pos = if (self.network.net_saved_client_pos.x != 0 or self.network.net_saved_client_pos.y != 0 or self.network.net_saved_client_pos.z != 0)
                    self.network.net_saved_client_pos
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
                        .clip_name = ClipName.idle.toString(),
                        .bone_offset = bone_offset,
                    });
                }
                self.network.clients.append(self.server.allocator, .{
                    .fd = cfd,
                    .entity = entity,
                    .player_id = pid,
                    .disconnect = false,
                    .saved_pos = spawn_pos,
                }) catch {};
                Network.sendWelcome(cfd, pid);
                Log.info(.network, "network: player joined as id={}, fd={}", .{ pid, cfd });
            } else if (cfd >= 0) {
                _ = winsock.closesocket(cfd);
            }
        }

        // ── 处理客户端输入 ──
        for (self.network.clients.items) |*c| {
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
                .attack_entity = input.attack_entity,
                .attack_target_raw = input.attack_target_raw,
            }) catch {};
        }

        // ── 读取共享数据（一次拷贝，遍历发送） ──
        self.network.net_mutex.lockUncancelable(io);
        const cam_yaw = self.network.net_cam_yaw;
        const cam_pitch = self.network.net_cam_pitch;
        self.server.pending_chunks_mutex.lockUncancelable(io);
        var chunks_to_send = self.server.pending_chunks;
        self.server.pending_chunks = .empty;
        self.server.pending_chunks_mutex.unlock(io);
        self.network.net_mutex.unlock(io);

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

        // 取出方块更新和掉落（一次读出，所有客户端共享）
        self.server.pending_block_updates_mutex.lockUncancelable(io);
        var block_updates = self.server.pending_block_updates;
        self.server.pending_block_updates = .empty;
        self.server.pending_block_updates_mutex.unlock(io);
        self.server.pending_drops_mutex.lockUncancelable(io);
        var pending_drops = self.server.pending_drops;
        self.server.pending_drops = .empty;
        self.server.pending_drops_mutex.unlock(io);

        // ── 遍历所有客户端，各自发送 ──
        var ci: usize = 0;
        while (ci < self.network.clients.items.len) {
            const c = &self.network.clients.items[ci];
            if (c.disconnect) {
                // 断线清理
                _ = winsock.closesocket(c.fd);
                if (self.server.registry.valid(c.entity)) {
                    self.server.block_world.cleanupEntity(&self.server.registry, c.entity);
                    self.server.registry.destroy(c.entity);
                }
                // 从 player_chunks 中移除
                _ = self.server.player_chunks.remove(c.player_id);
                Log.info(.network, "client id={} disconnected", .{c.player_id});
                _ = self.network.clients.swapRemove(ci);
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

            c.saved_pos = self.network.net_saved_client_pos;
            ci += 1;
        }
        chunks_to_send.deinit(self.server.allocator);

        // ── 发送 state 给所有在线客户端 ──
        const now_ns = @as(i64, @truncate(std.Io.Timestamp.now(io, .awake).nanoseconds));
        for (self.network.clients.items) |*c| {
            const state_serial = self.server.tick_count;
            // 过滤掉 origin=自己的 block_update（已由本地预测处理）
            var filtered_bu: std.ArrayListUnmanaged(Network.BlockUpdate) = .empty;
            defer filtered_bu.deinit(self.server.allocator);
            for (block_updates.items) |*u| {
                if (u.origin_player_id != c.player_id)
                    filtered_bu.append(self.server.allocator, u.*) catch {};
            }
            // 过滤出该客户端的掉落
            var filtered_drops: std.ArrayListUnmanaged(Network.DropUpdate) = .empty;
            defer filtered_drops.deinit(self.server.allocator);
            for (pending_drops.items) |*d| {
                if (d.target_player_id == c.player_id)
                    filtered_drops.append(self.server.allocator, d.*) catch {};
            }
            Network.sendState(c.fd, &.{
                .serial = @truncate(state_serial),
                .tick_count = snap_tick,
                .host_time = now_ns,
                .entities = snapshots[0..count],
                .block_updates = filtered_bu.items,
                .drops = filtered_drops.items,
            });
        }
        block_updates.deinit(self.server.allocator);
        pending_drops.deinit(self.server.allocator);

        // ── 发送卸载指令给所有客户端 ──
        self.server.pending_unloads_mutex.lockUncancelable(io);
        var unloads = self.server.pending_unloads;
        self.server.pending_unloads = .empty;
        self.server.pending_unloads_mutex.unlock(io);
        defer unloads.deinit(self.server.allocator);
        for (self.network.clients.items) |c| {
            for (unloads.items) |origin| {
                Network.sendChunkUnload(c.fd, origin.x, origin.z);
            }
        }
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
/// 左键：同时检测实体和方块，谁近打谁
/// attack_target_raw：输出命中的服务端实体标识（客机用，host 模式忽略）
fn predictBlockAction(self: *Game, target: *Vec3i, place_face: *u8, attack_target_raw: *u32) void {
    if (self.break_once) {
        const ray = Raycast.Ray.init(self.camera.position, self.camera.front);
        const block_hit = Raycast.raycastWorld(&self.server.block_world, ray, 8.0);
        var entity_hit: ?ECS.Entity = null;
        var entity_dist: f32 = 8.0;
        // 遍历注册表检测实体（依赖 BVH 不可靠，直接迭代 Position+Collider）
        {
            var ev = self.server.registry.view(.{ Comps.Position, Comps.Collider }, .{});
            var ei = ev.entityIterator();
            while (ei.next()) |e| {
                const epos = ev.get(Comps.Position, e);
                const ecol = ev.get(Comps.Collider, e);
                const half = ecol.width / 2.0;
                const t = Raycast.rayAABBEx(epos.vec.x - half, epos.vec.x + half, epos.vec.y, epos.vec.y + ecol.height, epos.vec.z - half, epos.vec.z + half, ray.origin, ray.direction);
                if (t == null or t.? > entity_dist or t.? <= 0) continue;
                entity_hit = e;
                entity_dist = t.?;
            }
        }

        if (entity_hit) |e| {
            if (!block_hit.hit or entity_dist < block_hit.distance) {
                // 检查是否自伤
                const is_self = if (self.server.registry.tryGet(Comps.Player, e)) |p| p.id == self.server.player_id else false;
                if (!is_self) {
                    // 主机模式：本地应用伤害
                    if (self.network.mode != .client) {
                        if (self.server.registry.tryGet(Comps.Health, e)) |health| {
                            health.current -= 10;
                            // 受击逃跑
                            if (self.server.registry.tryGet(Comps.AIAgent, e)) |agent| {
                                if (agent.type_id.info().flee_on_attack) {
                                    agent.state = .fleeing;
                                    agent.flee_timer = 5.0;
                                }
                            }
                            if (health.current <= 0) {
                                if (self.server.registry.tryGet(Comps.AIAgent, e)) |agent| {
                                    const rolls = Drops.rollEntityDrops(@as(usize, agent.type_id.id));
                                    for (rolls.items[0..rolls.count]) |r| tryItemToInventory(self, r.item_id, r.count);
                                }
                                self.server.block_world.cleanupEntity(&self.server.registry, e);
                                self.server.registry.destroy(e);
                            }
                        }
                    }
                    // 输出服务端实体标识
                    if (self.network.mode == .client) {
                        var iter = self.network.snapshot_info.iterator();
                        while (iter.next()) |entry| {
                            if (std.meta.eql(entry.value_ptr.*.entity, e)) {
                                attack_target_raw.* = entry.value_ptr.*.server_entity_raw;
                                break;
                            }
                        }
                    } else {
                        attack_target_raw.* = @as(u32, @bitCast(e));
                    }
                }
            }
        } else if (block_hit.hit) {
            target.* = block_hit.block_pos;
            self.server.block_world.setBlock(block_hit.block_pos, BlockState.fromName("air")) catch {};
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
                // 检查是否与实体重叠（注释掉 if (!can_place) return; 即可关闭）
                var can_place = true;
                {
                    const block_box = AABB{
                        .min_x = @as(f32, @floatFromInt(place_pos.x)),
                        .max_x = @as(f32, @floatFromInt(place_pos.x + 1)),
                        .min_y = @as(f32, @floatFromInt(place_pos.y)),
                        .max_y = @as(f32, @floatFromInt(place_pos.y + 1)),
                        .min_z = @as(f32, @floatFromInt(place_pos.z)),
                        .max_z = @as(f32, @floatFromInt(place_pos.z + 1)),
                    };
                    var ev = self.server.registry.view(.{ Comps.Position, Comps.Collider }, .{});
                    var ei = ev.entityIterator();
                    while (ei.next()) |entity| {
                        const epos = ev.get(Comps.Position, entity);
                        const ecol = ev.get(Comps.Collider, entity);
                        const ebox = BlockWorld.BlockWorld.getEntityAABB(epos.vec, ecol);
                        if (ebox.min_x < block_box.max_x and ebox.max_x > block_box.min_x and
                            ebox.min_y < block_box.max_y and ebox.max_y > block_box.min_y and
                            ebox.min_z < block_box.max_z and ebox.max_z > block_box.min_z)
                        {
                            can_place = false;
                            break;
                        }
                    }
                }
                // if (!can_place) return; // ← 注释这行关闭实体重叠检查
                target.* = place_pos;
                place_face.* = @intFromEnum(facing);
                self.server.block_world.setBlock(place_pos, BlockState{ .block_id = BlockId.fromInt(sel.item_id), .facing = facing }) catch {};
            }
        }
    }
}

/// 采集主机玩家的动作（break/place/fly/camera），通过服务端队列处理
fn collectHostActions(self: *Game) PlayerInput {
    const wants_fly = self.network.server_wants_fly;
    self.network.server_wants_fly = false;
    defer {
        self.break_once = false;
        self.place_once = false;
    }

    var target = Vec3i.zero;
    var place_face: u8 = 0;
    var attack_raw: u32 = 0;
    predictBlockAction(self, &target, &place_face, &attack_raw);

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
    self.network._tick_start_ns = @as(i64, @truncate(std.Io.Timestamp.now(io, .awake).nanoseconds));

    var intent: Network.ClientInput = undefined;
    intent.serial = @truncate(self.server.tick_count);
    // 清零目标坐标/朝向（避免 undefined 垃圾被发给服务器）
    intent.target = Vec3i.zero;
    intent.place_face = 0;

    // 设置移动意图（WASD），复用服务端物理系统
    // 键盘 → MoveIntent（与主机/单人游戏一致的逻辑）
    produceMoveIntent(self);
    // 飞行切换（双击空格）
    if (self.network.server_wants_fly) {
        self.network.server_wants_fly = false;
        const rp = self.network.remote_player.?;
        if (self.server.registry.has(Comps.Flying, rp)) {
            _ = self.server.registry.remove(Comps.Flying, rp);
        } else {
            self.server.registry.add(rp, Comps.Flying{});
        }
    }
    // 跑本地物理（碰撞、重力）——客机：只推自己 ID 匹配的玩家实体
    self.server.block_world.updatePhysics(&self.server.registry, TICK_DT, true, self.server.player_id);
    // 推入环缓冲（相机插值用，与主机逻辑统一）
    if (self.server.registry.tryGet(Comps.Position, self.network.remote_player.?)) |pos2| pushEntityPos(pos2, pos2.vec);
    // 读取物理运算后的位置，提交给服务器
    if (self.server.registry.tryGet(Comps.Position, self.network.remote_player.?)) |pos| {
        intent.pos = pos.vec;
    }
    intent.cam_yaw = self.camera.yaw;
    intent.cam_pitch = self.camera.pitch;

    // 本地预测（与主机 collectHostActions 共用 predictBlockAction）
    var attack_raw: u32 = 0;
    predictBlockAction(self, &intent.target, &intent.place_face, &attack_raw);
    intent.break_block = self.break_once;
    intent.place_block = self.place_once;
    self.break_once = false;
    self.place_once = false;
    intent.hotbar_slot = self.hotbar.selected;
    if (attack_raw != 0) {
        intent.attack_entity = true;
        intent.attack_target_raw = attack_raw;
    }

    Network.sendInput(@as(winsock.socket_t, @intCast(self.network.client_fd)), &intent);
}

/// 客机：每帧收包，更新实体位置（独立于 30Hz clientTick）
fn clientReceivePackets(self: *Game) void {
    var state: Network.ServerState = undefined;
    var state_initialized = false;

    // 一次性读完所有可用的包
    while (true) {
        var readfds = winsock.fd_set{
            .fd_count = 1,
            .fd_array = [_]usize{@as(usize, @intCast(self.network.client_fd))} ** winsock.FD_SETSIZE,
        };
        var tv = winsock.timeval{ .sec = 0, .usec = 0 };
        const sel_rc = winsock.select(0, &readfds, null, null, &tv);
        if (sel_rc < 0) break;
        if (sel_rc == 0) break; // 无数据，下帧再试
        const tag = Network.peekTag(self.network.client_fd);
        if (tag == 0) {
            // select 说有数据但 peekTag 返回 0 → 连接已关闭
            self.returnToMenu();
            return;
        }
        if (tag == 2) {
            self.network.chunk_count += 1;
            const result = Network.recvChunk(self.network.client_fd, self.allocator);
            if (result == null) {
                self.returnToMenu();
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
            // 释放上一个 state 的 entities 和 drops
            if (state_initialized) {
                self.allocator.free(state.entities);
                if (state.drops.len > 0) self.allocator.free(state.drops);
            }

            const got = Network.recvState(self.network.client_fd, self.allocator, &state);
            if (!got) {
                self.returnToMenu();
                return;
            }
            state_initialized = true;
            self.server.tick_count = state.tick_count;

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
            // 处理掉落（target_player_id == self 时加入背包）
            for (state.drops) |drop| {
                if (drop.target_player_id == self.server.player_id) {
                    tryItemToInventory(self, drop.item_id, drop.count);
                }
            }
            if (state.drops.len > 0) {
                self.allocator.free(state.drops);
                state.drops = &.{};
            }
        } else if (tag == 3) {
            const unload = Network.recvChunkUnload(self.network.client_fd);
            if (unload) |u| {
                self.server.block_world.unloadChunk(Vec3i.new(u.x, 0, u.z));
            }
        } else break;
    }

    if (!state_initialized) return;
    defer {
        self.allocator.free(state.entities);
        if (state.drops.len > 0) self.allocator.free(state.drops);
    }

    // 复制到渲染快照缓冲区
    self.network.render_snapshot_count = @as(u32, @intCast(state.entities.len));
    @memcpy(std.mem.sliceAsBytes(self.network.render_snapshots[0..self.network.render_snapshot_count]), std.mem.sliceAsBytes(state.entities));

    // 记录插值时间基准
    self.network.last_snapshot_time_ns = @as(i64, @truncate(std.Io.Timestamp.now(io, .awake).nanoseconds));
    const now_ns = self.network.last_snapshot_time_ns;
    const latency_ns = now_ns - state.host_time;
    if (latency_ns >= 0) {
        self.network.latency_min_ns = @min(self.network.latency_min_ns, latency_ns);
        self.network.latency_max_ns = @max(self.network.latency_max_ns, latency_ns);
        self.network.latency_sum_ns += latency_ns;
        self.network.latency_samples += 1;
    }

    var server_raw_set: [64]u32 = undefined;
    var server_raw_count: usize = 0;
    for (state.entities) |snap| {
        const server_raw = @as(u32, @bitCast(snap.entity));
        if (server_raw_count < 64) {
            server_raw_set[server_raw_count] = server_raw;
            server_raw_count += 1;
        }
        if (snap.player_id == self.server.player_id) {
            if (self.server.registry.tryGet(Comps.Facing, self.network.remote_player.?)) |facing| {
                facing.yaw = snap.facing_yaw;
                facing.pitch = snap.facing_pitch;
            }
            continue;
        }
        const key = @as(u64, server_raw);
        const gop = self.network.snapshot_info.getOrPut(self.allocator, key) catch continue;
        if (!gop.found_existing) {
            const etype = EntityTypeId.fromInt(snap.entity_type_id);
            const einfo = etype.info();
            const entity = self.server.registry.create();
            self.server.registry.add(entity, Comps.ModelName{ .id = einfo.model_id });
            self.server.registry.add(entity, Comps.Position{ .vec = snap.pos, .prev = snap.pos });
            if (self.server.registry.tryGet(Comps.Position, entity)) |pp| pushEntityPos(pp, snap.pos);
            self.server.registry.add(entity, Comps.Collider{ .width = einfo.collider_width, .height = einfo.collider_height });
            self.server.registry.add(entity, Comps.Velocity{ .vec = Vec3.zero });
            self.server.registry.add(entity, Comps.Facing{});
            if (self.server.animation_system.allocBoneSlot()) |bone_offset| {
                self.server.registry.add(entity, Comps.AnimationState{
                    .clip_name = ClipName.fromId(snap.clip_name_id).toString(),
                    .bone_offset = bone_offset,
                });
            }
            gop.value_ptr.* = .{ .entity = entity, .player_id = snap.player_id, .server_entity_raw = server_raw };
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
            // 同步 clip_name
            if (self.server.registry.tryGet(Comps.AnimationState, gop.value_ptr.*.entity)) |anim| {
                anim.clip_name = ClipName.fromId(snap.clip_name_id).toString();
            }
        }
    }

    // 清理已不存在的实体
    {
        var keys_to_remove: std.ArrayListUnmanaged(u64) = .empty;
        defer keys_to_remove.deinit(self.allocator);
        var iter = self.network.snapshot_info.keyIterator();
        while (iter.next()) |k| {
            // 如果服务端句柄不在当前快照中，则销毁
            var found = false;
            for (server_raw_set[0..server_raw_count]) |raw| {
                if (raw == k.*) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                keys_to_remove.append(self.allocator, k.*) catch {};
            }
        }
        for (keys_to_remove.items) |k| {
            if (self.network.snapshot_info.getPtr(k)) |e| {
                self.server.registry.destroy(e.*.entity);
            }
            _ = self.network.snapshot_info.remove(k);
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
                        .clip_name = ClipName.idle.toString(),
                        .bone_offset = bone_offset,
                    });
                }
            }
        }
    }
    self.server.animation_system.update(&self.server.registry, &self.res_manager, TICK_DT);
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
    if (serial == self.network.last_snapshot_serial) return;
    self.network.last_snapshot_serial = serial;

    self.server.snapshot_mutex.lockUncancelable(io);
    defer self.server.snapshot_mutex.unlock(io);
    const snapshots = self.server.snapshots[0..self.server.snapshot_count];

    // 复制到渲染快照缓冲区（供 render.zig 使用，避免 ECS view 迭代竞态）
    self.network.render_snapshot_count = @as(u32, @intCast(snapshots.len));
    @memcpy(std.mem.sliceAsBytes(self.network.render_snapshots[0..self.network.render_snapshot_count]), std.mem.sliceAsBytes(snapshots));

    // 主机：推入实体 3 槽环形缓冲区
    if (self.network.mode != .client) {
        for (snapshots) |s| {
            const entity = s.entity;
            if (!self.server.registry.valid(entity)) continue;
            if (self.server.registry.tryGet(Comps.Position, entity)) |pos| {
                if (!self.network.host_snap_valid) {
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
        self.network.last_snapshot_time_ns = @as(i64, @truncate(std.Io.Timestamp.now(io, .awake).nanoseconds));
        self.network.host_snap_valid = true;
    }

    // 主机/单人：动画更新（主线程，与服务端分离）
    if (self.network.mode != .client) {
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
            const render_pos = pos.interpPos(rend_time);
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
        std.debug.print("Inventory full, lost {d}x item_id={d}\n", .{ remaining, item_id });
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
const Drops = @import("drops.zig");
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
const i18n = @import("i18n.zig");

/// 从 settings.json 读取语言设置，失败时返回 "zh"（堆分配，调用方需 free）
fn loadSettingsLang(allocator: std.mem.Allocator) []const u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, "config/settings.json", allocator, .limited(4096)) catch {
        return allocator.dupe(u8, "zh") catch "zh";
    };
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        return allocator.dupe(u8, "zh") catch "zh";
    };
    defer parsed.deinit();
    if (parsed.value.object.get("language")) |v| {
        return allocator.dupe(u8, v.string) catch "zh";
    }
    return allocator.dupe(u8, "zh") catch "zh";
}

/// 从 settings.json 读取玩家名，失败时返回随机名
fn loadSettingsName(allocator: std.mem.Allocator) []const u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, "config/settings.json", allocator, .limited(4096)) catch {
        return randomPlayerName(allocator);
    };
    defer allocator.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        return randomPlayerName(allocator);
    };
    defer parsed.deinit();
    if (parsed.value.object.get("player_name")) |v| {
        return allocator.dupe(u8, v.string) catch randomPlayerName(allocator);
    }
    return randomPlayerName(allocator);
}

fn randomPlayerName(allocator: std.mem.Allocator) []const u8 {
    var buf: [4]u8 = undefined;
    io.random(&buf);
    const suffix = std.mem.readInt(u32, &buf, .little) % 10000;
    return std.fmt.allocPrint(allocator, "user_{d}", .{suffix}) catch "user_0";
}
