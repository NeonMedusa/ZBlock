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
hotbar: Hotbar,
save_manager: SaveManager,
icon_atlas: IconAtlas,
block_world: BlockWorld.BlockWorld,
load_range: i32,
flying: bool = false,
last_space_press: f64 = 0.0,
accumulator: f32 = 0, // 物理 tick 时间余量，用于渲染插值
sprint_toggled: bool = false, // 冲刺开关，渲染层触发，tick 层读取

// 开始游戏
pub fn start(self: *Game) !void {
    var main_menu = @import("ui/main_menu.zig"){};
    // 创建玩家实体
    const player_entity = self.registry.create();
    self.registry.add(player_entity, Comps.Player{ .id = self.player_id, .mode = .creative });
    self.registry.add(player_entity, Comps.Position{ .vec = Vec3.new(8, 130, 8), .prev = Vec3.zero });
    self.registry.add(player_entity, Comps.Velocity{ .vec = Vec3.zero });
    self.registry.add(player_entity, Comps.Collider{ .width = 0.6, .height = 1.8 });
    self.registry.add(player_entity, Comps.MoveSpeed{ .value = 4.0 });
    self.registry.add(player_entity, Comps.JumpVelocity{ .value = 14.0 });
    self.registry.add(player_entity, Comps.OnGround{ .value = false });
    self.registry.add(player_entity, Comps.MoveIntent{});
    self.registry.add(player_entity, Comps.Health{ .current = 100, .max = 100 });
    self.registry.add(player_entity, Comps.SpawnPos{ .pos = Vec3.new(8, 130, 8) });

    // 加载初始区块（尝试从存档恢复，无存档则生成）
    {
        var chunk_io = chunkIO(&self.save_manager);
        const player_origin = BlockWorld.BlockWorld.chunkOrigin(
            @intFromFloat(@floor(8.0)),
            @intFromFloat(@floor(8.0)),
        );
        const range: i32 = 1;
        var dx: i32 = -range;
        while (dx <= range) : (dx += 1) {
            var dz: i32 = -range;
            while (dz <= range) : (dz += 1) {
                try self.block_world.loadChunk(.new(
                    player_origin.x + dx * BlockWorld.CHUNK_SIZE_X_I32,
                    0,
                    player_origin.z + dz * BlockWorld.CHUNK_SIZE_Z_I32,
                ), &chunk_io);
            }
        }
    }
    // 加载玩家数据（位置、血量、物品栏、飞行状态）
    self.save_manager.loadPlayer(&self.hotbar, &self.registry) catch {};

    // 同步飞行状态到 Game 标记
    {
        var view = self.registry.view(.{ Comps.Player, Comps.Flying }, .{});
        var iter = view.entityIterator();
        if (iter.next()) |_| {
            self.flying = true;
        }
    }

    // 等待worker完成初始区块的mesh构建
    while (self.block_world.pendingCount() > 0) {
        try self.block_world.processCompletedBuilds();
        std.Thread.yield() catch {};
    }

    // 加载 AI 实体（从存档恢复）
    self.save_manager.loadAllEntities(&self.registry) catch |err| std.debug.print("loadEntities error: {}\n", .{err});

    // 主循环
    while (!self.window.shouldClose()) {
        self.input.beginFrame();
        self.window.pollEvents();

        self.accumulator += self.window.delta_time;
        if (self.accumulator > TICK_DT * 5) self.accumulator = TICK_DT * 5;

        // 准备 tick：保存当前位置到 prev，用于渲染插值
        if (self.accumulator >= TICK_DT) {
            var pv = self.registry.view(.{Comps.Position}, .{});
            var pi = pv.entityIterator();
            while (pi.next()) |e| {
                var p = pv.get(e);
                p.prev = p.vec;
            }
        }

        // tick 循环（固定步长）
        while (self.accumulator >= TICK_DT) {
            self.accumulator -= TICK_DT;
            if (!main_menu.visible) {
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
            }
        }

        // 渲染帧（输入事件处理、摄像机、UI，不受 tick 影响）
        if (!main_menu.visible) {
            handleFlightToggle(self);
            if (self.input.isKeyJustPressed(.left_shift) or self.input.isKeyJustPressed(.right_shift))
                self.sprint_toggled = !self.sprint_toggled;
            syncCameraFromPlayer(self);
            try updateChunks(self);

            if (self.input.isMouseJustPressed(.mouse_left))
                try handleLeftClick(self);
            if (self.input.isMouseJustPressed(.mouse_right))
                try tryPlaceBlock(self);
        }
        self.icon_atlas.reset();
        self.ui_system.beginFrame();
        main_menu.update(self);
        self.handleHotbarInput();
        self.ui_system.drawHotbar(&self.hotbar, &self.icon_atlas);
        try self.ui_system.endFrame(&self.gctx);
        // 6. 处理待构建的区块mesh（可能由异步worker完成）
        try self.block_world.processCompletedBuilds();
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
    const ui_system = try UiSystem.init(allocator, &self.gctx, self, "resources/fonts/wqy-microhei.ttc");
    self.ui_system = ui_system;

    // 物品栏
    self.hotbar = .{};

    // 存档系统
    self.save_manager = try SaveManager.init(allocator, "world_1");

    // 图标缓存 + 图标管线（传入 uniform 缓冲）
    self.icon_atlas = try IconAtlas.init(allocator, &self.gctx, self.ui_system.uniform_buffer);

    // 测试方块世界
    self.load_range = 16;
    const load_range: i32 = self.load_range;
    const max_chunks: usize = @intCast((2 * load_range + 1) * (2 * load_range + 1) * 4);
    self.block_world = try BlockWorld.BlockWorld.init(self.allocator, &self.gctx, &self.render_pipeline, max_chunks);
    try self.block_world.spawnWorker(); // mesh 生成线程
    try self.block_world.spawnAStarWorker(); // 寻路线程

    // 返回实例
    return self;
}

pub fn deinit(self: *@This()) void {
    // 最后释放自己
    defer self.allocator.destroy(self);

    self.window.deinit();
    self.gctx.deinit();

    // 退出前保存
    self.save_manager.savePlayer(&self.hotbar, &self.registry) catch |err| std.debug.print("savePlayer error: {}\n", .{err});
    self.save_manager.saveAllEntities(&self.registry) catch |err| std.debug.print("saveEntities error: {}\n", .{err});
    self.save_manager.saveAllChunks(&self.block_world) catch |err| std.debug.print("saveChunks error: {}\n", .{err});

    self.res_manager.deinit(self.allocator);
    self.render_pipeline.deinit();
    // 清理 AI 实体的寻路状态和路径内存（在 registry.deinit 之前）
    {
        var view = self.registry.view(.{Comps.AIAgent}, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            self.block_world.cleanupEntity(&self.registry, entity);
        }
    }
    self.registry.deinit();
    self.ui_system.deinit();
    self.icon_atlas.deinit();
    self.block_world.deinit();
    self.save_manager.deinit();
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
        if (self.input.isKeyHeld(.w)) move_dir = move_dir.add(front_h);
        if (self.input.isKeyHeld(.s)) move_dir = move_dir.sub(front_h);
        if (self.input.isKeyHeld(.a)) move_dir = move_dir.sub(right_h);
        if (self.input.isKeyHeld(.d)) move_dir = move_dir.add(right_h);

        // 空格：跳跃 + 水中上浮指示
        if (self.input.isKeyHeld(.space)) {
            intent.jump = true;
            move_dir.y = 1.0;
        }
        // Ctrl：水中下潜指示
        if (self.input.isKeyHeld(.left_control) or self.input.isKeyHeld(.right_control)) {
            move_dir.y = -1.0;
        }

        // 无水平输入时，强制关闭冲刺（防止松开按键后仍保持冲刺状态）
        const has_movement = self.input.isKeyHeld(.w) or
            self.input.isKeyHeld(.s) or
            self.input.isKeyHeld(.a) or
            self.input.isKeyHeld(.d);
        if (!has_movement) {
            intent.sprint = false;
            self.sprint_toggled = false;
        } else {
            intent.sprint = self.sprint_toggled;
        }

        // 按住左 Ctrl 进入潜行；松开则退出潜行（飞行时不关闭冲刺）
        if (self.input.isKeyHeld(.left_control)) {
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
    for (0..9) |i| {
        const key_code = @intFromEnum(Input.Key.num1) + @as(i32, @intCast(i));
        const key: Input.Key = @enumFromInt(key_code);
        if (self.input.isKeyJustPressed(key)) {
            self.hotbar.selected = @intCast(i);
        }
    }

    // 滚轮切换选中槽位
    const scroll = self.input.getScrollDelta();
    if (scroll.y > 0) {
        self.hotbar.selected = (self.hotbar.selected + 8) % 9;
    } else if (scroll.y < 0) {
        self.hotbar.selected = (self.hotbar.selected + 1) % 9;
    }

    // 鼠标中键：拾取瞄准的方块到当前槽位
    if (self.input.isMouseJustPressed(.mouse_middle)) {
        const ray = self.camera.getCursorRay();
        const hit = Raycast.raycastWorld(&self.block_world, ray, 8.0);
        if (hit.hit) {
            const block = self.block_world.getBlockAt(Vec3.new(
                @as(f32, @floatFromInt(hit.block_pos.x)) + 0.5,
                @as(f32, @floatFromInt(hit.block_pos.y)) + 0.5,
                @as(f32, @floatFromInt(hit.block_pos.z)) + 0.5,
            ));
            const air_id = @intFromEnum(BlockRegistry.BlockId.fromName("air"));
            if (@intFromEnum(block) != air_id) {
                self.hotbar.slots[self.hotbar.selected] = .{
                    .block_id = block,
                    .count = 1,
                };
            }
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
            self.camera.updateFromMouse(self);
            self.ubo.camera_pos = self.camera.position;
            break;
        }
    }
}

fn handleLeftClick(self: *Game) !void {
    const ray = self.camera.getCursorRay();

    // 同时检测实体和方块，比较距离：谁近打谁（防止隔墙攻击实体）
    const entity_hit = Raycast.raycastEntities(&self.registry, ray, 8.0);
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
                    self.block_world.cleanupEntity(&self.registry, entity_hit.entity);
                    self.registry.destroy(entity_hit.entity);
                }
            }
        }
    } else if (block_hit.hit) {
        try self.block_world.setBlock(block_hit.block_pos, .fromName("air"));
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
    )) != BlockRegistry.BlockId.fromName("air")) return;

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

    // 使用物品栏选中的方块放置，空气跳过
    const selected_id = self.hotbar.selectedBlock();
    if (@intFromEnum(selected_id) == @intFromEnum(BlockRegistry.BlockId.fromName("air"))) return;

    try self.block_world.setBlock(place_pos, selected_id);
}

fn updateEntities(self: *Game) !void {
    const DESPAWN_DISTANCE: f32 = 24.0;

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

        const MAX_ENEMIES: u32 = 1000;
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
    self.registry.add(entity, Comps.MoveIntent{});
    self.registry.add(entity, Comps.Health{ .current = info.health, .max = info.health });
    self.registry.add(entity, Comps.AttackCooldown{ .interval = info.attack_interval });
}

fn updateChunks(self: *Game) !void {
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
        const pcx = @divFloor(player_origin.x, BlockWorld.CHUNK_SIZE_X_I32);
        const pcz = @divFloor(player_origin.z, BlockWorld.CHUNK_SIZE_Z_I32);

        const load_range: i32 = self.load_range;
        var io = chunkIO(&self.save_manager);
        var dx: i32 = -load_range;
        while (dx <= load_range) : (dx += 1) {
            var dz: i32 = -load_range;
            while (dz <= load_range) : (dz += 1) {
                try self.block_world.loadChunk(.new(
                    player_origin.x + dx * BlockWorld.CHUNK_SIZE_X_I32,
                    0,
                    player_origin.z + dz * BlockWorld.CHUNK_SIZE_Z_I32,
                ), &io);
            }
        }

        // 卸载远处区块
        var to_unload = std.ArrayListUnmanaged(Vec3i){};
        defer to_unload.deinit(self.allocator);
        var chunk_it = self.block_world.chunks.keyIterator();
        while (chunk_it.next()) |key| {
            const kcx = @divFloor(key.x, BlockWorld.CHUNK_SIZE_X_I32);
            const kcz = @divFloor(key.z, BlockWorld.CHUNK_SIZE_Z_I32);
            const dist = @max(@abs(pcx - kcx), @abs(pcz - kcz));
            if (dist > load_range + 2) {
                to_unload.append(self.allocator, key.*) catch continue;
            }
        }
        for (to_unload.items) |key| {
            self.block_world.unloadChunk(key, &io);
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
const TICK_DT = BlockWorld.TICK_DT;
const BlockRegistry = @import("block_registry.zig");
const AABB = @import("aabb.zig").AABB;
const EntityTypeId = @import("entity_registry.zig").EntityTypeId;
const Hotbar = @import("inventory.zig").Hotbar;
const IconAtlas = @import("icon_atlas.zig").IconAtlas;
const SaveManager = @import("save_manager.zig").SaveManager;

/// 构建 ChunkIO 回调，使区块加载/卸载时自动读写存档
fn chunkIO(mgr: *SaveManager) BlockWorld.ChunkIO {
    const S = struct {
        fn load(ctx: *anyopaque, origin: Vec3i, chunk: *BlockWorld.Chunk) bool {
            const self = @as(*SaveManager, @ptrCast(@alignCast(ctx)));
            const cx = @divExact(origin.x, 16);
            const cz = @divExact(origin.z, 16);
            return self.loadChunk(cx, cz, chunk) catch false;
        }
        fn save(ctx: *anyopaque, origin: Vec3i, chunk: *const BlockWorld.Chunk) void {
            const self = @as(*SaveManager, @ptrCast(@alignCast(ctx)));
            const cx = @divExact(origin.x, 16);
            const cz = @divExact(origin.z, 16);
            self.saveChunk(cx, cz, chunk) catch {};
        }
    };
    return .{
        .ctx = @ptrCast(mgr),
        .loadFn = S.load,
        .saveFn = S.save,
    };
}

fn getSurfaceY(world: *BlockWorld.BlockWorld, x: i32, z: i32) ?i32 {
    var y: i32 = @intCast(BlockWorld.CHUNK_SIZE_Y - 1);
    while (y >= 0) : (y -= 1) {
        const pos = Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, @as(f32, @floatFromInt(z)) + 0.5);
        const block = world.getBlockAt(pos);
        if (block.prototype().is_solid) {
            const above: i32 = y + 1;
            if (above >= BlockWorld.CHUNK_SIZE_Y) return null;
            const above_pos = Vec3.new(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(above)) + 0.5, @as(f32, @floatFromInt(z)) + 0.5);
            const above_block = world.getBlockAt(above_pos);
            if (!above_block.prototype().is_solid) return above;
            return null;
        }
    }
    return null;
}
