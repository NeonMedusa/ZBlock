// block_world.zig
const std = @import("std");
const Imports = @import("imports.zig");
const Vec3 = Imports.Vec3;
const Vec3i = Imports.Vec3i;
const Vec4 = Imports.Vec4;
const Quat = Imports.Quat;
const Wgpu = Imports.Wgpu;
const Gctx = Imports.Gctx;
const RenderPipeline = @import("render_pipeline.zig");
const Perlin = @import("perlin.zig");
const ECS = Imports.ECS;
const Comps = Imports.Comps;
const AABB = @import("aabb.zig").AABB;
const Direction = @import("direction.zig").Direction;
const BlockId = @import("block_registry.zig").BlockId;
const BlockState = @import("block_registry.zig").BlockState;
const Pathfind = @import("pathfind.zig");

pub const CHUNK_SIZE_X: u32 = 16;
pub const CHUNK_SIZE_Y: u32 = 256;
pub const CHUNK_SIZE_Z: u32 = 16;
pub const CHUNK_SIZE_X_I32: i32 = CHUNK_SIZE_X;
pub const CHUNK_SIZE_Z_I32: i32 = CHUNK_SIZE_Z;

pub const Chunk = struct {
    blocks: [CHUNK_SIZE_X][CHUNK_SIZE_Y][CHUNK_SIZE_Z]BlockState,

    pub fn generate(world_origin: Vec3i, out_chunk: *Chunk) void {
        const noise_scale: f32 = 0.02;
        const world_height: i32 = 128;
        const water_height: i32 = 64;

        for (0..CHUNK_SIZE_X) |x| {
            for (0..CHUNK_SIZE_Z) |z| {
                const world_x = world_origin.x + @as(i32, @intCast(x));
                const world_z = world_origin.z + @as(i32, @intCast(z));
                const noise_val = Perlin.perlin2d(
                    @as(f32, @floatFromInt(world_x)) * noise_scale,
                    @as(f32, @floatFromInt(world_z)) * noise_scale,
                );
                const ground_position: i32 = @intFromFloat(noise_val * @as(f32, @floatFromInt(world_height)));

                for (0..CHUNK_SIZE_Y) |y| {
                    const y_i32: i32 = @intCast(y);
                    const block_id: BlockId = blk: {
                        if (y_i32 > ground_position) {
                            if (y_i32 < water_height) break :blk .fromName("water");
                            break :blk .fromName("air");
                        } else if (y_i32 == ground_position) {
                            if (y_i32 < water_height) break :blk .fromName("sand");
                            break :blk .fromName("grass");
                        } else {
                            const depth = ground_position - y_i32;
                            if (depth >= 5) break :blk .fromName("stone");
                            break :blk .fromName("dirt");
                        }
                    };
                    out_chunk.blocks[x][y][z] = BlockState.init(block_id);
                }
            }
        }
    }
};

/// u3 最多 8 种变体
const ChunkMesh = @import("chunk_mesh.zig");
const MAX_MATERIALS = ChunkMesh.MAX_MATERIALS;
const MaterialIdx = ChunkMesh.MaterialIdx;
const MaterialKey = ChunkMesh.MaterialKey;
const GlobalMaterial = ChunkMesh.GlobalMaterial;
const MaterialRegistry = ChunkMesh.MaterialRegistry;
const ChunkMeshCache = ChunkMesh.ChunkMeshCache;
const MeshBuildResult = ChunkMesh.MeshBuildResult;
const buildChunkMeshCPU = ChunkMesh.buildChunkMeshCPU;
const applyMeshResult = ChunkMesh.applyMeshResult;

/// 物理常量（可调整）
const GRAVITY: f32 = 25.0;
const FLUID_GRAVITY: f32 = 5.0;
const SWIM_UP_SPEED: f32 = 5.0;
const SWIM_DOWN_SPEED: f32 = 3.0;
const SINK_TERMINAL: f32 = -2.0;
const GROUND_FRICTION: f32 = 0.6;
const AIR_FRICTION: f32 = 4.0;
const ACCELERATION: f32 = 30.0;

const LoadedChunk = struct {
    chunk: *Chunk,
    mesh_cache: ChunkMeshCache,
    build_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const NEIGHBOR_OFFSETS = [_]struct { x: i32, z: i32 }{
    .{ .x = 0, .z = 0 },
    .{ .x = -1, .z = 0 },
    .{ .x = 1, .z = 0 },
    .{ .x = 0, .z = -1 },
    .{ .x = 0, .z = 1 },
};

pub const BlockWorld = struct {
    allocator: std.mem.Allocator,
    gctx: *Gctx,
    pipeline: *RenderPipeline,
    material_registry: MaterialRegistry,
    chunks: std.AutoHashMap(Vec3i, LoadedChunk),
    collision_list: std.ArrayListUnmanaged(AABB) = .{},

    pending: std.AutoHashMap(Vec3i, void),
    pending_mutex: std.Thread.Mutex = .{},
    completed: std.ArrayListUnmanaged(MeshBuildResult),
    completed_mutex: std.Thread.Mutex = .{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    worker: ?std.Thread = null,
    worker_gpa: std.heap.GeneralPurposeAllocator(.{}),
    astar_states: std.AutoHashMap(ECS.Entity, Pathfind.AStarState),

    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, pipeline: *RenderPipeline, max_chunks: usize) !BlockWorld {
        var material_registry = try MaterialRegistry.init(allocator, gctx, pipeline);
        errdefer material_registry.deinit();

        var chunks = std.AutoHashMap(Vec3i, LoadedChunk).init(allocator);
        errdefer chunks.deinit();
        try chunks.ensureTotalCapacity(@intCast(max_chunks));

        var pending = std.AutoHashMap(Vec3i, void).init(allocator);
        errdefer pending.deinit();

        var astar_states = std.AutoHashMap(ECS.Entity, Pathfind.AStarState).init(allocator);
        errdefer astar_states.deinit();

        return BlockWorld{
            .allocator = allocator,
            .gctx = gctx,
            .pipeline = pipeline,
            .material_registry = material_registry,
            .chunks = chunks,
            .pending = pending,
            .completed = .{},
            .worker_gpa = .{},
            .astar_states = astar_states,
        };
    }

    pub fn spawnWorker(self: *BlockWorld) !void {
        self.worker = try std.Thread.spawn(.{}, workerFn, .{self});
    }

    pub fn deinit(self: *BlockWorld) void {
        // 通知worker停止
        self.running.store(false, .release);
        if (self.worker) |w| {
            w.join();
        }
        self.worker = null;

        // 清理剩余completed结果（由worker_gpa分配）
        for (self.completed.items) |*r| r.deinit();
        self.completed.deinit(self.worker_gpa.allocator());

        // 直接释放所有区块（不走unloadChunk的pending/build_lock检查）
        {
            var it = self.chunks.valueIterator();
            while (it.next()) |loaded| {
                loaded.mesh_cache.deinit();
                self.allocator.destroy(loaded.chunk);
            }
            self.chunks.clearAndFree();
        }
        self.pending.deinit();
        self.material_registry.deinit();
        self.collision_list.deinit(self.allocator);

        {
            var it = self.astar_states.valueIterator();
            while (it.next()) |state| {
                Pathfind.deinitAStar(state);
            }
            self.astar_states.deinit();
        }

        _ = self.worker_gpa.deinit();
    }

    pub fn chunkOrigin(world_x: i32, world_z: i32) Vec3i {
        return Vec3i.new(
            @divFloor(world_x, CHUNK_SIZE_X_I32) * CHUNK_SIZE_X_I32,
            0,
            @divFloor(world_z, CHUNK_SIZE_Z_I32) * CHUNK_SIZE_Z_I32,
        );
    }

    fn enqueueMeshBuild(self: *BlockWorld, origin: Vec3i) !void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        try self.pending.put(origin, {});
    }

    pub fn pendingCount(self: *BlockWorld) usize {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        return self.pending.count();
    }

    pub fn processCompletedBuilds(self: *BlockWorld) !void {
        self.completed_mutex.lock();
        defer self.completed_mutex.unlock();

        for (self.completed.items) |*result| {
            if (self.chunks.getPtr(result.origin)) |loaded| {
                applyMeshResult(&loaded.mesh_cache, result) catch |err| {
                    std.debug.print("applyMeshResult failed: {}\n", .{err});
                };
            }
            result.deinit();
        }
        self.completed.clearRetainingCapacity();
    }

    pub fn loadChunk(self: *BlockWorld, origin: Vec3i) !void {
        if (self.chunks.contains(origin)) return;
        const chunk = try self.allocator.create(Chunk);
        errdefer self.allocator.destroy(chunk);
        Chunk.generate(origin, chunk);
        var mesh_cache = try ChunkMeshCache.init(self.allocator, self.gctx, &self.material_registry);
        errdefer {
            mesh_cache.deinit();
            self.allocator.destroy(chunk);
        }
        // 持锁写chunks和pending，防止与worker的HashMap读并发
        {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();

            try self.chunks.put(origin, .{ .chunk = chunk, .mesh_cache = mesh_cache });
            std.debug.assert(self.chunks.count() <= self.chunks.capacity());
            try self.pending.put(origin, {});

            for (NEIGHBOR_OFFSETS[1..]) |noff| {
                const nb_origin = Vec3i.new(
                    origin.x + noff.x * CHUNK_SIZE_X_I32,
                    0,
                    origin.z + noff.z * CHUNK_SIZE_Z_I32,
                );
                if (self.chunks.getPtr(nb_origin)) |nb_loaded| {
                    if (nb_loaded.chunk != chunk) {
                        try self.pending.put(nb_origin, {});
                    }
                }
            }
        }
    }

    pub fn unloadChunk(self: *BlockWorld, origin: Vec3i) void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();

        if (self.pending.contains(origin)) return;

        if (self.chunks.getPtr(origin)) |loaded| {
            if (loaded.build_lock.load(.acquire)) return;

            for (NEIGHBOR_OFFSETS[1..]) |noff| {
                const nb_origin = Vec3i.new(
                    origin.x + noff.x * CHUNK_SIZE_X_I32,
                    0,
                    origin.z + noff.z * CHUNK_SIZE_Z_I32,
                );
                if (self.chunks.getPtr(nb_origin)) |nb_loaded| {
                    if (nb_loaded.build_lock.load(.acquire)) return;
                }
            }

            loaded.mesh_cache.deinit();
            self.allocator.destroy(loaded.chunk);
            _ = self.chunks.remove(origin);
        }
        self.material_registry.cleanupUnused();
    }

    pub fn setBlock(self: *BlockWorld, world_pos: Vec3i, block_id: BlockId) !void {
        const origin = chunkOrigin(world_pos.x, world_pos.z);
        if (self.chunks.getPtr(origin)) |loaded| {
            const lx: u32 = @intCast(world_pos.x - origin.x);
            const ly: u32 = @intCast(world_pos.y - origin.y);
            const lz: u32 = @intCast(world_pos.z - origin.z);
            loaded.chunk.blocks[lx][ly][lz] = BlockState.init(block_id);
            try self.enqueueMeshBuild(origin);

            const dirs = std.enums.values(Direction);
            for (dirs) |dir| {
                const offset = dir.offset();
                const nx = world_pos.x + offset.x;
                const nz = world_pos.z + offset.z;
                const neighbor_origin = chunkOrigin(nx, nz);
                if (neighbor_origin.x != origin.x or neighbor_origin.y != origin.y or neighbor_origin.z != origin.z) {
                    if (self.chunks.contains(neighbor_origin)) {
                        try self.enqueueMeshBuild(neighbor_origin);
                    }
                }
            }
        }
    }

    pub fn updatePhysics(self: *BlockWorld, registry: *ECS.Registry, dt: f32) void {
        var view = registry.view(.{
            Comps.Position,
            Comps.Velocity,
            Comps.Collider,
            Comps.MoveSpeed,
            Comps.JumpVelocity,
            Comps.OnGround,
            Comps.MoveIntent,
        }, .{});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const pos = view.get(Comps.Position, entity);
            const vel = view.get(Comps.Velocity, entity);
            const aabb = view.get(Comps.Collider, entity);
            const move_speed = view.get(Comps.MoveSpeed, entity);
            const jump_vel = view.get(Comps.JumpVelocity, entity);
            const on_ground = view.get(Comps.OnGround, entity);
            var intent = view.get(Comps.MoveIntent, entity);

            const in_swimmable = self.isInSwimmable(pos, aabb);
            const resistance: f32 = if (in_swimmable) blk: {
                const mid = pos.vec.add(Vec3.new(0, aabb.height * 0.5, 0));
                const block_id = self.getBlockAt(mid);
                const fluid_proto = block_id.prototype();
                break :blk if (fluid_proto.is_swimmable) fluid_proto.fluid_resistance else 0.0;
            } else 0.0;

            const effective_gravity: f32 = if (in_swimmable) FLUID_GRAVITY else GRAVITY;
            const max_speed = move_speed.value * (1.0 - resistance);
            const acceleration = ACCELERATION * (1.0 - resistance);

            if (in_swimmable) {
                if (intent.direction.y > 0.0) {
                    vel.vec.y = SWIM_UP_SPEED;
                    on_ground.value = false;
                } else if (intent.direction.y < 0.0) {
                    vel.vec.y = -SWIM_DOWN_SPEED;
                    on_ground.value = false;
                } else {
                    vel.vec.y -= effective_gravity * dt;
                    if (vel.vec.y < SINK_TERMINAL) vel.vec.y = SINK_TERMINAL;
                }
            } else {
                vel.vec.y -= effective_gravity * dt;
                if (intent.jump and on_ground.value) {
                    vel.vec.y = jump_vel.value;
                    on_ground.value = false;
                }
            }

            var h_vel = Vec3.new(vel.vec.x, 0, vel.vec.z);
            const move_dir = Vec3.new(intent.direction.x, 0, intent.direction.z);
            if (move_dir.len2() > 0.001) {
                const wish_dir = move_dir.norm();
                h_vel = h_vel.add(wish_dir.scale(acceleration * dt));
                const h_speed = h_vel.len();
                if (h_speed > max_speed) h_vel = h_vel.scale(max_speed / h_speed);
            } else {
                if (on_ground.value) {
                    h_vel = h_vel.scale(GROUND_FRICTION);
                } else {
                    const h_speed = h_vel.len();
                    if (h_speed > 0.001) {
                        const reduction = AIR_FRICTION * dt;
                        const new_speed = @max(h_speed - reduction, 0);
                        h_vel = h_vel.scale(new_speed / h_speed);
                    }
                }
            }
            vel.vec.x = h_vel.x;
            vel.vec.z = h_vel.z;

            const dx = vel.vec.x * dt;
            const dy = vel.vec.y * dt;
            const dz = vel.vec.z * dt;
            self.moveEntity(pos, vel, aabb, on_ground, &self.collision_list, dx, dy, dz);

            intent.jump = false;
        }

        // 实体间碰撞：基于重叠深度的排斥力，不改变位置
        {
            const REPEL_FORCE: f32 = 3.0;
            var push_view = registry.view(.{ Comps.Position, Comps.Collider, Comps.Velocity }, .{});
            var push_iter_a = push_view.entityIterator();
            while (push_iter_a.next()) |entity_a| {
                const pos_a = push_view.get(Comps.Position, entity_a);
                const col_a = push_view.get(Comps.Collider, entity_a);
                const vel_a = push_view.get(Comps.Velocity, entity_a);
                const box_a = getEntityAABB(pos_a.vec, col_a);

                var push_iter_b = push_view.entityIterator();
                while (push_iter_b.next()) |entity_b| {
                    if (@as(u32, @bitCast(entity_b)) <= @as(u32, @bitCast(entity_a))) continue;
                    const pos_b = push_view.get(Comps.Position, entity_b);
                    const col_b = push_view.get(Comps.Collider, entity_b);
                    const vel_b = push_view.get(Comps.Velocity, entity_b);
                    const box_b = getEntityAABB(pos_b.vec, col_b);

                    if (box_a.min_x < box_b.max_x and box_a.max_x > box_b.min_x and
                        box_a.min_y < box_b.max_y and box_a.max_y > box_b.min_y and
                        box_a.min_z < box_b.max_z and box_a.max_z > box_b.min_z)
                    {
                        const dx = pos_b.vec.x - pos_a.vec.x;
                        const dz = pos_b.vec.z - pos_a.vec.z;
                        const dist = @max(@sqrt(dx * dx + dz * dz), 0.001);
                        const nx = dx / dist;
                        const nz = dz / dist;

                        const overlap_x = @min(box_a.max_x - box_b.min_x, box_b.max_x - box_a.min_x);
                        const overlap_z = @min(box_a.max_z - box_b.min_z, box_b.max_z - box_a.min_z);
                        const push = @max(overlap_x, overlap_z) * REPEL_FORCE;

                        vel_a.vec.x -= nx * push;
                        vel_a.vec.z -= nz * push;
                        vel_b.vec.x += nx * push;
                        vel_b.vec.z += nz * push;
                    }
                }
            }
        }
    }

    pub fn updateAIAgent(registry: *ECS.Registry, player_pos: Vec3) void {
        var view = registry.view(.{ Comps.AIAgent, Comps.Position }, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            var agent = view.get(Comps.AIAgent, entity);
            const pos = view.get(Comps.Position, entity);
            const info = agent.type_id.info();

            const dx = player_pos.x - pos.vec.x;
            const dz = player_pos.z - pos.vec.z;
            const dist = @sqrt(dx * dx + dz * dz);

            if (dist < info.detect_range) {
                agent.target = player_pos;
            }
        }
    }

    pub fn updateAI(self: *BlockWorld, registry: *ECS.Registry, dt: f32) void {
        const STUCK_TIMEOUT: f32 = 4.0;
        const ASTAR_STEPS_PER_FRAME: u16 = 50;

        var view = registry.view(.{
            Comps.AIAgent,        Comps.Position, Comps.Velocity,     Comps.MoveSpeed,
            Comps.MoveIntent,     Comps.OnGround, Comps.JumpVelocity, Comps.Collider,
            Comps.AttackCooldown,
        }, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const pos = view.get(Comps.Position, entity);
            var agent = view.get(Comps.AIAgent, entity);
            const info = agent.type_id.info();
            const collider = view.get(Comps.Collider, entity);
            var intent = view.get(Comps.MoveIntent, entity);
            const on_ground = view.get(Comps.OnGround, entity);
            var cooldown = view.get(Comps.AttackCooldown, entity);

            const dx = agent.target.x - pos.vec.x;
            const dy = agent.target.y - pos.vec.y;
            const dz = agent.target.z - pos.vec.z;
            const dist_3d = @sqrt(dx * dx + dy * dy + dz * dz);

            intent.jump = false;
            intent.direction = Vec3.zero;

            if (cooldown.timer > 0) {
                cooldown.timer -= dt;
            }

            if (dist_3d < info.attack_range and cooldown.timer <= 0) {
                cooldown.timer = cooldown.interval;
            }

            // Step ongoing A* if any
            if (self.astar_states.getPtr(entity)) |astar| {
                if (astar.result == .pending) {
                    Pathfind.stepAStar(astar, self, ASTAR_STEPS_PER_FRAME);
                }
                if (astar.result == .found) {
                    if (Pathfind.buildAStarPath(astar)) |new_path| {
                        if (agent.path) |*p| p.deinit(self.allocator);
                        agent.path = new_path;
                        agent.path_index = 0;
                        agent.stuck_timer = STUCK_TIMEOUT;
                        agent.last_pos = pos.vec;
                    } else |_| {}
                    Pathfind.deinitAStar(astar);
                    _ = self.astar_states.remove(entity);
                } else if (astar.result == .failed) {
                    Pathfind.deinitAStar(astar);
                    _ = self.astar_states.remove(entity);
                }
            }

            // Movement: follow path if available, otherwise greedy
            if (agent.path) |*path| {
                var blocked = false;
                if (agent.path_index < path.items.len) {
                    const wp = path.items[agent.path_index];
                    const wpx = @as(i32, @intFromFloat(@floor(wp.x)));
                    const wpz = @as(i32, @intFromFloat(@floor(wp.z)));
                    const wpy = @as(i32, @intFromFloat(@round(wp.y)));
                    const ground = Pathfind.findGroundBelow(self, wpx, wpz, wpy - 1);
                    if (ground == null or ground.? != wpy) {
                        blocked = true;
                    }
                }

                const moved = @sqrt((pos.vec.x - agent.last_pos.x) * (pos.vec.x - agent.last_pos.x) +
                    (pos.vec.z - agent.last_pos.z) * (pos.vec.z - agent.last_pos.z));
                agent.last_pos = pos.vec;
                if (moved < 0.01) {
                    agent.stuck_timer -= dt;
                } else {
                    agent.stuck_timer = STUCK_TIMEOUT;
                }

                if (blocked or agent.stuck_timer <= 0) {
                    path.deinit(self.allocator);
                    agent.path = null;
                } else if (agent.path_index < path.items.len) {
                    const waypoint = path.items[agent.path_index];
                    const wdx = waypoint.x - pos.vec.x;
                    const wdz = waypoint.z - pos.vec.z;
                    const wdist = @sqrt(wdx * wdx + wdz * wdz);

                    if (wdist < 0.5) {
                        agent.path_index += 1;
                        agent.stuck_timer = STUCK_TIMEOUT;
                    } else {
                        intent.direction = Vec3.new(wdx / wdist, 0, wdz / wdist);
                    }
                } else {
                    path.deinit(self.allocator);
                    agent.path = null;
                }
                // } else if (dist_3d > 0.5) {
                //     const d = @sqrt(dx * dx + dz * dz);
                //     if (d > 0.01) {
                //         intent.direction = Vec3.new(dx / d, 0, dz / d);
                //     }
            }

            // If no path, start pathfinding
            if (agent.path == null and !self.astar_states.contains(entity)) {
                const start_grid = Pathfind.GridPos{
                    .x = @intFromFloat(@floor(pos.vec.x)),
                    .y = @intFromFloat(@round(pos.vec.y)),
                    .z = @intFromFloat(@floor(pos.vec.z)),
                };
                const end_grid = Pathfind.GridPos{
                    .x = @intFromFloat(@floor(agent.target.x)),
                    .y = @intFromFloat(@round(agent.target.y)),
                    .z = @intFromFloat(@floor(agent.target.z)),
                };
                if (!start_grid.eql(end_grid)) {
                    var astar = Pathfind.initAStar(self.allocator, self, pos.vec, agent.target) catch continue;
                    self.astar_states.put(entity, astar) catch {
                        Pathfind.deinitAStar(&astar);
                        continue;
                    };
                }
            }

            // Jump logic
            if (intent.direction.x != 0 or intent.direction.z != 0) {
                const ahead = pos.vec.add(intent.direction.norm().scale(0.55));
                const block_ahead = self.getBlockAt(ahead);
                if (block_ahead.prototype().is_solid and on_ground.value) {
                    const above = ahead.add(Vec3.new(0, collider.height + 0.1, 0));
                    if (!self.getBlockAt(above).prototype().is_solid) {
                        const head_above = pos.vec.add(Vec3.new(0, collider.height + 0.1, 0));
                        if (!self.getBlockAt(head_above).prototype().is_solid) {
                            intent.jump = true;
                        }
                    }
                }
            }
        }
    }

    pub fn cleanupEntity(self: *BlockWorld, registry: *ECS.Registry, entity: ECS.Entity) void {
        if (self.astar_states.getPtr(entity)) |astar| {
            Pathfind.deinitAStar(astar);
            _ = self.astar_states.remove(entity);
        }
        if (registry.tryGet(Comps.AIAgent, entity)) |agent| {
            if (agent.path) |*p| {
                p.deinit(self.allocator);
                agent.path = null;
            }
        }
    }

    /// 获取实体的轴对齐包围盒 (AABB)
    /// pos 是实体的脚底中心位置 (即 min_y = pos.y)
    pub fn getEntityAABB(pos: Vec3, collider: *Comps.Collider) AABB {
        const half_w = collider.width / 2.0;
        return AABB{
            .min_x = pos.x - half_w,
            .max_x = pos.x + half_w,
            .min_y = pos.y,
            .max_y = pos.y + collider.height,
            .min_z = pos.z - half_w,
            .max_z = pos.z + half_w,
        };
    }

    fn moveEntity(
        self: *BlockWorld,
        pos: *Comps.Position,
        vel: *Comps.Velocity,
        collider: *Comps.Collider,
        on_ground: *Comps.OnGround,
        out_list: *std.ArrayListUnmanaged(AABB),
        xd: f32,
        yd: f32,
        zd: f32,
    ) void {
        var dx = xd;
        var dy = yd;
        var dz = zd;
        var box = getEntityAABB(pos.vec, collider);

        out_list.clearRetainingCapacity();
        self.getCollidingBlocks(box.expand(dx, dy, dz), out_list);

        for (out_list.items) |block| {
            dy = block.clipYCollide(box, dy);
        }
        box = box.move(0, dy, 0);
        const was_falling = yd < 0;
        const blocked_y = (yd != dy);
        on_ground.value = blocked_y and was_falling;
        if (on_ground.value) vel.vec.y = 0;

        for (out_list.items) |block| {
            dx = block.clipXCollide(box, dx);
        }
        box = box.move(dx, 0, 0);

        for (out_list.items) |block| {
            dz = block.clipZCollide(box, dz);
        }
        box = box.move(0, 0, dz);

        pos.vec.x = (box.min_x + box.max_x) / 2.0;
        pos.vec.z = (box.min_z + box.max_z) / 2.0;
        pos.vec.y = box.min_y;
    }

    fn getCollidingBlocks(self: *BlockWorld, expanded_box: AABB, out_list: *std.ArrayListUnmanaged(AABB)) void {
        const min_x = @as(i32, @intFromFloat(@floor(expanded_box.min_x)));
        const max_x = @as(i32, @intFromFloat(@floor(expanded_box.max_x)));
        const min_y = @as(i32, @intFromFloat(@floor(expanded_box.min_y)));
        const max_y = @as(i32, @intFromFloat(@floor(expanded_box.max_y)));
        const min_z = @as(i32, @intFromFloat(@floor(expanded_box.min_z)));
        const max_z = @as(i32, @intFromFloat(@floor(expanded_box.max_z)));

        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                var z = min_z;
                while (z <= max_z) : (z += 1) {
                    const world_pos = Vec3.new(
                        @as(f32, @floatFromInt(x)) + 0.5,
                        @as(f32, @floatFromInt(y)) + 0.5,
                        @as(f32, @floatFromInt(z)) + 0.5,
                    );
                    const block_id = self.getBlockAt(world_pos);
                    if (block_id == BlockId.fromName("air")) continue;
                    if (!block_id.prototype().is_solid) continue;
                    const bb = AABB{
                        .min_x = @floatFromInt(x),
                        .max_x = @floatFromInt(x + 1),
                        .min_y = @floatFromInt(y),
                        .max_y = @floatFromInt(y + 1),
                        .min_z = @floatFromInt(z),
                        .max_z = @floatFromInt(z + 1),
                    };
                    out_list.append(self.allocator, bb) catch continue;
                }
            }
        }
    }

    fn isInSwimmable(self: *BlockWorld, pos: *Comps.Position, collider: *Comps.Collider) bool {
        const points = [_]Vec3{
            pos.vec.add(Vec3.new(0, 0.1, 0)),
            pos.vec.add(Vec3.new(0, collider.height * 0.5, 0)),
            pos.vec.add(Vec3.new(0, collider.height - 0.1, 0)),
        };
        for (points) |p| {
            if (self.getBlockAt(p).prototype().is_swimmable) return true;
        }
        return false;
    }

    /// Worker 线程安全版本：直接从已知的 chunk 读取方块
    pub fn getBlockAtFromChunk(chunk: *const Chunk, origin: Vec3i, world_x: i32, world_y: i32, world_z: i32) BlockId {
        const local_x = world_x - origin.x;
        const local_y = world_y - origin.y;
        const local_z = world_z - origin.z;
        if (local_x >= 0 and local_x < CHUNK_SIZE_X and
            local_y >= 0 and local_y < CHUNK_SIZE_Y and
            local_z >= 0 and local_z < CHUNK_SIZE_Z)
        {
            return chunk.blocks[@intCast(local_x)][@intCast(local_y)][@intCast(local_z)].block_id;
        }
        return .fromName("air");
    }

    pub fn getBlockAt(self: *BlockWorld, world_pos: Vec3) BlockId {
        const x = @as(i32, @intFromFloat(@floor(world_pos.x)));
        const y = @as(i32, @intFromFloat(@floor(world_pos.y)));
        const z = @as(i32, @intFromFloat(@floor(world_pos.z)));

        const origin = chunkOrigin(x, z);

        if (self.chunks.getPtr(origin)) |loaded| {
            return getBlockAtFromChunk(loaded.chunk, origin, x, y, z);
        }
        return .fromName("air");
    }
};

fn workerFn(world: *BlockWorld) void {
    const alloc = world.worker_gpa.allocator();
    while (world.running.load(.acquire)) {
        // 取任务
        world.pending_mutex.lock();

        var origin: ?Vec3i = null;
        var iter = world.pending.keyIterator();
        if (iter.next()) |key_ptr| {
            origin = key_ptr.*;
        }

        var loaded_ptr_chunks: [NEIGHBOR_OFFSETS.len]?*LoadedChunk = [_]?*LoadedChunk{null} ** NEIGHBOR_OFFSETS.len;
        if (origin) |o| {
            loaded_ptr_chunks[0] = world.chunks.getPtr(o);
            if (loaded_ptr_chunks[0] != null) {
                loaded_ptr_chunks[0].?.build_lock.store(true, .release);
                for (NEIGHBOR_OFFSETS[1..], 1..) |noff, i| {
                    const nb = Vec3i.new(o.x + noff.x * CHUNK_SIZE_X_I32, 0, o.z + noff.z * CHUNK_SIZE_Z_I32);
                    loaded_ptr_chunks[i] = world.chunks.getPtr(nb);
                    if (loaded_ptr_chunks[i]) |l| {
                        l.build_lock.store(true, .release);
                    }
                }
                _ = world.pending.remove(o);
            }
        }
        world.pending_mutex.unlock();

        if (origin) |o| {
            if (loaded_ptr_chunks[0]) |loaded| {
                const nb_w: ?*const Chunk = if (loaded_ptr_chunks[1]) |l| l.chunk else null;
                const nb_e: ?*const Chunk = if (loaded_ptr_chunks[2]) |l| l.chunk else null;
                const nb_n: ?*const Chunk = if (loaded_ptr_chunks[3]) |l| l.chunk else null;
                const nb_s: ?*const Chunk = if (loaded_ptr_chunks[4]) |l| l.chunk else null;

                var result = buildChunkMeshCPU(alloc, o, loaded.chunk, nb_w, nb_e, nb_n, nb_s) catch {
                    // 释放所有build_lock
                    for (loaded_ptr_chunks) |opt_l| {
                        if (opt_l) |l| l.build_lock.store(false, .release);
                    }
                    continue;
                };

                // 释放build_lock
                for (loaded_ptr_chunks) |opt_l| {
                    if (opt_l) |l| l.build_lock.store(false, .release);
                }

                world.completed_mutex.lock();
                world.completed.append(alloc, result) catch {
                    result.deinit();
                };
                world.completed_mutex.unlock();
            }
        } else {
            std.Thread.yield() catch {};
        }
    }
}
