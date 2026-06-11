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
const Noise = @import("noise.zig");
const ECS = Imports.ECS;
const Comps = Imports.Comps;
const AABB = @import("aabb.zig").AABB;
const Direction = @import("direction.zig").Direction;
const BlockId = @import("block_registry.zig").BlockId;
const BlockState = @import("block_registry.zig").BlockState;
const MAX_BLOCKS = @import("block_registry.zig").MAX_BLOCKS;
const Pathfind = @import("pathfind.zig");
const bitstream = @import("bitstream.zig");
const readBits = bitstream.readBits;
const writeBits = bitstream.writeBits;
const fr = @import("fridge");
const registries = @import("registries.zig");

pub const CHUNK_WIDTH: u32 = 16;
pub const CHUNK_HEIGHT: u32 = 255;

// 如需支持更高高度，两种方案（详见 DESIGN.md 议题五）：
// A) 增大 CHUNK_HEIGHT（需同步增加 ChunkVertex.by 位数）
// B) 用 Vec3i.y 分片叠层区块，保持 CHUNK_HEIGHT=255（此时 ChunkVertex.by 可缩回 u8）
pub const CHUNK_WIDTH_I32: i32 = CHUNK_WIDTH;
const CHUNK_BLOCKS: u32 = CHUNK_WIDTH * CHUNK_HEIGHT * CHUNK_WIDTH;

pub const Chunk = struct {
    allocator: std.mem.Allocator,
    palette: std.ArrayListUnmanaged(BlockState),
    index_bits: u5,
    index_data: []u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const buf_size = (CHUNK_BLOCKS + 7) / 8; // 1-bit 最小大小
        return Self{
            .allocator = allocator,
            .palette = .{},
            .index_bits = 1,
            .index_data = allocator.alloc(u8, buf_size) catch unreachable,
        };
    }

    pub fn deinit(self: *Self) void {
        self.palette.deinit(self.allocator);
        self.allocator.free(self.index_data);
    }

    fn bitOffset(self: *const Self, x: u32, y: u32, z: u32) usize {
        // 匹配原始 blocks[x][y][z] 布局: z 变化最快, 然后 y, x 最慢
        const index = z + CHUNK_WIDTH * (y + CHUNK_HEIGHT * x);
        return index * self.index_bits;
    }

    pub fn getBlock(self: *const Self, x: u32, y: u32, z: u32) BlockState {
        const offset = self.bitOffset(x, y, z);
        const idx = readBits(self.index_data, offset, self.index_bits);
        return self.palette.items[idx];
    }

    pub fn getBlockId(self: *const Self, x: u32, y: u32, z: u32) BlockId {
        return self.getBlock(x, y, z).block_id;
    }

    pub fn setBlock(self: *Self, x: u32, y: u32, z: u32, bs: BlockState) void {
        // 在 palette 中查找
        for (self.palette.items, 0..) |existing, i| {
            if (existing.block_id == bs.block_id and existing.facing == bs.facing) {
                const offset = self.bitOffset(x, y, z);
                writeBits(self.index_data, offset, @intCast(i), self.index_bits);
                return;
            }
        }
        // 未找到 → 追加到 palette
        const new_idx = self.palette.items.len;
        const needed_bits = if (new_idx <= 1) @as(u5, 1) else @as(u5, @intCast(std.math.log2_int(usize, new_idx) + 1));
        if (needed_bits > self.index_bits) {
            self.growIndexBits(needed_bits);
        }
        self.palette.append(self.allocator, bs) catch unreachable;
        const offset = self.bitOffset(x, y, z);
        writeBits(self.index_data, offset, @intCast(new_idx), self.index_bits);
    }

    fn growIndexBits(self: *Self, new_bits: u5) void {
        const old_bits = self.index_bits;
        const new_size = (CHUNK_BLOCKS * new_bits + 7) / 8;
        const new_data = self.allocator.alloc(u8, new_size) catch unreachable;
        @memset(new_data, 0);

        for (0..CHUNK_WIDTH) |x| {
            for (0..CHUNK_WIDTH) |z| {
                for (0..CHUNK_HEIGHT) |y| {
                    const idx = x + CHUNK_WIDTH * (z + CHUNK_WIDTH * y);
                    const old_offset = idx * old_bits;
                    const val = readBits(self.index_data, old_offset, old_bits);
                    const new_offset = idx * new_bits;
                    writeBits(new_data, new_offset, val, new_bits);
                }
            }
        }

        self.allocator.free(self.index_data);
        self.index_data = new_data;
        self.index_bits = new_bits;
    }

    pub fn generate(world_origin: Vec3i, out_chunk: *Chunk) void {
        // 第一阶段：用固定大小数组做 lookup（block_infos 编译期已知，≤ 256 种）
        var temp_pal = std.ArrayListUnmanaged(BlockState){};
        defer temp_pal.deinit(out_chunk.allocator);

        // idx_lookup[block_id_int] = palette_index，初始为 null
        var idx_lookup: [MAX_BLOCKS]?u32 = [_]?u32{null} ** MAX_BLOCKS;

        var temp_indices = std.ArrayListUnmanaged(u32){};
        defer temp_indices.deinit(out_chunk.allocator);
        temp_indices.ensureTotalCapacity(out_chunk.allocator, CHUNK_BLOCKS) catch unreachable;

        // === 噪声生成 ===
        const base_noise_scale: f32 = 0.005; // 地形特征尺度：越小→大陆越大/越平缓，越大→丘陵越碎
        const octaves: u32 = 6; // 噪声层数：越多→细节越丰富（性能↓），越少→越光滑
        const persistence: f32 = 0.5; // 每层振幅衰减：0.3→平坦，0.5→适中，0.7→崎岖

        // === 高度映射 ===
        // 公式: if noise < threshold → 平原 (线性); else → 山脉 (2^(slope×factor) 指数)
        const base_height: i32 = 32; // 最低海拔（海床/盆地底部），抬高→整体陆地上移
        const threshold: f32 = 0.55; // 平原→山脉分界点（noise 值）：越大→平原越多、山越少
        const plain_scale: f32 = 40.0; // 平原高度振幅：越大→平原起伏越剧烈
        const mountain_factor: f32 = 4.0; // 山脉陡峭指数：越大→山越高越尖，越小→山越矮越圆
        const mountain_scale: f32 = 40.0; // 山脉高度振幅：越大→山越高，越小→山越矮

        // === 生物群落分界 ===
        const sea_level: i32 = 48; // 海平面：低于此高度填充水
        const stone_line: i32 = 80; // 裸岩线：高于此高度地表为 stone（而非 grass）
        const snow_line: i32 = 120; // 雪线：高于此高度地表为 snow（而非 stone）
        const dirt_depth: i32 = 4; // 表土厚度：地表以下多少层为 dirt（之下为 stone）

        // === 垂直群落边界凹凸（使雪线/裸岩线自然弯曲） ===
        const biome_noise_scale: f32 = 0.8; // 弯曲频率：越大→细碎，越小→宽缓
        const biome_snow_range: f32 = 9.0; // 雪线偏移半振幅 ±9 格
        const biome_stone_range: f32 = 7.0; // 裸岩线偏移半振幅 ±7 格

        for (0..CHUNK_WIDTH) |x| {
            for (0..CHUNK_WIDTH) |z| {
                const world_x = world_origin.x + @as(i32, @intCast(x));
                const world_z = world_origin.z + @as(i32, @intCast(z));
                const noise_val = Noise.octavePerlin2d(
                    @as(f32, @floatFromInt(world_x)) * base_noise_scale,
                    @as(f32, @floatFromInt(world_z)) * base_noise_scale,
                    octaves,
                    persistence,
                );
                const base_height_f: f32 = @floatFromInt(base_height);
                const ground_position = @as(i32, @intFromFloat(if (noise_val < threshold)
                    base_height_f + noise_val * plain_scale
                else blk: {
                    const slope = (noise_val - threshold) / (1.0 - threshold);
                    break :blk base_height_f + threshold * plain_scale + (@exp2(slope * mountain_factor) - 1.0) * mountain_scale;
                }));

                const biome_noise = Noise.perlin2d(
                    @as(f32, @floatFromInt(world_x)) * biome_noise_scale,
                    @as(f32, @floatFromInt(world_z)) * biome_noise_scale,
                );
                const local_snow_line = snow_line + @as(i32, @intFromFloat(biome_noise * biome_snow_range * 2.0 - biome_snow_range));
                const local_stone_line = stone_line + @as(i32, @intFromFloat(biome_noise * biome_stone_range * 2.0 - biome_stone_range));

                for (0..CHUNK_HEIGHT) |y| {
                    const y_i32: i32 = @intCast(y);
                    const block_id: BlockId = blk: {
                        if (y_i32 > ground_position) {
                            if (y_i32 < sea_level) break :blk .fromName("water");
                            break :blk .fromName("air");
                        } else if (y_i32 == ground_position) {
                            if (y_i32 < sea_level) break :blk .fromName("sand");
                            if (y_i32 >= local_snow_line) break :blk .fromName("snow");
                            if (y_i32 >= local_stone_line) break :blk .fromName("stone");
                            break :blk .fromName("grass");
                        } else {
                            const depth = ground_position - y_i32;
                            if (depth > dirt_depth) break :blk .fromName("stone");
                            break :blk .fromName("dirt");
                        }
                    };
                    const bs = BlockState.init(block_id);
                    const id_int = @intFromEnum(bs.block_id);
                    const pal_idx = if (idx_lookup[id_int]) |idx| idx else blk: {
                        const new_idx = @as(u32, @intCast(temp_pal.items.len));
                        idx_lookup[id_int] = new_idx;
                        temp_pal.append(out_chunk.allocator, bs) catch unreachable;
                        break :blk new_idx;
                    };
                    temp_indices.appendAssumeCapacity(pal_idx);
                }
            }
        }

        // 第二阶段：一次性构建 palette + index_data
        const palette_count = temp_pal.items.len;
        out_chunk.index_bits = if (palette_count <= 1) 1 else @as(u5, @intCast(std.math.log2_int(usize, palette_count - 1) + 1));

        out_chunk.palette.deinit(out_chunk.allocator);
        out_chunk.palette = temp_pal;
        // 阻止 defer 释放——所有权已转给 out_chunk.palette
        temp_pal = .{};

        const buf_size = (CHUNK_BLOCKS * out_chunk.index_bits + 7) / 8;
        out_chunk.allocator.free(out_chunk.index_data);
        out_chunk.index_data = out_chunk.allocator.alloc(u8, buf_size) catch unreachable;
        @memset(out_chunk.index_data, 0);

        // 用 temp_indices 填充 index_data，按正确的 (x,y,z) 偏移
        // temp_indices 按 (x,z,y) 顺序存储，bitOffset 需按 (x,y,z) 重映射
        for (0..CHUNK_WIDTH) |x| {
            for (0..CHUNK_HEIGHT) |y| {
                for (0..CHUNK_WIDTH) |z| {
                    const noise_order_i = x * (CHUNK_WIDTH * CHUNK_HEIGHT) + z * CHUNK_HEIGHT + y;
                    const idx = temp_indices.items[noise_order_i];
                    const offset = (z + CHUNK_WIDTH * (y + CHUNK_HEIGHT * x)) * out_chunk.index_bits;
                    writeBits(out_chunk.index_data, offset, idx, out_chunk.index_bits);
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
const MeshBuildResult = ChunkMesh.MeshBuildResult;
const buildChunkMeshCPU = ChunkMesh.buildChunkMeshCPU;
const applyMeshResult = ChunkMesh.applyMeshResult;

/// 物理常量（可调整）
const GRAVITY: f32 = 30.0;
const FLUID_GRAVITY: f32 = 5.0;
pub const TICK_DT: f32 = 1.0 / 30.0; // 每秒 30 tick（Δt ≈ 0.033s），物理步长
const SWIM_UP_SPEED: f32 = 5.0;
const SWIM_DOWN_SPEED: f32 = 3.0;
const SINK_TERMINAL: f32 = -2.0;
const GROUND_FRICTION: f32 = 0.6;
const AIR_FRICTION: f32 = 4.0;
const ACCELERATION: f32 = 30.0;
const SPRINT_MULTIPLIER: f32 = 1.5;
const SNEAK_MULTIPLIER: f32 = 0.5;
const FLY_SPEED_MULTIPLIER: f32 = 2.3; // 飞行极速 = 走速 × 此值

const LoadedChunk = struct {
    chunk: *Chunk,
    meshes: std.AutoHashMap(MaterialIdx, ChunkMesh.ChunkMesh),
    build_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    dirty: bool = false, // 被修改过，需要写入存档
};

const NEIGHBOR_OFFSETS = [_]struct { x: i32, z: i32 }{
    .{ .x = 0, .z = 0 },
    .{ .x = -1, .z = 0 },
    .{ .x = 1, .z = 0 },
    .{ .x = 0, .z = -1 },
    .{ .x = 0, .z = 1 },
};

/// 异步 A* 队列条目（pending 和 completed 共用）
const AStarTask = struct { entity: ECS.Entity, state: Pathfind.AStarState };

/// 异步存档保存任务（主线程序列化数据，io worker 写 SQLite）
const SaveTask = struct {
    origin: Vec3i,
    palette_json: []u8, // 主线程分配的 JSON，io worker 读取，主线程 processCompletedSaves 释放
    index_data: []u8, // chunk.index_data 的拷贝
    palette_count: u32, // 用于计算 bpi
};

/// 异步区块加载结果（io worker 分配 Chunk，主线程接收后放入 chunks HashMap）
const LoadResult = struct {
    origin: Vec3i,
    chunk: *Chunk, // io worker 完全初始化的 Chunk，主线程直接接管
};

pub const BlockWorld = struct {
    allocator: std.mem.Allocator,
    gctx: *Gctx,
    pipeline: *RenderPipeline,
    material_registry: MaterialRegistry,
    chunks: std.AutoHashMap(Vec3i, LoadedChunk),
    collision_list: std.ArrayListUnmanaged(AABB) = .{},

    pending: std.AutoHashMap(Vec3i, void),
    mesh_mutex: std.Thread.Mutex = .{}, // 保护 mesh pending 队列
    /// 读写锁保护 chunks HashMap。
    /// A* worker 和 mesh worker 均只读（getPtr）→ lockShared 并发无竞争。
    /// 只有 loadChunk（put）和 unloadChunk（remove）持写锁，此时所有读者排队等待。
    /// 前提：init 中 chunks.ensureTotalCapacity 预设容量，运行期不扩容——否则扩容会改 metadata 导致其他线程 getPtr 崩溃。
    chunk_mutex: std.Thread.RwLock = .{},
    completed: std.ArrayListUnmanaged(MeshBuildResult),
    completed_mutex: std.Thread.Mutex = .{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    worker: ?std.Thread = null,
    worker_gpa: std.heap.GeneralPurposeAllocator(.{}),
    stale_targets: std.AutoHashMap(Pathfind.StaleKey, u32),
    last_exact_targets: std.AutoHashMap(ECS.Entity, Pathfind.GridPos),

    // 异步 A*：worker 持有 AStarState 所有权，通过队列与主线程交换
    astar_pending: std.ArrayListUnmanaged(AStarTask),
    astar_pending_mutex: std.Thread.Mutex = .{},
    astar_completed: std.ArrayListUnmanaged(AStarTask),
    astar_completed_mutex: std.Thread.Mutex = .{},
    astar_active: std.AutoHashMap(ECS.Entity, void), // 标记有 A* 在运行的实体
    astar_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    astar_worker: ?std.Thread = null,

    // 异步 IO worker：独立线程处理所有存档操作（SQLite 读写），不阻塞主线程
    save_worker: ?std.Thread = null,
    save_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    save_dir: []const u8, // 存档目录路径（如 "saves/world_1"），io worker 用它打开自己的 SQLite 连接

    // 异步存档保存队列
    pending_saves: std.ArrayListUnmanaged(SaveTask),
    pending_saves_mutex: std.Thread.Mutex = .{},
    completed_saves: std.ArrayListUnmanaged(SaveTask),
    completed_saves_mutex: std.Thread.Mutex = .{},

    // 异步区块加载队列（io worker 读 SQLite 或 generate，主线程接收后放入 chunks）
    pending_loads: std.ArrayListUnmanaged(Vec3i),
    pending_loads_mutex: std.Thread.Mutex = .{},
    completed_loads: std.ArrayListUnmanaged(LoadResult),
    completed_loads_mutex: std.Thread.Mutex = .{},

    // 去重：已入队正在处理的 load 请求
    io_active_loads: std.AutoHashMap(Vec3i, void),

    /// 所有 IO 任务（load + save）的总数，deinit/saveAllChunks 等待此值归零
    pending_io_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, pipeline: *RenderPipeline, chunk_radius: i32, save_name: []const u8) !BlockWorld {
        var material_registry = try MaterialRegistry.init(allocator, gctx, pipeline);
        errdefer material_registry.deinit();

        const count = (chunk_radius + 1) * (chunk_radius + 1);
        const max_chunks = count * 3; // 3x 预分配余量，覆盖加载 + 异步排队等场景

        var chunks = std.AutoHashMap(Vec3i, LoadedChunk).init(allocator);
        errdefer chunks.deinit();
        // 一次性分配，运行期永不扩容。原因:多线程通过 getPtr 取 chunk 指针，
        // 若扩容则整张表重排、旧指针全部失效→ mesh/A* worker 段错误。
        // 预分配容量 = max_chunks × 80% 负载因子 ≈ 可用槽数，足够装下所有实际 chunk。
        try chunks.ensureTotalCapacity(@intCast(max_chunks));

        var pending = std.AutoHashMap(Vec3i, void).init(allocator);
        errdefer pending.deinit();

        var astar_active = std.AutoHashMap(ECS.Entity, void).init(allocator);
        errdefer astar_active.deinit();

        var stale_targets = std.AutoHashMap(Pathfind.StaleKey, u32).init(allocator);
        errdefer stale_targets.deinit();

        var last_exact_targets = std.AutoHashMap(ECS.Entity, Pathfind.GridPos).init(allocator);
        errdefer last_exact_targets.deinit();

        return BlockWorld{
            .allocator = allocator,
            .gctx = gctx,
            .pipeline = pipeline,
            .material_registry = material_registry,
            .chunks = chunks,
            .pending = pending,
            .completed = .{},
            .worker_gpa = .{},
            .astar_active = astar_active,
            .stale_targets = stale_targets,
            .last_exact_targets = last_exact_targets,
            .astar_pending = .{},
            .astar_completed = .{},
            .save_dir = try std.fs.path.join(allocator, &.{ "saves", save_name }),
            .pending_saves = .{},
            .completed_saves = .{},
            .pending_loads = .{},
            .completed_loads = .{},
            .io_active_loads = std.AutoHashMap(Vec3i, void).init(allocator),
        };
    }

    pub fn spawnWorker(self: *BlockWorld) !void {
        self.worker = try std.Thread.spawn(.{}, meshWorkerFn, .{self});
    }

    pub fn spawnAStarWorker(self: *BlockWorld) !void {
        self.astar_worker = try std.Thread.spawn(.{}, astarWorkerFn, .{self});
    }

    pub fn spawnSaveWorker(self: *BlockWorld) !void {
        self.save_worker = try std.Thread.spawn(.{}, ioWorkerFn, .{self});
    }

    pub fn deinit(self: *BlockWorld) void {
        // 检查是否有未处理的 pending 任务（先不处理 completed，等 worker 停后再统一清理）
        const pending_count = self.pending_io_count.load(.acquire);
        if (pending_count > 0) {
            std.debug.print("WARNING: deinit with {d} pending IO tasks - data may be lost!\n", .{pending_count});
        }

        // 停止 IO worker（之后不会再 push 新的 completed）
        self.save_running.store(false, .release);
        if (self.save_worker) |w| {
            w.join();
        }
        self.save_worker = null;

        // 清理所有 IO 任务
        for (self.pending_saves.items) |*t| {
            self.allocator.free(t.palette_json);
            self.allocator.free(t.index_data);
        }
        self.pending_saves.deinit(self.allocator);
        for (self.completed_saves.items) |*t| {
            self.allocator.free(t.palette_json);
            self.allocator.free(t.index_data);
        }
        self.completed_saves.deinit(self.allocator);
        for (self.completed_loads.items) |*r| {
            r.chunk.deinit();
            self.allocator.destroy(r.chunk);
        }
        self.completed_loads.deinit(self.allocator);
        self.pending_loads.deinit(self.allocator);
        self.io_active_loads.deinit();
        self.allocator.free(self.save_dir);

        // 通知mesh worker停止
        self.running.store(false, .release);
        if (self.worker) |w| {
            w.join();
        }
        self.worker = null;

        // 清理 A* worker
        self.astar_running.store(false, .release);
        if (self.astar_worker) |w| {
            w.join();
        }
        self.astar_worker = null;
        for (self.astar_pending.items) |*t| Pathfind.deinitAStar(&t.state);
        self.astar_pending.deinit(self.allocator);
        for (self.astar_completed.items) |*t| Pathfind.deinitAStar(&t.state);
        self.astar_completed.deinit(self.allocator);

        // 清理剩余mesh completed结果
        for (self.completed.items) |*r| r.deinit();
        self.completed.deinit(self.allocator);

        // 直接释放所有区块（不走unloadChunk的pending/build_lock检查）
        {
            var it = self.chunks.valueIterator();
            while (it.next()) |loaded| {
                {
                    var mesh_it = loaded.meshes.iterator();
                    while (mesh_it.next()) |entry| {
                        entry.value_ptr.deinit(self.allocator);
                        self.material_registry.releaseById(entry.key_ptr.*);
                    }
                }
                loaded.meshes.deinit();
                loaded.chunk.deinit();
                self.allocator.destroy(loaded.chunk);
            }
            self.chunks.clearAndFree();
        }
        self.pending.deinit();
        self.material_registry.deinit();
        self.collision_list.deinit(self.allocator);

        {
            self.astar_active.deinit();
        }

        {
            self.stale_targets.deinit();
        }
        self.last_exact_targets.deinit();

        _ = self.worker_gpa.deinit();
    }

    /// 世界坐标 → chunk origin
    pub fn chunkOrigin(world_x: i32, world_z: i32) Vec3i {
        return Vec3i.new(
            @divFloor(world_x, CHUNK_WIDTH_I32) * CHUNK_WIDTH_I32,
            0,
            @divFloor(world_z, CHUNK_WIDTH_I32) * CHUNK_WIDTH_I32,
        );
    }

    fn enqueueMeshBuild(self: *BlockWorld, origin: Vec3i) !void {
        self.mesh_mutex.lock();
        defer self.mesh_mutex.unlock();
        try self.pending.put(origin, {});
    }

    /// 批量入队 mesh 构建请求（一次锁操作，减少锁争抢）
    fn enqueueMeshBuildBatch(self: *BlockWorld, origins: []const Vec3i) !void {
        self.mesh_mutex.lock();
        defer self.mesh_mutex.unlock();
        for (origins) |origin| {
            try self.pending.put(origin, {});
        }
    }

    /// 待构建 mesh 的 chunk 数量
    pub fn pendingCount(self: *BlockWorld) usize {
        self.mesh_mutex.lock();
        defer self.mesh_mutex.unlock();
        return self.pending.count();
    }

    pub fn processCompletedBuilds(self: *BlockWorld) !void {
        const start_ns = std.time.nanoTimestamp();
        self.completed_mutex.lock();
        defer self.completed_mutex.unlock();

        for (self.completed.items) |*r| {
            if (self.chunks.getPtr(r.origin)) |loaded| {
                applyMeshResult(&loaded.meshes, self.allocator, self.gctx, &self.material_registry, r) catch |err| {
                    std.debug.print("applyMeshResult failed: {}\n", .{err});
                };
            }
            r.deinit();
        }
        self.completed.clearRetainingCapacity();
        const elapsed_us = @as(u64, @intCast(@max(@as(i64, 0), std.time.nanoTimestamp() - start_ns))) / 1000;
        if (elapsed_us > 100000) std.debug.print("[TIMER] processCompletedBuilds: {d}us\n", .{elapsed_us});
    }

    /// 将脏区块数据拷贝入队，io worker 异步写入 SQLite
    pub fn enqueueSaveTask(self: *BlockWorld, origin: Vec3i, chunk: *const Chunk) !void {
        const start_ns = std.time.nanoTimestamp();
        const pal = chunk.palette.items;
        // 序列化 palette 为 JSON（同 saveChunk 格式）
        var json = try std.ArrayListUnmanaged(u8).initCapacity(self.allocator, pal.len * 16);
        try json.append(self.allocator, '[');
        for (pal, 0..) |bs, i| {
            if (i > 0) try json.append(self.allocator, ',');
            try json.append(self.allocator, '"');
            try json.appendSlice(self.allocator, bs.block_id.name());
            try json.append(self.allocator, '_');
            try json.append(self.allocator, @as(u8, '0') + @intFromEnum(bs.facing));
            try json.append(self.allocator, '"');
        }
        try json.append(self.allocator, ']');

        const palette_count = pal.len;
        const bpi = if (palette_count <= 1) 1 else @as(u32, @intCast(std.math.log2_int(usize, palette_count - 1) + 1));
        const data_size = (CHUNK_BLOCKS * bpi + 7) / 8;
        const idx_copy = try self.allocator.alloc(u8, data_size);
        @memcpy(idx_copy, chunk.index_data[0..data_size]);

        const json_owned = try json.toOwnedSlice(self.allocator);

        self.pending_saves_mutex.lock();
        defer self.pending_saves_mutex.unlock();
        try self.pending_saves.append(self.allocator, .{
            .origin = origin,
            .palette_json = json_owned,
            .index_data = idx_copy,
            .palette_count = @as(u32, @intCast(palette_count)),
        });
        _ = self.pending_io_count.fetchAdd(1, .release);
        const elapsed_us = @as(u64, @intCast(@max(@as(i64, 0), std.time.nanoTimestamp() - start_ns))) / 1000;
        if (elapsed_us > 100000) std.debug.print("[TIMER] enqueueSaveTask({d},{d}): {d}us\n", .{ origin.x, origin.z, elapsed_us });
    }

    /// 入队异步区块加载请求
    pub fn enqueueLoadTask(self: *BlockWorld, origin: Vec3i) !void {
        if (self.chunks.contains(origin)) return;
        {
            self.pending_loads_mutex.lock();
            defer self.pending_loads_mutex.unlock();
            // 如果已有相同 origin 的 load 在排队的，跳过
            if (self.io_active_loads.contains(origin)) return;
            try self.pending_loads.append(self.allocator, origin);
            try self.io_active_loads.put(origin, {});
        }
        _ = self.pending_io_count.fetchAdd(1, .release);
    }

    /// 处理已完成的 IO 加载任务（主线程每帧调用）
    pub fn processCompletedLoads(self: *BlockWorld) !void {
        self.completed_loads_mutex.lock();
        defer self.completed_loads_mutex.unlock();

        // 先收集所有需要 mesh 构建的 origin，批量入队（一次锁操作）
        var batch_origins = std.ArrayListUnmanaged(Vec3i){};
        defer batch_origins.deinit(self.allocator);

        for (self.completed_loads.items) |*result| {
            _ = self.io_active_loads.remove(result.origin);
            var meshes = std.AutoHashMap(MaterialIdx, ChunkMesh.ChunkMesh).init(self.allocator);
            try meshes.ensureTotalCapacity(@intCast(MAX_MATERIALS));
            {
                self.chunk_mutex.lock();
                defer self.chunk_mutex.unlock();
                try self.chunks.put(result.origin, .{
                    .chunk = result.chunk,
                    .meshes = meshes,
                    .dirty = false,
                });
            }
            try batch_origins.append(self.allocator, result.origin);
            // 也触发邻居 mesh 重建
            for (NEIGHBOR_OFFSETS[1..]) |noff| {
                const nb_origin = Vec3i.new(
                    result.origin.x + noff.x * CHUNK_WIDTH_I32,
                    0,
                    result.origin.z + noff.z * CHUNK_WIDTH_I32,
                );
                if (self.chunks.contains(nb_origin)) {
                    try batch_origins.append(self.allocator, nb_origin);
                }
            }
        }

        if (batch_origins.items.len > 0) {
            try self.enqueueMeshBuildBatch(batch_origins.items);
        }

        self.completed_loads.clearRetainingCapacity();
    }

    /// 释放 io worker 已完成的任务内存
    pub fn processCompletedSaves(self: *BlockWorld) void {
        self.completed_saves_mutex.lock();
        defer self.completed_saves_mutex.unlock();
        for (self.completed_saves.items) |*t| {
            self.allocator.free(t.palette_json);
            self.allocator.free(t.index_data);
        }
        self.completed_saves.clearRetainingCapacity();
    }

    /// 等待所有待处理 IO 任务（load + save）完成
    pub fn flushIO(self: *BlockWorld) void {
        while (self.pending_io_count.load(.acquire) > 0) {
            std.Thread.yield() catch {};
        }
        self.processCompletedSaves();
    }

    /// 当前待处理的 IO 任务数量
    pub fn pendingIOCount(self: *BlockWorld) usize {
        return self.pending_io_count.load(.acquire);
    }

    pub fn loadChunk(self: *BlockWorld, origin: Vec3i) !void {
        try self.enqueueLoadTask(origin);
    }

    pub fn unloadChunk(self: *BlockWorld, origin: Vec3i) void {
        const start_ns = std.time.nanoTimestamp();

        self.chunk_mutex.lock();
        defer self.chunk_mutex.unlock();
        const c_mutex_ns = std.time.nanoTimestamp();

        if (self.chunks.getPtr(origin)) |loaded| {
            if (loaded.build_lock.load(.acquire)) return;

            for (NEIGHBOR_OFFSETS[1..]) |noff| {
                const nb_origin = Vec3i.new(
                    origin.x + noff.x * CHUNK_WIDTH_I32,
                    0,
                    origin.z + noff.z * CHUNK_WIDTH_I32,
                );
                if (self.chunks.getPtr(nb_origin)) |nb_loaded| {
                    if (nb_loaded.build_lock.load(.acquire)) return;
                }
            }

            const t1_ns = std.time.nanoTimestamp();

            // 脏数据入队异步保存（不阻塞主线程）
            if (loaded.dirty) {
                self.enqueueSaveTask(origin, loaded.chunk) catch {};
            }

            const t2_ns = std.time.nanoTimestamp();

            // 释放所有 mesh
            {
                var mesh_it = loaded.meshes.iterator();
                while (mesh_it.next()) |entry| {
                    entry.value_ptr.deinit(self.allocator);
                    self.material_registry.releaseById(entry.key_ptr.*);
                }
            }
            loaded.meshes.deinit();

            const t3_ns = std.time.nanoTimestamp();

            loaded.chunk.deinit();
            self.allocator.destroy(loaded.chunk);
            _ = self.chunks.remove(origin);

            const t4_ns = std.time.nanoTimestamp();

            self.material_registry.cleanupUnused();

            const elapsed_us = @as(u64, @intCast(@max(@as(i64, 0), std.time.nanoTimestamp() - start_ns))) / 1000;
            if (elapsed_us > 100000) {
                const cmtx_us = @as(u64, @intCast(@max(@as(i64, 0), c_mutex_ns - start_ns))) / 1000;
                const lookup_us = @as(u64, @intCast(@max(@as(i64, 0), t1_ns - c_mutex_ns))) / 1000;
                const save_us = @as(u64, @intCast(@max(@as(i64, 0), t2_ns - t1_ns))) / 1000;
                const mesh_us = @as(u64, @intCast(@max(@as(i64, 0), t3_ns - t2_ns))) / 1000;
                const chunk_us = @as(u64, @intCast(@max(@as(i64, 0), t4_ns - t3_ns))) / 1000;
                const reg_us = @as(u64, @intCast(@max(@as(i64, 0), std.time.nanoTimestamp() - t4_ns))) / 1000;
                std.debug.print("[TIMER] unloadChunk({d},{d}): total={d}us cmtx={d}us look={d}us save={d}us mesh={d}us chunk={d}us reg={d}us\n", .{ origin.x, origin.z, elapsed_us, cmtx_us, lookup_us, save_us, mesh_us, chunk_us, reg_us });
            }
        } else {
            // chunk 不存在，只执行 cleanupUnused
            self.material_registry.cleanupUnused();
        }
    }

    pub fn setBlock(self: *BlockWorld, world_pos: Vec3i, block_state: BlockState) !void {
        const origin = chunkOrigin(world_pos.x, world_pos.z);
        if (self.chunks.getPtr(origin)) |loaded| {
            const lx: u32 = @intCast(world_pos.x - origin.x);
            const ly: u32 = @intCast(world_pos.y - origin.y);
            const lz: u32 = @intCast(world_pos.z - origin.z);
            loaded.chunk.setBlock(lx, ly, lz, block_state);
            loaded.dirty = true;
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
        self.stale_targets.clearRetainingCapacity();
        self.last_exact_targets.clearRetainingCapacity();
    }

    /// 物理更新：每帧处理实体的垂直移动、水平移动、潜行边缘保护、碰撞解算以及实体间排斥。
    pub fn updatePhysics(self: *BlockWorld, registry: *ECS.Registry, dt: f32) void {
        // ============================================================
        // 第一阶段：遍历所有物理实体，更新速度与位置
        // ============================================================
        var view = registry.view(.{
            Comps.Position,   Comps.Velocity,     Comps.Collider,
            Comps.MoveSpeed,  Comps.JumpVelocity, Comps.OnGround,
            Comps.MoveIntent,
        }, .{});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const pos = view.get(Comps.Position, entity);
            const vel = view.get(Comps.Velocity, entity);
            const aabb = view.get(Comps.Collider, entity);
            const move_speed = view.get(Comps.MoveSpeed, entity);
            const on_ground = view.get(Comps.OnGround, entity);
            var intent = view.get(Comps.MoveIntent, entity);

            // 飞行实体：跳过重力/加速/潜行，仅保留碰撞解算
            const flying = registry.has(Comps.Flying, entity);

            // ---- 水平移动：提取当前速度与输入方向的 XZ 分量 ----
            var h_vel = Vec3.new(vel.vec.x, 0, vel.vec.z);
            var move_dir = Vec3.new(intent.direction.x, 0, intent.direction.z);

            if (!flying) {
                // 水中检测与流体阻力
                const in_swimmable = self.isInSwimmable(pos, aabb);
                const resistance: f32 = blk: {
                    if (!in_swimmable) break :blk 0.0;
                    const mid = pos.vec.add(Vec3.new(0, aabb.height * 0.5, 0));
                    const proto = self.getBlockAt(mid).prototype();
                    break :blk @as(f32, if (proto.is_swimmable) proto.fluid_resistance else 0.0);
                };

                // 重力、移速倍率、最终最大速度与加速度
                const effective_gravity: f32 = if (in_swimmable) FLUID_GRAVITY else GRAVITY;
                const speed_multiplier: f32 = if (intent.sprint) SPRINT_MULTIPLIER else if (intent.sneak) SNEAK_MULTIPLIER else 1.0;
                const max_speed = move_speed.value * (1.0 - resistance) * speed_multiplier;
                const acceleration = ACCELERATION * (1.0 - resistance);

                // ---- 垂直移动：水中上浮/下潜，或陆地重力+跳跃 ----
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
                        vel.vec.y = intent.jump_power;
                        on_ground.value = false;
                    }
                }

                // ---- 潜行边缘保护：阻止从方块边缘坠落 ----
                var sneak_blocked = false;
                if (intent.sneak and move_dir.len2() > 0.001 and on_ground.value) {
                    // 边缘保留宽度：AABB 底面积仅剩此比例接触方块时阻止移动
                    const edge_margin = aabb.width * 0.1;
                    const intent_len = move_dir.len();
                    var edge_blocked = false;

                    // 逐轴独立检测：沿移动方向探测 edge_margin，检查该处 AABB 底部是否仍有方块
                    if (move_dir.x != 0) {
                        const s: f32 = if (move_dir.x > 0) 1.0 else -1.0;
                        if (!self.hasGroundUnder(pos.vec.add(Vec3.new(edge_margin * s, 0, 0)), aabb)) {
                            h_vel.x = 0;
                            move_dir.x = 0;
                            edge_blocked = true;
                        }
                    }
                    if (move_dir.z != 0) {
                        const s: f32 = if (move_dir.z > 0) 1.0 else -1.0;
                        if (!self.hasGroundUnder(pos.vec.add(Vec3.new(0, 0, edge_margin * s)), aabb)) {
                            h_vel.z = 0;
                            move_dir.z = 0;
                            edge_blocked = true;
                        }
                    }

                    // 有轴向被边缘阻挡时，按剩余意图比例缩放速度，实现贴墙滑动
                    if (edge_blocked) {
                        sneak_blocked = true;
                        const remaining_len = move_dir.len();
                        if (remaining_len > 0.001) {
                            h_vel = h_vel.scale(remaining_len / intent_len);
                        }
                    }
                }

                // ---- 水平加速/摩擦 ----
                if (move_dir.len2() > 0.001) {
                    // 潜行阻挡时不归一化 wish_dir，保留分量比例以模拟贴（空气）墙滑动
                    const wish_dir = if (sneak_blocked) move_dir else move_dir.norm();
                    h_vel = h_vel.add(wish_dir.scale(acceleration * dt));
                    const h_speed = h_vel.len();
                    if (h_speed > max_speed) h_vel = h_vel.scale(max_speed / h_speed);
                } else {
                    if (on_ground.value) {
                        // 地面摩擦力：每帧乘系数减速
                        h_vel = h_vel.scale(GROUND_FRICTION);
                    } else {
                        // 空气阻力：每秒扣除固定量
                        const h_speed = h_vel.len();
                        if (h_speed > 0.001) {
                            const reduction = AIR_FRICTION * dt;
                            const new_speed = @max(h_speed - reduction, 0);
                            h_vel = h_vel.scale(new_speed / h_speed);
                        }
                    }
                }
            } else {
                // 飞行移动：lerp 方式，最大飞速 = 走速 × 飞速倍率
                const fly_top_speed: f32 = move_speed.value * FLY_SPEED_MULTIPLIER *
                    (if (intent.sprint) SPRINT_MULTIPLIER else 1.0);
                const fly_response: f32 = 8.0;
                const factor: f32 = 1.0 - std.math.exp(-fly_response * dt);

                if (move_dir.len2() > 0.001) {
                    const target = move_dir.norm().scale(fly_top_speed);
                    h_vel = Vec3.lerp(h_vel, target, factor);
                } else {
                    h_vel = Vec3.lerp(h_vel, Vec3.zero, factor);
                }

                const v_target = intent.direction.y * fly_top_speed;
                vel.vec.y += (v_target - vel.vec.y) * factor;
            }
            vel.vec.x = h_vel.x;
            vel.vec.z = h_vel.z;

            // 旁观者模式：绕过碰撞解算，直接应用位移
            if (flying) {
                if (registry.tryGet(Comps.Player, entity)) |player| {
                    if (player.mode == .spectator) {
                        pos.vec.x += vel.vec.x * dt;
                        pos.vec.y += vel.vec.y * dt;
                        pos.vec.z += vel.vec.z * dt;
                        intent.jump = false;
                        continue;
                    }
                }
            }

            // ---- 碰撞解算：将速度转为位移，交 moveEntity 处理方块碰撞与 on_ground 更新 ----
            const dx = vel.vec.x * dt;
            const dy = vel.vec.y * dt;
            const dz = vel.vec.z * dt;
            self.moveEntity(pos, vel, aabb, on_ground, &self.collision_list, dx, dy, dz);

            intent.jump = false;
        }

        // ============================================================
        // 第二阶段：实体间碰撞排斥
        // 对发生 AABB 重叠的实体对施加水平排斥力（不修改位置，仅调整速度）
        // ============================================================
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
                    // 跳过自身以及已处理过的实体对
                    if (@as(u32, @bitCast(entity_b)) <= @as(u32, @bitCast(entity_a))) continue;
                    const pos_b = push_view.get(Comps.Position, entity_b);
                    const col_b = push_view.get(Comps.Collider, entity_b);
                    const vel_b = push_view.get(Comps.Velocity, entity_b);
                    const box_b = getEntityAABB(pos_b.vec, col_b);

                    // AABB 相交检测
                    if (box_a.min_x < box_b.max_x and box_a.max_x > box_b.min_x and
                        box_a.min_y < box_b.max_y and box_a.max_y > box_b.min_y and
                        box_a.min_z < box_b.max_z and box_a.max_z > box_b.min_z)
                    {
                        // 水平排斥方向（A → B）
                        const dx = pos_b.vec.x - pos_a.vec.x;
                        const dz = pos_b.vec.z - pos_a.vec.z;
                        const dist = @max(@sqrt(dx * dx + dz * dz), 0.001);
                        const nx = dx / dist;
                        const nz = dz / dist;

                        // 排斥力大小与重叠深度成正比
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

    /// 每帧更新 AI 目标选择。
    /// 玩家在探测范围内 → 目标设为玩家位置（脚底）。
    /// player_pos 来自 ECS 的 Player.Position（脚底），不是摄像机（眼高）。
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

    /// 每帧更新 AI 行为：管理 A* 寻路状态、跟随路径、触发跳跃。
    ///
    /// 流程：
    ///   1. 轮询异步 A* worker 的完成结果
    ///   2. A* 完成后构建路径，替换到 agent.path
    ///   3. 有路径 → 沿 waypoint 移动；路径过时 → 标记重算
    ///   4. 无路径且无进行中 A* → 发起新寻路
    ///   5. 路径阻塞/卡住超时 → 清除路径
    ///   6. 前方有方块 → 自动跳跃
    pub fn updateAI(self: *BlockWorld, registry: *ECS.Registry, dt: f32) void {
        const STUCK_TIMEOUT: f32 = 4.0;

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
            const entity_height_blocks: i32 = @intFromFloat(@ceil(collider.height));
            const max_step_up: i32 = @intFromFloat(@floor((info.jump_vel * info.jump_vel) / (2.0 * GRAVITY)));
            var intent = view.get(Comps.MoveIntent, entity);
            const on_ground = view.get(Comps.OnGround, entity);
            var cooldown = view.get(Comps.AttackCooldown, entity);

            const dx = agent.target.x - pos.vec.x;
            const dy = agent.target.y - pos.vec.y;
            const dz = agent.target.z - pos.vec.z;
            const dist_3d = @sqrt(dx * dx + dy * dy + dz * dz);

            intent.jump = false;
            intent.direction = Vec3.zero;
            var need_repath = false;

            // 水中自动上浮保持在水面，超时翻倍（游泳慢）
            const in_water = self.isInSwimmable(pos, collider);

            // 攻击冷却
            if (cooldown.timer > 0) {
                cooldown.timer -= dt;
            }

            if (dist_3d < info.attack_range and cooldown.timer <= 0) {
                cooldown.timer = cooldown.interval;
            }

            // 轮询异步 A* 完成结果（worker 返回完整的 AStarState）
            {
                var completed_buf: [16]AStarTask = undefined;
                var completed_count: usize = 0;
                {
                    self.astar_completed_mutex.lock();
                    defer self.astar_completed_mutex.unlock();
                    var i: usize = self.astar_completed.items.len;
                    while (i > 0 and completed_count < completed_buf.len) {
                        i -= 1;
                        completed_buf[completed_count] = self.astar_completed.swapRemove(i);
                        completed_count += 1;
                    }
                }
                for (completed_buf[0..completed_count]) |*entry| {
                    const e = entry.entity;
                    var astar = entry.state;
                    _ = self.astar_active.remove(e);
                    if (astar.result == .found) {
                        if (Pathfind.buildAStarPath(&astar)) |new_path| {
                            if (registry.tryGet(Comps.AIAgent, e)) |a| {
                                if (a.path) |*p| p.deinit(self.allocator);
                                a.path = new_path;
                                a.path_index = 0;
                                a.stuck_timer = 0;
                            } else {
                                var p = new_path;
                                p.deinit(self.allocator);
                            }
                        } else |_| {}
                        const stale_key = Pathfind.StaleKey{
                            .pos = astar.end,
                            .height_blocks = astar.entity_height_blocks,
                            .step_up = astar.max_step_up,
                        };
                        if (!astar.exact_match) {
                            if (self.stale_targets.count() >= 64) {
                                var it2 = self.stale_targets.keyIterator();
                                if (it2.next()) |old_key| _ = self.stale_targets.remove(old_key.*);
                            }
                            if (self.stale_targets.getOrPut(stale_key)) |se| {
                                if (se.found_existing) se.value_ptr.* += 1 else se.value_ptr.* = 1;
                            } else |_| {}
                        } else {
                            _ = self.stale_targets.remove(stale_key);
                            self.last_exact_targets.put(e, astar.end) catch {};
                        }
                        if (registry.tryGet(Comps.AIAgent, e)) |a| {
                            a.astar_cooldown = 1.0;
                        }
                    } else if (astar.result == .failed) {
                        if (registry.tryGet(Comps.AIAgent, e)) |a| {
                            a.astar_cooldown = 1.0;
                        }
                    }
                    Pathfind.deinitAStar(&astar);
                }
            }

            // 路径跟随：沿 waypoint 逐格移动
            if (agent.path) |*path| {
                var blocked = false;
                // 检查当前 waypoint 是否仍可达（地面是否被改变）
                if (agent.path_index < path.items.len) {
                    const wp = path.items[agent.path_index];
                    const wpx = @as(i32, @intFromFloat(@floor(wp.x)));
                    const wpz = @as(i32, @intFromFloat(@floor(wp.z)));
                    const wpy = @as(i32, @intFromFloat(@round(wp.y)));
                    const ground = Pathfind.findGroundBelow(self, wpx, wpz, wpy - 1, entity_height_blocks);
                    if (ground == null or ground.? != wpy) {
                        blocked = true;
                    }
                }

                // 路径超时计时：到达 waypoint 时归零，超时则放弃当前路径
                agent.stuck_timer += dt;

                if (blocked or agent.stuck_timer > if (in_water) STUCK_TIMEOUT * 2.0 else STUCK_TIMEOUT) {
                    path.deinit(self.allocator);
                    agent.path = null;
                } else if (agent.path_index < path.items.len) {
                    const waypoint = path.items[agent.path_index];
                    const wdx = waypoint.x - pos.vec.x;
                    const wdz = waypoint.z - pos.vec.z;
                    const wdy = waypoint.y - pos.vec.y;
                    const wdist = @sqrt(wdx * wdx + wdz * wdz + wdy * wdy);

                    if (wdist < 0.5) {
                        agent.path_index += 1;
                        agent.stuck_timer = 0; // 到达 waypoint，重置超时计时
                    } else {
                        // 朝 waypoint 移动（仅水平方向，垂直由重力/跳跃处理）
                        const hdist = @sqrt(wdx * wdx + wdz * wdz);
                        if (hdist > 0.01) {
                            intent.direction = Vec3.new(wdx / hdist, 0, wdz / hdist);
                        }
                    }

                    // 距离自适应重算：近处微动就重算，远处不轻易浪费长搜索
                    {
                        const repath_dist: f32 = blk: {
                            if (dist_3d < 10.0) break :blk 1.0;
                            if (dist_3d < 20.0) break :blk 3.0;
                            break :blk 8.0;
                        };
                        const final_wp = path.items[path.items.len - 1];
                        const fdx = agent.target.x - final_wp.x;
                        const fdz = agent.target.z - final_wp.z;
                        if (@sqrt(fdx * fdx + fdz * fdz) > repath_dist) {
                            need_repath = true;
                        }
                    }
                } else {
                    path.deinit(self.allocator);
                    agent.path = null;
                }
            }

            // 发起新寻路：无路径（或路径过时），无进行中 A*，冷却已过且目标未缓存
            if ((agent.path == null or need_repath) and !self.astar_active.contains(entity)) {
                agent.astar_cooldown -= dt;
                if (agent.astar_cooldown <= 0) {
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
                        const cached = self.last_exact_targets.get(entity);
                        if (cached == null or !cached.?.eql(end_grid)) {
                            const stale_key = Pathfind.StaleKey{
                                .pos = end_grid,
                                .height_blocks = entity_height_blocks,
                                .step_up = max_step_up,
                            };
                            const stale_hits = if (self.stale_targets.get(stale_key)) |c| c else @as(u32, 0);
                            if (stale_hits < 3) {
                                const cur_max_steps: u32 = if (stale_hits >= 2) @as(u32, 200) else @as(u32, 3000);
                                var astar = Pathfind.initAStar(self.allocator, self, pos.vec, agent.target, entity_height_blocks, max_step_up) catch continue;
                                astar.max_steps = cur_max_steps;
                                // 防泄漏 defer：任何失败路径释放 astar
                                var owned: bool = false;
                                defer if (!owned) Pathfind.deinitAStar(&astar);
                                self.astar_active.put(entity, {}) catch continue;
                                {
                                    self.astar_pending_mutex.lock();
                                    defer self.astar_pending_mutex.unlock();
                                    self.astar_pending.append(self.allocator, .{ .entity = entity, .state = astar }) catch {
                                        _ = self.astar_active.remove(entity);
                                        continue;
                                    };
                                }
                                owned = true; // 所有权转移给 worker
                            }
                        }
                    }
                } else if (agent.path == null and dist_3d < 10.0) {
                    // 贪心桥接：A* 冷却中，直走方向临时填补
                    const d = @sqrt(dx * dx + dz * dz);
                    if (d > 0.01) {
                        intent.direction = Vec3.new(dx / d, 0, dz / d);
                    }
                }
            }

            // 跳跃检测：用 findGroundBelow 精确定位落点并验证实体身高空间
            if (intent.direction.x != 0 or intent.direction.z != 0) {
                if (on_ground.value) {
                    const ahead = pos.vec.add(intent.direction.norm().scale(0.55));
                    const ax: i32 = @intFromFloat(@floor(ahead.x));
                    const az: i32 = @intFromFloat(@floor(ahead.z));
                    const from_y: i32 = @as(i32, @intFromFloat(@floor(ahead.y))) + max_step_up;

                    // findGroundBelow 从扫描起点向下找固体，同时验证 entity_height_blocks 格空气
                    const landing = Pathfind.findGroundBelow(self, ax, az, from_y, entity_height_blocks);
                    if (landing) |land_y| {
                        const height_diff = land_y - @as(i32, @intFromFloat(@floor(pos.vec.y)));
                        // 向上跳且在能力范围内
                        if (height_diff > 0 and height_diff <= max_step_up) {
                            // 头顶无阻挡（用实体身高验证当前站立位置有空间起跳）
                            const head_y: i32 = @as(i32, @intFromFloat(@floor(pos.vec.y))) + entity_height_blocks;
                            const head_check = Vec3.new(pos.vec.x, @as(f32, @floatFromInt(head_y)) + 0.5, pos.vec.z);
                            if (!self.getBlockAt(head_check).prototype().is_solid) {
                                // waypoint 引导的精确跳跃力度
                                var jump_power: f32 = info.jump_vel;
                                if (agent.path) |p| {
                                    if (agent.path_index < p.items.len) {
                                        const wp = p.items[agent.path_index];
                                        const needed = wp.y - pos.vec.y;
                                        if (needed > 0.5 and needed <= @as(f32, @floatFromInt(max_step_up)) + 0.5) {
                                            jump_power = @sqrt(2.0 * GRAVITY * (needed + 0.5));
                                            jump_power = @min(jump_power, info.jump_vel);
                                        }
                                    }
                                }
                                intent.jump = true;
                                intent.jump_power = jump_power;
                            }
                        }
                    }
                }
            }

            // 水中自动上浮：游泳时保持在水面（放末尾，不被路径跟随覆盖 y 分量）
            if (in_water) {
                intent.direction.y = 1.0;
            }
        }
    }

    /// 清理实体的寻路状态和路径内存。在销毁实体前调用。
    pub fn cleanupEntity(self: *BlockWorld, registry: *ECS.Registry, entity: ECS.Entity) void {
        _ = self.astar_active.remove(entity);
        _ = self.last_exact_targets.remove(entity);
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

    /// 检查实体身体任意部位是否在水中，用于游泳判定
    fn isInSwimmable(self: *BlockWorld, pos: *Comps.Position, collider: *Comps.Collider) bool {
        const points = [_]Vec3{
            pos.vec.add(Vec3.new(0, 0.3, 0)),
            pos.vec.add(Vec3.new(0, collider.height * 0.5, 0)),
            pos.vec.add(Vec3.new(0, collider.height - 0.3, 0)),
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
        if (local_x >= 0 and local_x < CHUNK_WIDTH and
            local_y >= 0 and local_y < CHUNK_HEIGHT and
            local_z >= 0 and local_z < CHUNK_WIDTH)
        {
            return chunk.getBlockId(@intCast(local_x), @intCast(local_y), @intCast(local_z));
        }
        return .fromName("air");
    }

    pub fn getBlockAt(self: *BlockWorld, world_pos: Vec3) BlockId {
        const x = @as(i32, @intFromFloat(@floor(world_pos.x)));
        const y = @as(i32, @intFromFloat(@floor(world_pos.y)));
        const z = @as(i32, @intFromFloat(@floor(world_pos.z)));

        const origin = chunkOrigin(x, z);
        const loaded = self.chunks.getPtr(origin) orelse return .fromName("air");
        return getBlockAtFromChunk(loaded.chunk, origin, x, y, z);
    }

    /// 整数坐标版，跳过 Vec3 构造（热点路径优化）
    fn peekBlockAt(self: *BlockWorld, x: i32, y: i32, z: i32) BlockId {
        const origin = chunkOrigin(x, z);
        const loaded = self.chunks.getPtr(origin) orelse return .fromName("air");
        return getBlockAtFromChunk(loaded.chunk, origin, x, y, z);
    }

    /// 判断指定整数坐标是否为固体方块
    pub fn isSolidAt(self: *BlockWorld, x: i32, y: i32, z: i32) bool {
        return self.peekBlockAt(x, y, z).prototype().is_solid;
    }

    fn hasGroundUnder(self: *BlockWorld, pos: Vec3, collider: *Comps.Collider) bool {
        const box = getEntityAABB(pos, collider);
        const by = @as(i32, @intFromFloat(@floor(pos.y))) - 1;
        const min_bx = @as(i32, @intFromFloat(@floor(box.min_x)));
        const max_bx = @as(i32, @intFromFloat(@floor(box.max_x)));
        const min_bz = @as(i32, @intFromFloat(@floor(box.min_z)));
        const max_bz = @as(i32, @intFromFloat(@floor(box.max_z)));
        var bx: i32 = min_bx;
        while (bx <= max_bx) : (bx += 1) {
            var bz: i32 = min_bz;
            while (bz <= max_bz) : (bz += 1) {
                if (self.isSolidAt(bx, by, bz)) return true;
            }
        }
        return false;
    }

    /// 判断指定整数坐标是否为可游泳方块（水）
    pub fn isSwimmableBlock(self: *BlockWorld, x: i32, y: i32, z: i32) bool {
        return self.peekBlockAt(x, y, z).prototype().is_swimmable;
    }

    /// 一次方块查询同时判断实心或可游泳，避免双次 peekBlockAt（热点优化）
    pub fn isSolidOrSwimmable(self: *BlockWorld, x: i32, y: i32, z: i32) bool {
        const proto = self.peekBlockAt(x, y, z).prototype();
        return proto.is_solid or proto.is_swimmable;
    }
};

/// 异步 mesh 生成 worker：从 pending 取 chunk，构建 mesh，推入 completed
fn meshWorkerFn(world: *BlockWorld) void {
    const alloc = world.worker_gpa.allocator();
    while (world.running.load(.acquire)) {
        // 取任务：持 mesh_mutex 操作 pending 队列
        var origin: ?Vec3i = null;
        {
            world.mesh_mutex.lock();
            defer world.mesh_mutex.unlock();
            var iter = world.pending.keyIterator();
            if (iter.next()) |key_ptr| {
                origin = key_ptr.*;
            }
        }

        var loaded_ptr_chunks: [NEIGHBOR_OFFSETS.len]?*LoadedChunk = [_]?*LoadedChunk{null} ** NEIGHBOR_OFFSETS.len;
        if (origin) |o| {
            // 持 chunk_mutex（读共享）访问 chunks
            {
                world.chunk_mutex.lockShared();
                defer world.chunk_mutex.unlockShared();
                loaded_ptr_chunks[0] = world.chunks.getPtr(o);
                if (loaded_ptr_chunks[0] != null) {
                    loaded_ptr_chunks[0].?.build_lock.store(true, .release);
                    for (NEIGHBOR_OFFSETS[1..], 1..) |noff, i| {
                        const nb = Vec3i.new(o.x + noff.x * CHUNK_WIDTH_I32, 0, o.z + noff.z * CHUNK_WIDTH_I32);
                        loaded_ptr_chunks[i] = world.chunks.getPtr(nb);
                        if (loaded_ptr_chunks[i]) |l| {
                            l.build_lock.store(true, .release);
                        }
                    }
                }
            }
            if (loaded_ptr_chunks[0] == null) {
                // chunk 未加载 → 移除 pending，loadChunk 完成后 enqueueMeshBuild 会重新提交
                world.mesh_mutex.lock();
                defer world.mesh_mutex.unlock();
                _ = world.pending.remove(o);
                std.Thread.yield() catch {};
                continue;
            }
            // chunk 可用 → 移除 pending 条目（防重复构建）
            {
                world.mesh_mutex.lock();
                defer world.mesh_mutex.unlock();
                _ = world.pending.remove(o);
            }
        }

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
                world.completed.append(world.allocator, result) catch {
                    result.deinit();
                };
                world.completed_mutex.unlock();
            }
        } else {
            std.Thread.sleep(3_000_000); // 空闲休眠 3ms，避免 yield 空转
            continue;
        }
        // 完成工作后短暂让步，让主线程有机会处理 completed
        std.Thread.yield() catch {};
    }
}

/// 异步 A* worker：持 active 状态持续步进，完成推送 completed。
/// 不反复推回 pending——同一实体直到 A* 完成才释放 CPU。
fn astarWorkerFn(world: *BlockWorld) void {
    var active: ?AStarTask = null;
    while (world.astar_running.load(.acquire)) {
        if (active == null) {
            world.astar_pending_mutex.lock();
            defer world.astar_pending_mutex.unlock();
            if (world.astar_pending.items.len > 0) {
                active = world.astar_pending.swapRemove(0);
            }
        }
        if (active) |*entry| {
            var just_finished: bool = false;
            {
                // 读共享 chunk 锁（多 reader 并发），state 由 worker 独占无需锁
                world.chunk_mutex.lockShared();
                defer world.chunk_mutex.unlockShared();
                if (entry.state.result == .pending) {
                    Pathfind.stepAStar(&entry.state, world, 500);
                }
                if (entry.state.result != .pending) {
                    just_finished = true;
                }
            }
            if (just_finished) {
                world.astar_completed_mutex.lock();
                defer world.astar_completed_mutex.unlock();
                world.astar_completed.append(world.allocator, .{ .entity = entry.entity, .state = entry.state }) catch {};
                active = null;
            }
        }
        if (active == null) {
            std.Thread.sleep(3_000_000); // 空闲休眠 3ms
        } else {
            std.Thread.yield() catch {};
        }
    }
    if (active) |*t| Pathfind.deinitAStar(&t.state);
}

/// 异步 IO worker：将 pending_saves 中的任务写入 SQLite + 处理 pending_loads
fn ioWorkerFn(world: *BlockWorld) void {
    // worker 线程独享的 SQLite 连接池（共享 map 非线程安全，所以这里自己开连接）
    var region_caches = std.AutoHashMap(i64, fr.Session).init(std.heap.page_allocator);
    defer {
        var it = region_caches.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        region_caches.deinit();
    }
    const pa = std.heap.page_allocator;

    // 确保 region 目录存在（fridge/SQLite 不会自动创建目录）
    {
        if (std.fmt.allocPrint(pa, "{s}/regions", .{world.save_dir})) |reg_dir| {
            defer pa.free(reg_dir);
            std.fs.cwd().makePath(reg_dir) catch {};
        } else |_| {}
    }

    while (world.save_running.load(.acquire)) {
        // 优先处理保存任务
        var save_task: ?SaveTask = null;
        {
            world.pending_saves_mutex.lock();
            defer world.pending_saves_mutex.unlock();
            if (world.pending_saves.items.len > 0) {
                save_task = world.pending_saves.swapRemove(0);
            }
        }

        if (save_task) |t| {
            // 原有保存逻辑（略作调整用 pa 替代 world.allocator）
            const cx = @divExact(t.origin.x, 16);
            const cz = @divExact(t.origin.z, 16);
            const rx = @divFloor(cx, 32);
            const rz = @divFloor(cz, 32);
            const key: i64 = (@as(i64, @intCast(rx)) << 32) | @as(i64, @intCast(rz)) & 0xFFFFFFFF;

            const db = blk: {
                if (region_caches.getPtr(key)) |sess| break :blk sess;
                var db_path_buf: [512]u8 = undefined;
                const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/regions/r_{d}_{d}.db", .{ world.save_dir, rx, rz }) catch {
                    _ = world.pending_io_count.fetchSub(1, .release);
                    continue;
                };
                const db_path_z = pa.dupeZ(u8, db_path) catch {
                    _ = world.pending_io_count.fetchSub(1, .release);
                    continue;
                };
                defer pa.free(db_path_z);
                var sess = fr.Session.open(fr.SQLite3, pa, .{ .filename = db_path_z }) catch {
                    _ = world.pending_io_count.fetchSub(1, .release);
                    continue;
                };
                sess.conn.execAll("CREATE TABLE IF NOT EXISTS \"Chunks\" (x INTEGER NOT NULL,z INTEGER NOT NULL,palette TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY (x, z)); PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;") catch {};
                region_caches.put(key, sess) catch {
                    _ = world.pending_io_count.fetchSub(1, .release);
                    continue;
                };
                break :blk region_caches.getPtr(key).?;
            };
            {
                var stmt = db.conn.prepare("INSERT OR REPLACE INTO Chunks (x,z,palette,data) VALUES (?,?,?,?)", &.{}) catch {
                    std.debug.print("IO save failed\n", .{});
                    _ = world.pending_io_count.fetchSub(1, .release);
                    continue;
                };
                defer stmt.deinit();
                _ = stmt.bind(0, fr.Value{ .int = cx }) catch {};
                _ = stmt.bind(1, fr.Value{ .int = cz }) catch {};
                _ = stmt.bind(2, fr.Value{ .string = t.palette_json }) catch {};
                const bpi = if (t.palette_count <= 1) 1 else @as(u32, @intCast(std.math.log2_int(usize, t.palette_count - 1) + 1));
                const data_size = (CHUNK_BLOCKS * bpi + 7) / 8;
                _ = stmt.bind(3, fr.Value{ .blob = t.index_data[0..data_size] }) catch {};
                _ = stmt.exec() catch {};
            }
            world.completed_saves_mutex.lock();
            world.completed_saves.append(world.allocator, t) catch {};
            world.completed_saves_mutex.unlock();
            _ = world.pending_io_count.fetchSub(1, .release);
            continue;
        }

        // 没有保存任务，尝试加载任务
        var origin: ?Vec3i = null;
        {
            world.pending_loads_mutex.lock();
            defer world.pending_loads_mutex.unlock();
            if (world.pending_loads.items.len > 0) {
                origin = world.pending_loads.swapRemove(0);
            }
        }

        if (origin) |o| {
            const cx = @divExact(o.x, 16);
            const cz = @divExact(o.z, 16);
            const rx = @divFloor(cx, 32);
            const rz = @divFloor(cz, 32);
            const key: i64 = (@as(i64, @intCast(rx)) << 32) | @as(i64, @intCast(rz)) & 0xFFFFFFFF;

            // 打开或获取 region 数据库连接
            const db = blk: {
                var load_path_buf: [512]u8 = undefined;
                const load_path = std.fmt.bufPrint(&load_path_buf, "{s}/regions/r_{d}_{d}.db", .{ world.save_dir, rx, rz }) catch {
                    _ = world.pending_io_count.fetchSub(1, .release);
                    continue;
                };
                const load_path_z = pa.dupeZ(u8, load_path) catch {
                    _ = world.pending_io_count.fetchSub(1, .release);
                    continue;
                };
                defer pa.free(load_path_z);
                if (region_caches.getPtr(key)) |sess| {
                    break :blk sess;
                } else {
                    var sess = fr.Session.open(fr.SQLite3, pa, .{ .filename = load_path_z }) catch {
                        _ = world.pending_io_count.fetchSub(1, .release);
                        continue;
                    };
                    sess.conn.execAll("CREATE TABLE IF NOT EXISTS \"Chunks\" (x INTEGER NOT NULL,z INTEGER NOT NULL,palette TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY (x, z)); PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;") catch {};
                    region_caches.put(key, sess) catch {
                        _ = world.pending_io_count.fetchSub(1, .release);
                        continue;
                    };
                    break :blk region_caches.getPtr(key).?;
                }
            };

            // 尝试从 SQLite 加载
            var stmt = db.conn.prepare("SELECT palette, data FROM Chunks WHERE x=? AND z=?", &.{}) catch {
                _ = world.pending_io_count.fetchSub(1, .release);
                continue;
            };
            defer stmt.deinit();
            _ = stmt.bind(0, fr.Value{ .int = cx }) catch {};
            _ = stmt.bind(1, fr.Value{ .int = cz }) catch {};
            const found = stmt.step() catch false;

            // 分配 Chunk
            const chunk = world.allocator.create(Chunk) catch {
                _ = world.pending_io_count.fetchSub(1, .release);
                continue;
            };
            errdefer world.allocator.destroy(chunk);

            if (found) {
                // 从存档加载
                const col0 = stmt.column(0) catch {
                    _ = world.pending_io_count.fetchSub(1, .release);
                    continue;
                };
                const src = col0.string;
                // 解析 palette JSON
                var palette_names = std.ArrayListUnmanaged([]const u8){};
                defer palette_names.deinit(pa);
                {
                    var i: usize = 1;
                    while (i < src.len and src[i] != ']') : (i += 1) {
                        if (src[i] == '"') {
                            const start = i + 1;
                            const end = std.mem.indexOfScalarPos(u8, src, start, '"') orelse break;
                            palette_names.append(pa, src[start..end]) catch {
                                _ = world.pending_io_count.fetchSub(1, .release);
                                continue;
                            };
                            i = end;
                        }
                    }
                }
                // 构建运行时 palette
                var runtime_palette = std.ArrayListUnmanaged(BlockState){};
                defer runtime_palette.deinit(pa);
                runtime_palette.ensureTotalCapacity(pa, palette_names.items.len) catch {
                    _ = world.pending_io_count.fetchSub(1, .release);
                    continue;
                };
                for (palette_names.items) |name| {
                    const last_underscore = std.mem.lastIndexOfScalar(u8, name, '_');
                    const block_name = if (last_underscore) |pos| name[0..pos] else name;
                    const facing_int: u3 = if (last_underscore) |pos| blk: {
                        break :blk if (pos + 1 < name.len) @as(u3, @intCast(name[pos + 1] - '0')) else 0;
                    } else 0;
                    const id = registries.block_name_to_id.get(block_name) orelse 0;
                    runtime_palette.appendAssumeCapacity(BlockState{
                        .block_id = BlockId.fromInt(id),
                        .facing = @enumFromInt(facing_int),
                    });
                }
                const final_count = runtime_palette.items.len;
                const bpi = if (final_count <= 1) 1 else @as(u32, @intCast(std.math.log2_int(usize, final_count - 1) + 1));
                chunk.* = Chunk.init(pa);
                chunk.palette.deinit(pa);
                chunk.palette = runtime_palette;
                runtime_palette = .{};
                chunk.index_bits = @as(u5, @intCast(bpi));
                const col1 = stmt.column(1) catch {
                    _ = world.pending_io_count.fetchSub(1, .release);
                    continue;
                };
                const data_bytes = col1.blob;
                const data_size = (CHUNK_BLOCKS * chunk.index_bits + 7) / 8;
                chunk.allocator.free(chunk.index_data);
                chunk.index_data = pa.alloc(u8, data_size) catch {
                    _ = world.pending_io_count.fetchSub(1, .release);
                    continue;
                };
                @memcpy(chunk.index_data, data_bytes[0..@min(data_size, data_bytes.len)]);
                if (data_bytes.len < data_size) @memset(chunk.index_data[data_bytes.len..], 0);
            } else {
                chunk.* = Chunk.init(pa);
                Chunk.generate(o, chunk);
            }

            // 推送 completed_loads
            world.completed_loads_mutex.lock();
            world.completed_loads.append(world.allocator, .{ .origin = o, .chunk = chunk }) catch {};
            world.completed_loads_mutex.unlock();
            _ = world.pending_io_count.fetchSub(1, .release);
        } else {
            std.Thread.sleep(3_000_000); // 空闲休眠 3ms
        }
    }
}
