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
sky_pipeline: SkyPipeline,
shadow_pipeline: ShadowPipeline,
camera: Camera3D,
ubo: SceneUniform,
player_id: u32 = 0,
player_name: []const u8 = "", // 当前用户名（由 config/user_name.json 加载）
hotbar: Hotbar,
inventory: PlayerInventory = .{},
selected_item: ?SelectedItem = null,
save_manager: SaveManager,
icon_atlas: IconAtlas,
block_world: BlockWorld.BlockWorld,
chunk_radius: i32, // 加载区块半径（chunk 数），实际加载 (2*radius+1)² 个
flying: bool = false,
last_space_press: f64 = 0.0,
accumulator: f32 = 0, // 物理 tick 时间余量，用于渲染插值
frame_timer: std.time.Instant, // 帧计时器，独立于 GLFW
fps_buffer: [120]f32 = undefined, // 2 秒 FPS 窗口
fps_idx: u32 = 0,
fps_avg: f32 = 0,
tick_count: u64 = 0, // 逻辑 tick 计数，1 tick = 1/30s
sprint_toggled: bool = false, // 冲刺开关，渲染层触发，tick 层读取
keybinds: Keybinds,
animation_system: AnimationSystem,
save_initialized: bool = false, // 延迟初始化：选存档后才加载游戏
game_cleaned: bool = false, // returnToMenu 已清理 gameplay 资源，阻止 deinit 重复释放
menu_state: MenuState = .MainMenu,

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
                    self.tick_count -|= half_hour;
                    self.accumulator = 0;
                }
                if (self.input.isKeyJustPressed(.equal)) {
                    const half_hour = @as(u64, @intFromFloat(self.sky_pipeline.day_length / TICK_DT / 48));
                    self.tick_count += half_hour;
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
            const now = try std.time.Instant.now();
            const dt_ns = now.since(self.frame_timer);
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
                // 保存上一帧的位置用于渲染插值
                {
                    var pv = self.registry.view(.{Comps.Position}, .{});
                    var pi = pv.entityIterator();
                    while (pi.next()) |e| {
                        var p = pv.get(e);
                        p.prev = p.vec;
                    }
                }
                // 骨骼矩阵 double buffer 交换
                self.animation_system.swapBuffers();
            }

            while (self.accumulator >= TICK_DT) {
                self.accumulator -= TICK_DT;
                if (self.menu_state != .Pause) {
                    self.tick_count += 1;
                    produceMoveIntent(self);
                    self.block_world.updatePhysics(&self.registry, TICK_DT);
                    {
                        var pview = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
                        var piter = pview.entityIterator();
                        while (piter.next()) |entity| {
                            const player = pview.get(Comps.Player, entity);
                            if (player.id == self.player_id) {
                                const ppos = pview.get(Comps.Position, entity);
                                BlockWorld.BlockWorld.updateAIAgent(&self.registry, ppos.vec);
                                break;
                            }
                        }
                    }
                    self.block_world.updateAI(&self.registry, TICK_DT);
                    try updateEntities(self);
                    try updateChunks(self);
                    // 动画更新（物理 tick 层）
                    self.animation_system.update(&self.registry, &self.res_manager, TICK_DT);
                }
            }

            // 根据水平速度更新实体朝向
            {
                var fv = self.registry.view(.{ Comps.Velocity, Comps.Facing }, .{});
                var fi = fv.entityIterator();
                while (fi.next()) |entity| {
                    const vel = fv.get(Comps.Velocity, entity);
                    const facing = fv.get(Comps.Facing, entity);
                    const h_speed = @sqrt(vel.vec.x * vel.vec.x + vel.vec.z * vel.vec.z);
                    if (h_speed > 0.01) {
                        facing.yaw = std.math.atan2(vel.vec.x, vel.vec.z);
                    }
                }
            }

            if (self.menu_state == .Gameplay or self.menu_state == .Inventory) {
                // 骨骼矩阵插值并上传到 GPU
                self.animation_system.upload(self.gctx.queue, self.accumulator / TICK_DT);
                syncCameraFromPlayer(self);
            }

            if (self.menu_state == .Gameplay) {
                handleFlightToggle(self);
                self.camera.updateFromMouse(self);
                if (self.keybinds.isJustPressed(&self.input, .sprint_toggle))
                    self.sprint_toggled = !self.sprint_toggled;
                if (self.keybinds.isJustPressed(&self.input, .break_block))
                    try handleLeftClick(self);
                if (self.keybinds.isJustPressed(&self.input, .place_block))
                    try tryPlaceBlock(self);

                // - 时间倒退 0.5 小时，= 时间前进 0.5 小时
                if (self.input.isKeyJustPressed(.minus)) {
                    const half_hour = @as(u64, @intFromFloat(self.sky_pipeline.day_length / TICK_DT / 48));
                    self.tick_count -|= half_hour;
                    self.accumulator = 0;
                }
                if (self.input.isKeyJustPressed(.equal)) {
                    const half_hour = @as(u64, @intFromFloat(self.sky_pipeline.day_length / TICK_DT / 48));
                    self.tick_count += half_hour;
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
            try self.block_world.processCompletedBuilds();
            try self.block_world.processCompletedLoads();
            self.block_world.processCompletedSaves();
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
    const far = @as(f32, @floatFromInt(self.chunk_radius)) * @as(f32, @floatFromInt(BlockWorld.CHUNK_WIDTH)) * 1.5 + BlockWorld.CHUNK_WIDTH * 4;
    self.ubo.proj_matrix = Mat4.perspectiveReversedZ(70, aspect, 0.01, far);
}

/// 选存档后初始化游戏世界（玩家实体、区块、存档数据）
fn initGame(self: *Game) !void {
    const player_entity = self.registry.create();
    self.registry.add(player_entity, Comps.Player{ .id = self.player_id, .mode = .creative });
    self.registry.add(player_entity, Comps.Position{ .vec = Vec3.new(8, 130, 8), .prev = Vec3.zero });
    self.registry.add(player_entity, Comps.Velocity{ .vec = Vec3.zero });
    self.registry.add(player_entity, Comps.Collider{ .width = 0.6, .height = 1.8 });
    self.registry.add(player_entity, Comps.MoveSpeed{ .value = 4.0 });
    self.registry.add(player_entity, Comps.JumpVelocity{ .value = 14.0 });
    self.registry.add(player_entity, Comps.OnGround{ .value = false });
    self.registry.add(player_entity, Comps.Facing{});
    self.registry.add(player_entity, Comps.MoveIntent{});
    self.registry.add(player_entity, Comps.Health{ .current = 100, .max = 100 });
    self.registry.add(player_entity, Comps.SpawnPos{ .pos = Vec3.new(8, 130, 8) });

    // { // 调试：生成一个静态模型验证光照方向
    //     const debug_entity = self.registry.create();
    //     self.registry.add(debug_entity, Comps.ModelName{ .id = RendCTX.ModelId.fromName("CesiumMan") });
    //     self.registry.add(debug_entity, Comps.Position{ .vec = Vec3.new(0, 200, 0), .prev = Vec3.new(0, 200, 0) });
    //     self.registry.add(debug_entity, Comps.Collider{ .width = 1.0, .height = 1.0 });
    // }

    // 先恢复玩家存档位置（如果有存档）--- 必须在加载区块之前
    // 原因：区块需要围绕玩家实际所在位置加载，而不是硬编码的 (8,8)。
    // 如果调换顺序，玩家位置附近的区块未加载 → getBlockAt 全返回 air → 自由落体。
    if (try self.save_manager.loadPlayer(self.player_name, &self.hotbar, &self.inventory, &self.registry)) |tc| {
        self.tick_count = tc;
    }

    // 以玩家实际位置为中心加载区块
    {
        const player_center: Vec3 = blk: {
            var pv = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
            var pi = pv.entityIterator();
            if (pi.next()) |entity| {
                const p = pv.get(Comps.Player, entity);
                if (p.id == self.player_id) {
                    break :blk pv.get(Comps.Position, entity).vec;
                }
            }
            break :blk Vec3.new(8, 130, 8);
        };
        const player_origin = BlockWorld.BlockWorld.chunkOrigin(
            @intFromFloat(@floor(player_center.x)),
            @intFromFloat(@floor(player_center.z)),
        );
        const load_range: i32 = self.chunk_radius;
        const load_range_sq = load_range * load_range;
        var dx: i32 = -load_range;
        while (dx <= load_range) : (dx += 1) {
            var dz: i32 = -load_range;
            while (dz <= load_range) : (dz += 1) {
                if (dx * dx + dz * dz > load_range_sq) continue;
                try self.block_world.loadChunk(.new(
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
        while (self.block_world.pendingIOCount() > 0 or self.block_world.pendingCount() > 0) {
            self.window.pollEvents();
            self.block_world.processCompletedLoads() catch {};
            self.block_world.processCompletedBuilds() catch {};
            self.block_world.processCompletedSaves();
            std.Thread.yield() catch {};
            const cur = self.block_world.pendingIOCount();
            if (cur != last_pending) {
                last_pending = cur;
                self.ui_system.beginFrame();
                Loading.draw(self);
                self.ui_system.endFrame(&self.gctx) catch {};
                Render.drawUI(self);
            }
        }
    }

    {
        var view = self.registry.view(.{ Comps.Player, Comps.Flying }, .{});
        var iter = view.entityIterator();
        if (iter.next()) |_| self.flying = true;
    }

    self.save_manager.loadAllEntities(&self.registry) catch |err| std.debug.print("loadEntities error: {}\n", .{err});

    // 为存档加载的实体补加动画状态
    {
        var anim_view = self.registry.view(.{Comps.ModelName}, .{});
        var anim_iter = anim_view.entityIterator();
        while (anim_iter.next()) |ent| {
            if (!self.registry.has(Comps.AnimationState, ent)) {
                if (self.animation_system.allocBoneSlot()) |bone_offset| {
                    self.registry.add(ent, Comps.AnimationState{
                        .clip_name = @import("rend_ctx.zig").ClipName.walk,
                        .bone_offset = bone_offset,
                    });
                }
            }
        }
    }

    self.save_initialized = true;
}

pub fn init(allocator: std.mem.Allocator) !*@This() {
    var self = try allocator.create(@This());
    self.allocator = allocator;
    self.tick_count = 0;
    // 创建窗口
    const window = try Window.init(self, "ZigGame", 1280, 720);
    self.window = window;

    // 初始化输入系统
    const input = Input.init(self);
    self.input = input;
    self.frame_timer = try std.time.Instant.now();
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
    self.registry = registry;
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
    self.animation_system = try AnimationSystem.init(allocator, self.gctx.device);

    // 为渲染管线设置骨骼矩阵缓冲
    self.render_pipeline.setBoneBuffer(self, self.animation_system.bone_pool_buffer);

    // 图标缓存 + 图标管线（传入 uniform 缓冲）
    self.icon_atlas = try IconAtlas.init(allocator, &self.gctx, self.ui_system.uniform_buffer);
    // 存档系统、BlockWorld、worker 线程在用户选择存档后才初始化（initGame/startSave）

    // 加载/创建用户配置
    {
        const cfg_dir = "config";
        const cfg_path = "config/user_name.json";
        var file = std.fs.cwd().readFileAlloc(allocator, cfg_path, 1024) catch {
            // 不存在则创建
            const random_suffix = std.crypto.random.int(u32) % 10000;
            const default_name = try std.fmt.allocPrint(allocator, "user_{d}", .{random_suffix});
            defer allocator.free(default_name);
            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(allocator);
            try buf.writer(allocator).print("{{ \"name\": \"{s}\" }}", .{default_name});
            std.fs.cwd().makePath(cfg_dir) catch {};
            var f = try std.fs.cwd().createFile(cfg_path, .{});
            defer f.close();
            try f.writeAll(buf.items);
            self.player_name = try allocator.dupe(u8, default_name);
            return self;
        };
        defer allocator.free(file);
        // 简易 JSON 解析：找 "name": "..."
        const name_mark = std.mem.indexOf(u8, file, "\"name\": \"") orelse {
            self.player_name = try allocator.dupe(u8, "Player");
            return self;
        };
        const name_start = name_mark + 9; // 跳过 "name": "
        const name_end = std.mem.indexOfScalar(u8, file[name_start..], '"') orelse {
            self.player_name = try allocator.dupe(u8, "Player");
            return self;
        };
        self.player_name = try allocator.dupe(u8, file[name_start .. name_start + name_end]);
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

    if (!self.game_cleaned) {
        if (self.save_initialized) {
            // 退出前保存
            self.save_manager.savePlayer(self.player_name, &self.hotbar, &self.inventory, &self.registry, self.tick_count) catch |err| std.debug.print("savePlayer error: {}\n", .{err});
            self.save_manager.saveAllEntities(&self.registry) catch |err| std.debug.print("saveEntities error: {}\n", .{err});
            self.save_manager.saveAllChunks(&self.block_world) catch |err| std.debug.print("saveChunks error: {}\n", .{err});
            {
                var view = self.registry.view(.{Comps.AIAgent}, .{});
                var iter = view.entityIterator();
                while (iter.next()) |entity| {
                    self.block_world.cleanupEntity(&self.registry, entity);
                }
            }
            self.block_world.deinit();
            self.save_manager.deinit();
        }
        self.registry.deinit();
    }
    registries.deinit(self.allocator);
    self.animation_system.deinit();
}

/// 切换存档（由存档管理界面调用）
pub fn startSave(self: *Game, name: []const u8) !void {
    self.chunk_radius = 16;
    rebuildProjMatrix(self);
    self.save_manager = try SaveManager.init(self.allocator, name);
    // 如果是从 returnToMenu 回来的，需要重建 BlockWorld
    if (self.game_cleaned) {
        self.registry = ECS.Registry.init(self.allocator);
    }
    self.block_world = try BlockWorld.BlockWorld.init(self.allocator, &self.gctx, &self.render_pipeline, self.chunk_radius, name);
    try self.block_world.spawnWorker();
    try self.block_world.spawnAStarWorker();
    try self.block_world.spawnSaveWorker();
    self.hotbar = .{};
    self.inventory = .{};
    self.game_cleaned = false;
    try self.initGame();
}

/// 返回主菜单（由暂停菜单调用）
pub fn returnToMenu(self: *Game) void {
    // 保存当前游戏状态
    self.save_manager.savePlayer(self.player_name, &self.hotbar, &self.inventory, &self.registry, self.tick_count) catch |err| std.debug.print("savePlayer error: {}\n", .{err});
    self.save_manager.saveAllEntities(&self.registry) catch |err| std.debug.print("saveEntities error: {}\n", .{err});
    self.save_manager.saveAllChunks(&self.block_world) catch |err| std.debug.print("saveChunks error: {}\n", .{err});
    self.hotbar = .{};
    self.inventory = .{};
    // 清理 AI 实体的寻路状态和路径内存
    {
        var view = self.registry.view(.{Comps.AIAgent}, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            self.block_world.cleanupEntity(&self.registry, entity);
        }
    }
    // 释放 gameplay 子系统
    self.registry.deinit();
    self.block_world.deinit();
    self.save_manager.deinit();
    // 标记已清理，防止 deinit 重复释放
    self.game_cleaned = true;
    self.save_initialized = false;
    self.player_id = 0;
    self.flying = false;
}

fn produceMoveIntent(self: *Game) void {
    var view = self.registry.view(.{ Comps.Player, Comps.MoveIntent }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const player = view.get(Comps.Player, entity);
        if (player.id != self.player_id) continue;
        var intent = view.get(Comps.MoveIntent, entity);

        // 根据相机朝向计算水平基础方向向量
        const front_h = Vec3.new(self.camera.front.x, 0, self.camera.front.z).norm();
        const camera_right = self.camera.front.cross(self.camera.up);
        const right_h = Vec3.new(camera_right.x, 0, camera_right.z).norm();

        // WASD 水平输入
        var move_dir = Vec3.zero;
        if (self.keybinds.isHeld(&self.input, .forward)) move_dir = move_dir.add(front_h);
        if (self.keybinds.isHeld(&self.input, .back)) move_dir = move_dir.sub(front_h);
        if (self.keybinds.isHeld(&self.input, .left)) move_dir = move_dir.sub(right_h);
        if (self.keybinds.isHeld(&self.input, .right)) move_dir = move_dir.add(right_h);

        // 跳跃 + 水中上浮
        if (self.keybinds.isHeld(&self.input, .jump)) {
            intent.jump = true;
            move_dir.y = 1.0;
        }
        // 水中下潜
        if (self.keybinds.isHeld(&self.input, .swim_down)) {
            move_dir.y = -1.0;
        }

        // 无水平输入时，强制关闭冲刺
        const has_movement = self.keybinds.isHeld(&self.input, .forward) or
            self.keybinds.isHeld(&self.input, .back) or
            self.keybinds.isHeld(&self.input, .left) or
            self.keybinds.isHeld(&self.input, .right);
        if (!has_movement) {
            intent.sprint = false;
            self.sprint_toggled = false;
        } else {
            intent.sprint = self.sprint_toggled;
        }

        // 潜行（按住）
        if (self.keybinds.isHeld(&self.input, .sneak)) {
            intent.sneak = true;
            if (!self.flying) intent.sprint = false;
        } else {
            intent.sneak = false;
        }

        // 归一化后写入移动意图，供物理系统消费
        if (move_dir.len2() > 0.001) move_dir = move_dir.norm();
        intent.direction = move_dir;
    }
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
        const hit = Raycast.raycastWorld(&self.block_world, ray, 8.0);
        if (hit.hit) {
            const block = self.block_world.getBlockAt(Vec3.new(
                @as(f32, @floatFromInt(hit.block_pos.x)) + 0.5,
                @as(f32, @floatFromInt(hit.block_pos.y)) + 0.5,
                @as(f32, @floatFromInt(hit.block_pos.z)) + 0.5,
            ));
            const block_id = @intFromEnum(block);
            if (block_id == 0) return;

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

/// 双击空格切换飞行模式（0.3 秒内再次按下空格则添加/移除 Flying 组件）
fn handleFlightToggle(self: *Game) void {
    self.last_space_press -= self.window.delta_time;
    if (self.last_space_press < 0) self.last_space_press = 0;

    if (self.input.isKeyJustPressed(.space)) {
        if (self.last_space_press > 0) {
            // 找到玩家实体，切换 Flying 组件
            var view = self.registry.view(.{Comps.Player}, .{});
            var iter = view.entityIterator();
            while (iter.next()) |entity| {
                const player = view.get(entity);
                if (player.id == self.player_id) {
                    if (self.registry.has(Comps.Flying, entity)) {
                        self.registry.remove(Comps.Flying, entity);
                        self.flying = false;
                    } else {
                        self.registry.add(entity, Comps.Flying{});
                        self.flying = true;
                    }
                    break;
                }
            }
            self.last_space_press = 0;
        } else {
            self.last_space_press = 0.3;
        }
    }
}

fn syncCameraFromPlayer(self: *Game) void {
    var view = self.registry.view(.{ Comps.Player, Comps.Position, Comps.Collider }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const player = view.get(Comps.Player, entity);
        if (player.id == self.player_id) {
            const pos = view.get(Comps.Position, entity);
            const collider = view.get(Comps.Collider, entity);
            const eye_offset = Vec3.new(0, collider.height - 0.2, 0);
            const alpha = self.accumulator / TICK_DT;
            const eye = Vec3.lerp(pos.prev, pos.vec, alpha).add(eye_offset);
            self.camera.position = eye;
            self.ubo.camera_pos = self.camera.position;
            self.ubo.view_matrix = Mat4.lookAt(self.camera.position, self.camera.position.add(self.camera.front), self.camera.up);
            break;
        }
    }
}

fn handleLeftClick(self: *Game) !void {
    const ray = self.camera.getCursorRay();

    // 同时检测实体和方块，比较距离：谁近打谁（防止隔墙攻击实体）
    const entity_hit = Raycast.raycastEntities(&self.registry, &self.block_world.bvh, ray, 8.0);
    const block_hit = Raycast.raycastWorld(&self.block_world, ray, 8.0);

    if (entity_hit.hit and (!block_hit.hit or entity_hit.distance < block_hit.distance)) {
        const is_self = blk: {
            if (self.registry.tryGet(Comps.Player, entity_hit.entity)) |p| {
                break :blk p.id == self.player_id;
            }
            break :blk false;
        };
        if (!is_self) {
            if (self.registry.tryGet(Comps.Health, entity_hit.entity)) |health| {
                health.current -= 10;
                if (health.current <= 0) {
                    if (self.registry.tryGet(Comps.AIAgent, entity_hit.entity)) |agent| {
                        const rng = std.crypto.random;
                        for (registries.getEntityDrops(@intFromEnum(agent.type_id))) |d| {
                            if (rng.float(f32) >= d.probability) continue;
                            const extra: u32 = @intFromFloat(rng.float(f32) * @as(f32, @floatFromInt(d.max_count - d.min_count + 1)));
                            tryItemToInventory(self, d.item_id, d.min_count + extra);
                        }
                    }
                    self.block_world.cleanupEntity(&self.registry, entity_hit.entity);
                    self.registry.destroy(entity_hit.entity);
                }
            }
        }
    } else if (block_hit.hit) {
        const pos = Vec3.new(
            @as(f32, @floatFromInt(block_hit.block_pos.x)) + 0.5,
            @as(f32, @floatFromInt(block_hit.block_pos.y)) + 0.5,
            @as(f32, @floatFromInt(block_hit.block_pos.z)) + 0.5,
        );
        const block = self.block_world.getBlockAt(pos);
        const drops = registries.getBlockDrops(@intFromEnum(block));
        for (drops) |d| {
            if (std.crypto.random.float(f32) < d.probability) {
                const extra: u32 = @intFromFloat(std.crypto.random.float(f32) * @as(f32, @floatFromInt(d.max_count - d.min_count + 1)));
                tryItemToInventory(self, d.item_id, d.min_count + extra);
            }
        }
        try self.block_world.setBlock(
            block_hit.block_pos,
            .fromName("air"),
        );
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
    )).prototype().is_solid) return;

    // 放置方块的 AABB
    const block_box = AABB{
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
        const entity_box = BlockWorld.BlockWorld.getEntityAABB(pos.vec, collider);
        if (entity_box.min_x < block_box.max_x and entity_box.max_x > block_box.min_x and
            entity_box.min_y < block_box.max_y and entity_box.max_y > block_box.min_y and
            entity_box.min_z < block_box.max_z and entity_box.max_z > block_box.min_z)
        {
            can_place = false;
            break;
        }
    }

    if (!can_place) return;

    // 使用物品栏选中的物品放置，空气跳过
    const selected_item_id = self.hotbar.slots[self.hotbar.selected].item_id;
    if (selected_item_id == 0) return;
    const block_id = BlockRegistry.BlockId.fromInt(selected_item_id);

    // 根据点击的方块面设置朝向
    const facing: Direction = blk: {
        const fn_ = hit.face_normal;
        if (fn_.y != 0) break :blk if (fn_.y > 0) .up else .down;
        if (fn_.x != 0) break :blk if (fn_.x > 0) .west else .east;
        break :blk if (fn_.z > 0) .south else .north;
    };
    try self.block_world.setBlock(place_pos, BlockState{ .block_id = block_id, .facing = facing });
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

fn updateEntities(self: *Game) !void {
    // 实体销毁距离：比区块加载距离少 1 个 chunk，防止站在卸载边缘时区块先被卸载导致实体跌落
    const DESPAWN_DISTANCE: f32 = @as(f32, @floatFromInt(self.chunk_radius - 1)) * @as(f32, @floatFromInt(BlockWorld.CHUNK_WIDTH));

    // 0. 销毁掉出世界的实体（Y 坐标过低）
    {
        const VOID_Y: f32 = -64.0;
        var view = self.registry.view(.{Comps.Position}, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const pos = view.get(entity);
            if (pos.vec.y >= VOID_Y) continue;
            // 玩家掉出世界则复活
            if (self.registry.tryGet(Comps.Player, entity)) |player| {
                if (player.id == self.player_id) {
                    if (self.registry.tryGet(Comps.SpawnPos, entity)) |spawn| {
                        if (self.registry.tryGet(Comps.Health, entity)) |hp| {
                            hp.current = hp.max;
                        }
                        pos.vec = spawn.pos;
                        pos.prev = spawn.pos;
                    }
                    continue;
                }
            }
            // 非玩家实体直接销毁
            self.block_world.cleanupEntity(&self.registry, entity);
            self.registry.destroy(entity);
        }
    }

    // 1. 销毁远离所有玩家的 AI 实体
    {
        var view = self.registry.view(.{ Comps.AIAgent, Comps.Position }, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const pos = view.get(Comps.Position, entity);
            var pv = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
            var pi = pv.entityIterator();
            var despawn = true;
            while (pi.next()) |pe| {
                const pp = pv.get(Comps.Position, pe);
                const dx = pp.vec.x - pos.vec.x;
                const dz = pp.vec.z - pos.vec.z;
                if (@sqrt(dx * dx + dz * dz) < DESPAWN_DISTANCE) {
                    despawn = false;
                    break;
                }
            }
            if (despawn) {
                self.block_world.cleanupEntity(&self.registry, entity);
                self.registry.destroy(entity);
            }
        }
    }

    // 2. 敌人接触伤害
    {
        var view = self.registry.view(.{ Comps.AIAgent, Comps.Position, Comps.Collider }, .{});
        var iter = view.entityIterator();
        while (iter.next()) |enemy_entity| {
            const enemy_pos = view.get(Comps.Position, enemy_entity);
            const enemy_col = view.get(Comps.Collider, enemy_entity);
            const agent = view.get(Comps.AIAgent, enemy_entity);
            const info = agent.type_id.info();
            const ebox = BlockWorld.BlockWorld.getEntityAABB(enemy_pos.vec, enemy_col);

            var pview = self.registry.view(.{ Comps.Player, Comps.Position, Comps.Collider, Comps.Health }, .{});
            var piter = pview.entityIterator();
            while (piter.next()) |player_entity| {
                const ppos = pview.get(Comps.Position, player_entity);
                const pcol = pview.get(Comps.Collider, player_entity);
                var hp = pview.get(Comps.Health, player_entity);
                const pbox = BlockWorld.BlockWorld.getEntityAABB(ppos.vec, pcol);

                if (ebox.min_x < pbox.max_x and ebox.max_x > pbox.min_x and
                    ebox.min_y < pbox.max_y and ebox.max_y > pbox.min_y and
                    ebox.min_z < pbox.max_z and ebox.max_z > pbox.min_z)
                // 清理 AI 实体的寻路状态和路径内存（在 registry.deinit 之前）
                {
                    hp.current -= info.attack_damage * TICK_DT;
                    std.debug.print("Player took {d:.2} damage, HP: {d:.1}/{d:.1}\n", .{ info.attack_damage * TICK_DT, hp.current, hp.max });
                }
            }
        }
    }

    // 3. 玩家死亡复活
    {
        var view = self.registry.view(.{ Comps.Player, Comps.Position, Comps.Health, Comps.SpawnPos }, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            var hp = view.get(Comps.Health, entity);
            if (hp.current <= 0) {
                hp.current = hp.max;
                var pos = view.get(Comps.Position, entity);
                const spawn = view.get(Comps.SpawnPos, entity);
                pos.vec = spawn.pos;
            }
        }
    }

    // 4. 生成敌人
    {
        var enemy_count: u32 = 0;
        var eview = self.registry.view(.{Comps.AIAgent}, .{});
        var eiter = eview.entityIterator();
        while (eiter.next()) |_| {
            enemy_count += 1;
        }

        const MAX_ENEMIES: u32 = 0;
        if (enemy_count < MAX_ENEMIES and std.crypto.random.int(u32) % 60 == 0) {
            var pview = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
            var piter = pview.entityIterator();
            while (piter.next()) |entity| {
                const ppos = pview.get(Comps.Position, entity);
                const angle = @as(f32, @floatFromInt(std.crypto.random.int(u32) % 360)) * std.math.pi / 180.0;
                const r: f32 = 16 + @as(f32, @floatFromInt(std.crypto.random.int(u32) % 16));
                const sx: f32 = ppos.vec.x + @cos(angle) * r;
                const sz: f32 = ppos.vec.z + @sin(angle) * r;
                const sy = getSurfaceY(&self.block_world, @intFromFloat(@floor(sx)), @intFromFloat(@floor(sz)));
                if (sy) |y| {
                    // 在方块表面生成敌人（脚底 = 表面方块顶 +1）
                    try spawnEnemy(self, "zombie", Vec3.new(sx, @as(f32, @floatFromInt(y)), sz));
                }
                break;
            }
        }
    }
}

fn spawnEnemy(self: *Game, comptime type_name: []const u8, pos: Vec3) !void {
    const eid = EntityTypeId.fromName(type_name);
    const info = eid.info();
    const entity = self.registry.create();
    self.registry.add(entity, Comps.AIAgent{ .type_id = eid, .target = pos });
    self.registry.add(entity, Comps.ModelName{ .id = info.model_id });
    self.registry.add(entity, Comps.Position{ .vec = pos, .prev = pos });
    self.registry.add(entity, Comps.Velocity{ .vec = Vec3.zero });
    self.registry.add(entity, Comps.Collider{ .width = info.collider_width, .height = info.collider_height });
    self.registry.add(entity, Comps.MoveSpeed{ .value = info.move_speed });
    self.registry.add(entity, Comps.JumpVelocity{ .value = info.jump_vel });
    self.registry.add(entity, Comps.OnGround{ .value = false });
    self.registry.add(entity, Comps.Facing{});
    self.registry.add(entity, Comps.MoveIntent{});
    self.registry.add(entity, Comps.Health{ .current = info.health, .max = info.health });
    self.registry.add(entity, Comps.AttackCooldown{ .interval = info.attack_interval });
    if (self.animation_system.allocBoneSlot()) |bone_offset| {
        self.registry.add(entity, Comps.AnimationState{
            .clip_name = @import("rend_ctx.zig").ClipName.walk,
            .bone_offset = bone_offset,
        });
    }
}

fn updateChunks(self: *Game) !void {
    const start_ns = std.time.nanoTimestamp();
    var view = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const player = view.get(Comps.Player, entity);
        if (player.id != self.player_id) continue;
        const pos = view.get(Comps.Position, entity);

        const player_origin = BlockWorld.BlockWorld.chunkOrigin(
            @intFromFloat(@floor(pos.vec.x)),
            @intFromFloat(@floor(pos.vec.z)),
        );
        const pcx = @divFloor(player_origin.x, BlockWorld.CHUNK_WIDTH_I32);
        const pcz = @divFloor(player_origin.z, BlockWorld.CHUNK_WIDTH_I32);

        // 用 prev 算上一次物理 tick 时的区块坐标
        // 如果玩家没有跨区块移动，直接跳过加载/卸载
        const prev_origin = BlockWorld.BlockWorld.chunkOrigin(
            @intFromFloat(@floor(pos.prev.x)),
            @intFromFloat(@floor(pos.prev.z)),
        );
        const prev_cx = @divFloor(prev_origin.x, BlockWorld.CHUNK_WIDTH_I32);
        const prev_cz = @divFloor(prev_origin.z, BlockWorld.CHUNK_WIDTH_I32);
        if (pcx == prev_cx and pcz == prev_cz) break;

        const load_range: i32 = self.chunk_radius;
        const load_range_sq = load_range * load_range;
        const t_load_start = std.time.nanoTimestamp();
        var dx: i32 = -load_range;
        while (dx <= load_range) : (dx += 1) {
            var dz: i32 = -load_range;
            while (dz <= load_range) : (dz += 1) {
                // 圆形加载区域：跳过四个角上的 chunk
                if (dx * dx + dz * dz > load_range_sq) continue;
                try self.block_world.loadChunk(.new(
                    player_origin.x + dx * BlockWorld.CHUNK_WIDTH_I32,
                    0,
                    player_origin.z + dz * BlockWorld.CHUNK_WIDTH_I32,
                ));
            }
        }
        const t_unload_start = std.time.nanoTimestamp();
        const load_us = @as(u64, @intCast(@max(@as(i64, 0), t_unload_start - t_load_start))) / 1000;

        // 卸载远处区块（圆形边界：半径 load_range + 2）
        var to_unload = std.ArrayListUnmanaged(Vec3i){};
        defer to_unload.deinit(self.allocator);
        const unload_range_sq = (load_range + 2) * (load_range + 2);
        var chunk_it = self.block_world.chunks.keyIterator();
        while (chunk_it.next()) |key| {
            const kcx = @divFloor(key.x, BlockWorld.CHUNK_WIDTH_I32);
            const kcz = @divFloor(key.z, BlockWorld.CHUNK_WIDTH_I32);
            const dd = (pcx - kcx) * (pcx - kcx) + (pcz - kcz) * (pcz - kcz);
            if (dd > unload_range_sq) {
                to_unload.append(self.allocator, key.*) catch continue;
            }
        }
        const t_unload_loop_start = std.time.nanoTimestamp();
        const scan_us = @as(u64, @intCast(@max(@as(i64, 0), t_unload_loop_start - t_unload_start))) / 1000;
        for (to_unload.items) |key| {
            self.block_world.unloadChunk(key);
        }
        const t_end = std.time.nanoTimestamp();
        const unload_us = @as(u64, @intCast(@max(@as(i64, 0), t_end - t_unload_loop_start))) / 1000;
        const elapsed_us = @as(u64, @intCast(@max(@as(i64, 0), t_end - start_ns))) / 1000;
        if (elapsed_us > 100000) std.debug.print("[TIMER] updateChunks: total={d}us load={d}us scan={d}us unload={d}us\n", .{ elapsed_us, load_us, scan_us, unload_us });
        break;
    }
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
const SkyPipeline = @import("sky.zig").SkyPipeline;
const ShadowPipeline = @import("shadow.zig").ShadowPipeline;

const BlockWorld = @import("block_world.zig");
const TICK_DT = BlockWorld.TICK_DT;
const BlockRegistry = @import("block_registry.zig");
const BlockState = BlockRegistry.BlockState;
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

fn getSurfaceY(world: *BlockWorld.BlockWorld, x: i32, z: i32) ?i32 {
    var y: i32 = @intCast(BlockWorld.CHUNK_HEIGHT - 1);
    while (y >= 0) : (y -= 1) {
        const pos = Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, @as(f32, @floatFromInt(z)) + 0.5);
        const block = world.getBlockAt(pos);
        if (block.prototype().is_solid) {
            const above: i32 = y + 1;
            if (above >= BlockWorld.CHUNK_HEIGHT) return null;
            const above_pos = Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(above)) + 0.5, @as(f32, @floatFromInt(z)) + 0.5);
            const above_block = world.getBlockAt(above_pos);
            if (!above_block.prototype().is_solid) return above;
            return null;
        }
    }
    return null;
}
