const io = @import("imports.zig").io;
pub extern "kernel32" fn Sleep(milliseconds: u32) callconv(.c) void;
// server.zig — 服务端状态（物理、AI、动画）
// 独立线程运行，通过输入队列与渲染线程通信。

const std = @import("std");
const Vec3 = @import("algebra.zig").Vec3;
const Vec3i = @import("algebra.zig").Vec3i;
const BlockWorld = @import("block_world.zig").BlockWorld;
const CHUNK_WIDTH = @import("block_world.zig").CHUNK_WIDTH;
const CHUNK_WIDTH_I32 = @import("block_world.zig").CHUNK_WIDTH_I32;
const Comps = @import("components.zig").Components;
const ECS = @import("imports.zig").ECS;
const AnimationSystem = @import("animation.zig").AnimationSystem;
const ResManager = @import("rend_ctx.zig").ResManager;
const Raycast = @import("raycast.zig");
const BlockRegistry = @import("block_registry.zig");
const BlockState = BlockRegistry.BlockState;
const BlockId = BlockRegistry.BlockId;
const Direction = @import("direction.zig").Direction;
const Network = @import("network.zig");
const EntityTypeId = @import("entity_registry.zig").EntityTypeId;
const TICK_DT: f32 = 1.0 / 30.0;

pub const PlayerInput = struct {
    player_id: u32 = 0,
    move_dir: Vec3 = Vec3.zero,
    jump: bool = false,
    sprint_held: bool = false,
    sneak: bool = false,
    facing_dir: Vec3 = Vec3.new(0, 0, -1),
    cam_yaw: f32 = 0,
    cam_pitch: f32 = 0,
    break_block: bool = false,
    place_block: bool = false,
    wants_fly: bool = false,
    attack: bool = false,
    hotbar_slot: u32 = 0,
    place_block_id: u32 = 0,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    registry: ECS.Registry,
    block_world: BlockWorld,
    animation_system: AnimationSystem,
    tick_count: u64 = 0,
    player_id: u32 = 0,
    flying: bool = false,
    chunk_radius: i32 = 4,
    sprint_toggled: bool = false,

    input_queue: std.ArrayListUnmanaged(PlayerInput) = .empty,
    queue_mutex: std.Io.Mutex = .init,
    running: bool = true,
    server_thread: ?std.Thread = null,

    // 待发送给客机的区块更新（服务端线程填充，网络线程消费）
    pending_chunks: std.ArrayListUnmanaged(Vec3i) = .empty,
    pending_chunks_mutex: std.Io.Mutex = .init,
    pending_unloads: std.ArrayListUnmanaged(Vec3i) = .empty,
    pending_unloads_mutex: std.Io.Mutex = .init,

    // 双缓冲快照（服务端线程发布，网络/渲染线程读取）
    snapshot_mutex: std.Io.Mutex = .init,
    snapshots: [64]Network.EntitySnapshot = undefined,
    snapshot_count: u32 = 0,
    snapshot_tick: u64 = 0,
    snapshot_serial: u64 = 0,

    // 每个玩家已加载的区块集合（用于增量更新远程客户端）
    player_chunks: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(Vec3i)) = .empty,

    pub fn init(allocator: std.mem.Allocator) Server {
        return .{
            .allocator = allocator,
            .registry = ECS.Registry.init(allocator),
            .block_world = undefined,
            .animation_system = undefined,
        };
    }

    pub fn deinit(self: *Server) void {
        self.input_queue.deinit(self.allocator);
        self.pending_chunks.deinit(self.allocator);
        self.pending_unloads.deinit(self.allocator);
        var it = self.player_chunks.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.player_chunks.deinit(self.allocator);
        self.registry.deinit();
    }

    pub fn start(self: *Server, res_manager: *ResManager) !void {
        self.running = true;
        self.server_thread = try std.Thread.spawn(.{}, serverThreadFn, .{ self, res_manager });
    }

    pub fn stop(self: *Server) void {
        self.running = false;
        if (self.server_thread) |t| {
            t.join();
            self.server_thread = null;
        }
        self.input_queue.clearAndFree(self.allocator);
    }

    pub fn pushInput(self: *Server, input: PlayerInput) !void {
        self.queue_mutex.lockUncancelable(io);
        defer self.queue_mutex.unlock(io);
        try self.input_queue.append(self.allocator, input);
    }

    fn serverThreadFn(self: *Server, res_manager: *ResManager) void {
        const tick_ns: u64 = @intFromFloat(TICK_DT * 1_000_000_000);
        var next_tick = std.Io.Timestamp.now(io, .awake);

        while (self.running) {
            // 等待到下一个 tick 时间点
            {
                const deadline = next_tick.nanoseconds;
                while (true) {
                    const now = std.Io.Timestamp.now(io, .awake);
                    const remaining = deadline - now.nanoseconds;
                    if (remaining <= 0) break;
                    // 分块睡眠，每次最多 5ms，保持对 running 标志的响应
                    const sleep_ms = @min(@as(u32, @intCast(@divTrunc(remaining, 1_000_000))), 5);
                    if (sleep_ms > 0) Sleep(sleep_ms);
                }
            }

            var inputs: std.ArrayListUnmanaged(PlayerInput) = .empty;
            defer inputs.deinit(self.allocator);
            self.queue_mutex.lockUncancelable(io);
            while (self.input_queue.items.len > 0) {
                inputs.append(self.allocator, self.input_queue.orderedRemove(0)) catch {};
            }
            self.queue_mutex.unlock(io);

            self.tick(inputs.items, res_manager) catch {};

            // 推进到下一个 tick 截止时间
            next_tick = std.Io.Timestamp.fromNanoseconds(next_tick.nanoseconds + tick_ns);
            // 如果落后超过一个 tick，直接跳到当前时间 + 一个 tick（不补帧）
            const now2 = std.Io.Timestamp.now(io, .awake);
            if (next_tick.nanoseconds < now2.nanoseconds) {
                next_tick = std.Io.Timestamp.fromNanoseconds(now2.nanoseconds + tick_ns);
            }
        }
    }

    /// 处理单个玩家的输入（更新 MoveIntent/朝向/动作等，不跑物理）
    /// 投递区块更新（服务端线程调用，网络线程消费）
    pub fn enqueueChunkUpdate(self: *Server, block_pos: Vec3i) void {
        const origin = Vec3i.new(
            @divFloor(block_pos.x, 16) * 16,
            0,
            @divFloor(block_pos.z, 16) * 16,
        );
        self.pending_chunks_mutex.lockUncancelable(io);
        defer self.pending_chunks_mutex.unlock(io);
        for (self.pending_chunks.items) |o| {
            if (o.x == origin.x and o.z == origin.z) return;
        }
        self.pending_chunks.append(self.allocator, origin) catch {};
    }

    /// 投递区块卸载（服务端线程调用，网络线程消费）
    pub fn enqueueChunkUnload(self: *Server, origin: Vec3i) void {
        self.pending_unloads_mutex.lockUncancelable(io);
        defer self.pending_unloads_mutex.unlock(io);
        for (self.pending_unloads.items) |o| {
            if (o.x == origin.x and o.z == origin.z) return;
        }
        self.pending_unloads.append(self.allocator, origin) catch {};
    }

    /// 运行一个物理 tick（固定 30Hz）
    /// 运行一个物理 tick：先处理所有待处理输入，再跑一次物理
    pub fn tick(self: *Server, inputs: []const PlayerInput, res_manager: *ResManager) !void {
        self.tick_count += 1;

        // 依次处理每个输入
        for (inputs) |input| {
            var target_entity: ?ECS.Entity = null;
            {
                var view = self.registry.view(.{Comps.Player}, .{});
                var iter = view.entityIterator();
                while (iter.next()) |entity| {
                    if (view.get(entity).id == input.player_id) {
                        target_entity = entity;
                        break;
                    }
                }
            }
            const entity = target_entity orelse continue;

            if (self.registry.tryGet(Comps.MoveIntent, entity)) |intent| {
                intent.direction = input.move_dir;
                // 垂直移动：飞行或游泳时用 jump/sneak 控制上下
                if (input.jump) intent.direction.y = 1.0;
                if (input.sneak) intent.direction.y = -1.0;
                if (input.jump) intent.jump = true;

                const has_movement = @sqrt(input.move_dir.x * input.move_dir.x + input.move_dir.z * input.move_dir.z) > 0.01;
                if (input.player_id == 0) {
                    if (has_movement) {
                        intent.sprint = self.sprint_toggled;
                    } else {
                        intent.sprint = false;
                        self.sprint_toggled = false;
                    }
                } else {
                    if (has_movement) {
                        intent.sprint = input.sprint_held;
                    } else {
                        intent.sprint = false;
                    }
                }

                if (input.sneak) {
                    intent.sneak = true;
                    if (!self.registry.has(Comps.Flying, entity)) intent.sprint = false;
                } else {
                    intent.sneak = false;
                }
            }

            if (self.registry.tryGet(Comps.Facing, entity)) |facing| {
                if (input.player_id != 0) {
                    facing.yaw = -input.cam_yaw + std.math.pi / 2.0;
                    facing.pitch = input.cam_pitch;
                }
            }

            if (input.wants_fly) {
                if (self.registry.has(Comps.Flying, entity)) {
                    _ = self.registry.remove(Comps.Flying, entity);
                } else {
                    self.registry.add(entity, Comps.Flying{});
                }
            }

            // 所有玩家的 break/place 都在服务端线程处理
            if (input.break_block or input.place_block) {
                if (self.registry.tryGet(Comps.Position, entity)) |pos| {
                    const eye = pos.vec.add(Vec3.new(0, 1.6, 0));
                    const front = Vec3.new(
                        @cos(input.cam_yaw) * @cos(input.cam_pitch),
                        @sin(input.cam_pitch),
                        @sin(input.cam_yaw) * @cos(input.cam_pitch),
                    ).norm();
                    const ray = Raycast.Ray{ .origin = eye, .direction = front };
                    if (input.break_block) self.handleActionBreak(ray);
                    if (input.place_block) self.handleActionPlaceSlot(ray, input.place_block_id);
                }
            }
        }

        // 物理（只跑一次，与输入数量无关）
        self.block_world.updatePhysics(&self.registry, TICK_DT);

        // AI 追踪玩家：每个 AI 追踪最近的玩家
        {
            var aview = self.registry.view(.{ Comps.AIAgent, Comps.Position }, .{});
            var aiter = aview.entityIterator();
            while (aiter.next()) |enemy| {
                var agent = aview.get(Comps.AIAgent, enemy);
                const epos = aview.get(Comps.Position, enemy);
                var nearest_dist: f32 = std.math.floatMax(f32);
                var nearest_pos = epos.vec;
                {
                    var pview = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
                    var piter = pview.entityIterator();
                    while (piter.next()) |player_entity| {
                        const ppos = pview.get(Comps.Position, player_entity).vec;
                        const dx = ppos.x - epos.vec.x;
                        const dz = ppos.z - epos.vec.z;
                        const d = dx * dx + dz * dz;
                        if (d < nearest_dist) {
                            nearest_dist = d;
                            nearest_pos = ppos;
                        }
                    }
                }
                const info = agent.type_id.info();
                if (@sqrt(nearest_dist) < info.detect_range) {
                    agent.target = nearest_pos;
                }
            }
        }
        self.block_world.updateAI(&self.registry, TICK_DT);

        self.animation_system.update(&self.registry, res_manager, TICK_DT);

        self.updateEntities() catch {};
        self.updateChunks() catch {};

        // 每 5 秒尝试生成敌对实体（每玩家附近最多 3 个）
        if (self.tick_count % 150 == 0) self.spawnEnemies();

        self.publishSnapshot();
    }

    fn publishSnapshot(self: *Server) void {
        self.snapshot_mutex.lockUncancelable(io);
        defer self.snapshot_mutex.unlock(io);
        self.snapshot_count = 0;
        self.snapshot_tick = self.tick_count;
        self.snapshot_serial +|= 1;

        {
            var view = self.registry.view(.{ Comps.Player, Comps.Position, Comps.Facing }, .{});
            var iter = view.entityIterator();
            while (iter.next()) |e| {
                if (self.snapshot_count >= 64) break;
                const p = view.get(Comps.Player, e);
                const pos = view.get(Comps.Position, e);
                const facing = view.get(Comps.Facing, e);
                self.snapshots[self.snapshot_count] = .{
                    .player_id = p.id,
                    .pos = pos.vec,
                    .facing_yaw = facing.yaw,
                    .facing_pitch = facing.pitch,
                };
                self.snapshot_count += 1;
            }
        }
        {
            var view = self.registry.view(.{ Comps.ModelName, Comps.Position, Comps.Facing }, .{});
            var iter = view.entityIterator();
            while (iter.next()) |e| {
                if (self.snapshot_count >= 64) break;
                if (self.registry.tryGet(Comps.Player, e)) |_| continue;
                const pos = view.get(Comps.Position, e);
                const facing = view.get(Comps.Facing, e);
                self.snapshots[self.snapshot_count] = .{
                    .player_id = std.math.maxInt(u32),
                    .pos = pos.vec,
                    .facing_yaw = facing.yaw,
                    .facing_pitch = facing.pitch,
                };
                self.snapshot_count += 1;
            }
        }
    }

    fn spawnEnemies(self: *Server) void {
        const MAX_ENEMIES: usize = 1;
        var count: usize = 0;
        {
            var view = self.registry.view(.{Comps.AIAgent}, .{});
            var it = view.entityIterator();
            while (it.next()) |_| count += 1;
        }
        if (count >= MAX_ENEMIES) return;

        var pv = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
        var pi = pv.entityIterator();
        while (pi.next()) |entity| {
            const ppos = pv.get(Comps.Position, entity);
            var seed_buf: [8]u8 = undefined;
            io.random(&seed_buf);
            var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed_buf, .little));
            const rng = prng.random();
            if (rng.float(f32) > 0.4) continue; // 60% 概率跳过
            const angle = rng.float(f32) * std.math.pi * 2;
            const r: f32 = 16 + @as(f32, @floatFromInt(rng.int(u32) % 16));
            const sx: f32 = ppos.vec.x + @cos(angle) * r;
            const sz: f32 = ppos.vec.z + @sin(angle) * r;
            // 简单地表检测
            const surface_y = self.block_world.getSurfaceY(@intFromFloat(@floor(sx)), @intFromFloat(@floor(sz)));
            if (surface_y) |y| {
                self.spawnEnemy("zombie", Vec3.new(sx, @as(f32, @floatFromInt(y)), sz));
                count += 1;
                if (count >= MAX_ENEMIES) break;
            }
        }
    }

    fn spawnEnemy(self: *Server, comptime type_name: []const u8, pos: Vec3) void {
        const eid = EntityTypeId.fromName(type_name);
        const info = eid.info();
        const entity = self.registry.create();
        // MoveIntent 和 AttackCooldown 必须最先添加，避免 ECS 库的稀疏集 cleanup bug
        self.registry.add(entity, Comps.MoveIntent{});
        self.registry.add(entity, Comps.AttackCooldown{});
        self.registry.add(entity, Comps.AIAgent{ .type_id = eid, .target = pos });
        self.registry.add(entity, Comps.Position{ .vec = pos, .prev = pos });
        self.registry.add(entity, Comps.Velocity{ .vec = Vec3.zero });
        self.registry.add(entity, Comps.Collider{ .width = info.collider_width, .height = info.collider_height });
        self.registry.add(entity, Comps.MoveSpeed{ .value = info.move_speed });
        self.registry.add(entity, Comps.JumpVelocity{ .value = info.jump_vel });
        self.registry.add(entity, Comps.OnGround{ .value = false });
        self.registry.add(entity, Comps.Health{ .current = info.health, .max = info.health });
        self.registry.add(entity, Comps.Facing{});
        self.registry.add(entity, Comps.ModelName{ .id = info.model_id });
        if (self.animation_system.allocBoneSlot()) |bone_offset| {
            self.registry.add(entity, Comps.AnimationState{
                .clip_name = @import("rend_ctx.zig").ClipName.idle,
                .bone_offset = bone_offset,
            });
        }
    }

    fn handleActionBreak(self: *Server, ray: Raycast.Ray) void {
        const entity_hit = Raycast.raycastEntities(&self.registry, &self.block_world.bvh, ray, 8.0);
        const block_hit = Raycast.raycastWorld(&self.block_world, ray, 8.0);

        if (entity_hit.hit and (!block_hit.hit or entity_hit.distance < block_hit.distance)) {
            if (self.registry.tryGet(Comps.Player, entity_hit.entity)) |p| {
                if (p.id == self.player_id) return; // 不打自己
            }
            if (self.registry.tryGet(Comps.Health, entity_hit.entity)) |health| {
                health.current -= 10;
                if (health.current <= 0) {
                    if (self.registry.tryGet(Comps.AIAgent, entity_hit.entity)) |_| {
                        // 怪物死亡掉落暂不处理（需要 Inventory 访问）
                    }
                    self.block_world.cleanupEntity(&self.registry, entity_hit.entity);
                    self.registry.destroy(entity_hit.entity);
                }
            }
        } else if (block_hit.hit) {
            self.block_world.setBlock(block_hit.block_pos, .fromName("air")) catch {};
            self.enqueueChunkUpdate(block_hit.block_pos);
        }
    }

    fn handleActionPlaceSlot(self: *Server, ray: Raycast.Ray, block_id: u32) void {
        if (block_id == 0) return;
        const hit = Raycast.raycastWorld(&self.block_world, ray, 8.0);
        if (!hit.hit) return;
        const place_pos = Vec3i.new(
            hit.block_pos.x + hit.face_normal.x,
            hit.block_pos.y + hit.face_normal.y,
            hit.block_pos.z + hit.face_normal.z,
        );
        if (self.block_world.getBlockAt(Vec3.new(
            @as(f32, @floatFromInt(place_pos.x)) + 0.5,
            @as(f32, @floatFromInt(place_pos.y)) + 0.5,
            @as(f32, @floatFromInt(place_pos.z)) + 0.5,
        )).prototype().is_solid) return;
        const facing: Direction = blk: {
            const fn_ = hit.face_normal;
            if (fn_.y != 0) break :blk if (fn_.y > 0) .up else .down;
            if (fn_.x != 0) break :blk if (fn_.x > 0) .west else .east;
            break :blk if (fn_.z > 0) .south else .north;
        };
        self.block_world.setBlock(place_pos, BlockState{ .block_id = BlockId.fromInt(block_id), .facing = facing }) catch {};
        self.enqueueChunkUpdate(place_pos);
    }

    fn updateEntities(self: *Server) !void {
        const DESPAWN_DISTANCE: f32 = @as(f32, @floatFromInt(self.chunk_radius - 1)) * @as(f32, @floatFromInt(CHUNK_WIDTH));
        const VOID_Y: f32 = -64.0;
        var view = self.registry.view(.{Comps.Position}, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const pos = view.get(entity);
            if (pos.vec.y >= VOID_Y) continue;
            if (self.registry.tryGet(Comps.Player, entity)) |player| {
                if (player.id == self.player_id) {
                    if (self.registry.tryGet(Comps.SpawnPos, entity)) |spawn| {
                        if (self.registry.tryGet(Comps.Health, entity)) |hp| hp.current = hp.max;
                        pos.vec = spawn.pos;
                        pos.prev = spawn.pos;
                    }
                    continue;
                }
            }
            self.block_world.cleanupEntity(&self.registry, entity);
            self.registry.destroy(entity);
        }
        {
            var view_a = self.registry.view(.{ Comps.AIAgent, Comps.Position }, .{});
            var iter_a = view_a.entityIterator();
            while (iter_a.next()) |entity| {
                const apos = view_a.get(Comps.Position, entity);
                var pv = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
                var pi = pv.entityIterator();
                var despawn = true;
                while (pi.next()) |pe| {
                    const pp = pv.get(Comps.Position, pe);
                    const dx = pp.vec.x - apos.vec.x;
                    const dz = pp.vec.z - apos.vec.z;
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
        {
            var view_enemy = self.registry.view(.{ Comps.AIAgent, Comps.Position, Comps.Collider }, .{});
            var iter_enemy = view_enemy.entityIterator();
            while (iter_enemy.next()) |enemy_entity| {
                const epos = view_enemy.get(Comps.Position, enemy_entity);
                const ecol = view_enemy.get(Comps.Collider, enemy_entity);
                const ebox = BlockWorld.getEntityAABB(epos.vec, ecol);
                var pv = self.registry.view(.{ Comps.Player, Comps.Position, Comps.Collider, Comps.Health }, .{});
                var pi = pv.entityIterator();
                while (pi.next()) |pe| {
                    var hp = pv.get(Comps.Health, pe);
                    const pbox = BlockWorld.getEntityAABB(pv.get(Comps.Position, pe).vec, pv.get(Comps.Collider, pe));
                    if (ebox.min_x < pbox.max_x and ebox.max_x > pbox.min_x and
                        ebox.min_y < pbox.max_y and ebox.max_y > pbox.min_y and
                        ebox.min_z < pbox.max_z and ebox.max_z > pbox.min_z)
                    {
                        const agent = view_enemy.get(Comps.AIAgent, enemy_entity);
                        hp.current -= agent.type_id.info().attack_damage * TICK_DT;
                    }
                }
            }
        }
        {
            var view_hp = self.registry.view(.{ Comps.Player, Comps.Position, Comps.Health, Comps.SpawnPos }, .{});
            var iter_hp = view_hp.entityIterator();
            while (iter_hp.next()) |entity| {
                var hp = view_hp.get(Comps.Health, entity);
                if (hp.current <= 0) {
                    hp.current = hp.max;
                    view_hp.get(Comps.Position, entity).vec = view_hp.get(Comps.SpawnPos, entity).pos;
                }
            }
        }
    }

    fn updateChunks(self: *Server) !void {
        var view = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const player = view.get(Comps.Player, entity);
            const pos = view.get(Comps.Position, entity);
            const player_origin = BlockWorld.chunkOrigin(@intFromFloat(@floor(pos.vec.x)), @intFromFloat(@floor(pos.vec.z)));
            const pcx = @divFloor(player_origin.x, CHUNK_WIDTH_I32);
            const pcz = @divFloor(player_origin.z, CHUNK_WIDTH_I32);
            const prev_origin = BlockWorld.chunkOrigin(@intFromFloat(@floor(pos.prev.x)), @intFromFloat(@floor(pos.prev.z)));
            const prev_cx = @divFloor(prev_origin.x, CHUNK_WIDTH_I32);
            const prev_cz = @divFloor(prev_origin.z, CHUNK_WIDTH_I32);

            // 无论主机还是客机，只要移动了就更新区块
            if (pcx == prev_cx and pcz == prev_cz) continue;

            if (player.id == self.player_id) {
                // 主机玩家：从磁盘加载/卸载
                const load_range: i32 = self.chunk_radius;
                const lr_sq = load_range * load_range;
                var dx: i32 = -load_range;
                while (dx <= load_range) : (dx += 1) {
                    var dz: i32 = -load_range;
                    while (dz <= load_range) : (dz += 1) {
                        if (dx * dx + dz * dz > lr_sq) continue;
                        try self.block_world.loadChunk(.new(
                            player_origin.x + dx * CHUNK_WIDTH_I32,
                            0,
                            player_origin.z + dz * CHUNK_WIDTH_I32,
                        ));
                    }
                }
                const unload_lr_sq = (load_range + 2) * (load_range + 2);
                var to_unload: std.ArrayListUnmanaged(Vec3i) = .empty;
                defer to_unload.deinit(self.allocator);
                var chunk_it = self.block_world.chunks.keyIterator();
                while (chunk_it.next()) |key| {
                    const kcx = @divFloor(key.x, CHUNK_WIDTH_I32);
                    const kcz = @divFloor(key.z, CHUNK_WIDTH_I32);
                    if ((pcx - kcx) * (pcx - kcx) + (pcz - kcz) * (pcz - kcz) <= unload_lr_sq) continue;
                    // 检查是否有其他玩家还需要这个区块
                    var needed_by_other = false;
                    {
                        var other_view = self.registry.view(.{ Comps.Player, Comps.Position }, .{});
                        var other_iter = other_view.entityIterator();
                        while (other_iter.next()) |oe| {
                            if (other_view.get(Comps.Player, oe).id == self.player_id) continue;
                            const op = other_view.get(Comps.Position, oe);
                            const o_origin = BlockWorld.chunkOrigin(@intFromFloat(@floor(op.vec.x)), @intFromFloat(@floor(op.vec.z)));
                            const ocx = @divFloor(o_origin.x, CHUNK_WIDTH_I32);
                            const ocz = @divFloor(o_origin.z, CHUNK_WIDTH_I32);
                            if ((ocx - kcx) * (ocx - kcx) + (ocz - kcz) * (ocz - kcz) <= unload_lr_sq) {
                                needed_by_other = true;
                                break;
                            }
                        }
                    }
                    if (!needed_by_other) {
                        to_unload.append(self.allocator, key.*) catch continue;
                    }
                }
                for (to_unload.items) |origin| self.block_world.unloadChunk(origin);
            } else {
                // 远程玩家：增量发送新出现的区块 + 卸载已远离的区块
                const pid = player.id;
                const gop = try self.player_chunks.getOrPut(self.allocator, pid);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                const loaded = &gop.value_ptr.*;

                const load_range: i32 = self.chunk_radius;
                const lr_sq = load_range * load_range;
                const unload_lr_sq = (load_range + 2) * (load_range + 2);

                // 新出现的区块
                var dx: i32 = -load_range;
                while (dx <= load_range) : (dx += 1) {
                    var dz: i32 = -load_range;
                    while (dz <= load_range) : (dz += 1) {
                        if (dx * dx + dz * dz > lr_sq) continue;
                        const origin = Vec3i.new(player_origin.x + dx * CHUNK_WIDTH_I32, 0, player_origin.z + dz * CHUNK_WIDTH_I32);
                        if (self.block_world.chunks.contains(origin)) {
                            var already = false;
                            for (loaded.items) |o| {
                                if (o.x == origin.x and o.z == origin.z) {
                                    already = true;
                                    break;
                                }
                            }
                            if (already) continue;
                            try loaded.append(self.allocator, origin);
                            self.enqueueChunkUpdate(origin);
                        } else {
                            self.block_world.loadChunk(origin) catch {};
                        }
                    }
                }

                // 找出已远离的区块（在已发送列表中但不在新范围内）
                var to_unload: std.ArrayListUnmanaged(Vec3i) = .empty;
                defer to_unload.deinit(self.allocator);
                for (loaded.items) |origin| {
                    const ocx = @divFloor(origin.x, CHUNK_WIDTH_I32);
                    const ocz = @divFloor(origin.z, CHUNK_WIDTH_I32);
                    if ((pcx - ocx) * (pcx - ocx) + (pcz - ocz) * (pcz - ocz) > unload_lr_sq) {
                        try to_unload.append(self.allocator, origin);
                    }
                }
                for (to_unload.items) |origin| {
                    // 从已发送列表中移除
                    for (loaded.items, 0..) |o, idx| {
                        if (o.x == origin.x and o.z == origin.z) {
                            _ = loaded.swapRemove(idx);
                            break;
                        }
                    }
                    // 入队卸载指令（网络线程会发 unload 包给客机）
                    self.enqueueChunkUnload(origin);
                }
            }
        }
    }
};
