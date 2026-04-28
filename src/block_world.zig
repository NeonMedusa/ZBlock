const std = @import("std");
const Imports = @import("imports.zig");
const Vec2 = Imports.Vec2;
const Vec3 = Imports.Vec3;
const Vec3i = Imports.Vec3i;
const Vec3u = Imports.Vec3u;
const Vec4 = Imports.Vec4;
const Quat = Imports.Quat;
const Wgpu = Imports.Wgpu;
const Material = Imports.RendCTX.Material;
const MaterialConstants = Imports.RendCTX.MaterialConstants;
const TextureRes = Imports.RendCTX.TextureRes;
const Gctx = Imports.Gctx;
const RenderPipeline = @import("render_pipeline.zig");
const IMG = Imports.zigimg;
const SparseSet = @import("sparse_set.zig").SparseSet;
const Perlin = @import("perlin.zig");
const VertexAttribute = Imports.RendCTX.VertexAttribute;
const ECS = Imports.ECS;
const Comps = Imports.Comps;

/// 方块原型
pub const BlockProtoType = struct {
    name: [:0]const u8, // 方块名
    face_variants: [6]u3 = [1]u3{0} ** 6, // 每个面应用什么材质
    occludes: bool = true, // 新增：是否遮挡相邻方块的面
    opacity: f32 = 1.0, // 不透明度

    is_solid: bool = true, // 是否是固体（不可进入，有完整碰撞箱）
    is_swimmable: bool = false, // 是否可以在其中“游泳”（如水体）
    fluid_resistance: f32 = 0.0, // 游泳时的额外阻力系数（越大移动越慢）

    durability: u32 = 32, // 耐久度
    is_directional: bool = true, // 是否有朝向
};

/// 方块注册表
const block_infos = [_]BlockProtoType{
    .{
        .name = "air",
        .occludes = false,
        .is_solid = false,
    },
    .{
        .name = "grass",
        .face_variants = .{ 0, 1, 2, 2, 2, 2 },
        .is_directional = false,
    },
    .{ .name = "stone" },
    .{ .name = "dirt" },
    .{ .name = "sand" },
    .{
        .name = "water",
        .occludes = false,
        .opacity = 0.5,
        .is_solid = false,
        .is_swimmable = true,
        .fluid_resistance = 0.3,
    },
};

/// 生成“方块名→索引”的枚举
pub const BlockNames = blk: {
    var fields: [block_infos.len]std.builtin.Type.EnumField = undefined;
    for (&fields, block_infos, 0..) |*field, def, i|
        field.* = .{ .name = def.name, .value = i };
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u32,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub const BlockId = enum(u32) {
    _,
    pub fn fromInt(i: anytype) BlockId {
        return @enumFromInt(i);
    }
    pub fn fromName(comptime str: []const u8) BlockId {
        const block_name_val = @field(BlockNames, str);
        return @enumFromInt(@intFromEnum(block_name_val));
    }
    pub fn prototype(self: BlockId) BlockProtoType {
        return block_infos[@intFromEnum(self)];
    }
    pub fn name(self: BlockId) [:0]const u8 {
        return self.prototype().name;
    }
};

pub const CHUNK_SIZE_X: u32 = 128;
pub const CHUNK_SIZE_Y: u32 = 256;
pub const CHUNK_SIZE_Z: u32 = 128;
pub const ChunkSize = Vec3u{
    .x = CHUNK_SIZE_X,
    .y = CHUNK_SIZE_Y,
    .z = CHUNK_SIZE_Z,
};

pub const Chunk = struct {
    blocks: [CHUNK_SIZE_X][CHUNK_SIZE_Y][CHUNK_SIZE_Z]BlockState,

    pub fn generate(world_origin: Vec3i, out_chunk: *Chunk) void {
        const noise_scale: f32 = 0.03;
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

// u3 最多 8 种变体
pub const MAX_VARIANTS = 8;

// 生成“材质名→索引”的枚举
pub const MaterialId = blk: {
    @setEvalBranchQuota(10000);
    const block_count = block_infos.len;
    var fields: [block_count * MAX_VARIANTS]std.builtin.Type.EnumField = undefined;
    var idx: usize = 0;
    for (block_infos, 0..) |info, block_idx| {
        _ = block_idx;
        for (0..MAX_VARIANTS) |v| {
            const variant: u3 = @intCast(v);
            const field_name = info.name ++ "_" ++ std.fmt.comptimePrint("{d}", .{variant});
            fields[idx] = .{ .name = field_name, .value = idx };
            idx += 1;
        }
    }
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u32,
        .fields = fields[0..idx],
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub const MaterialKey = struct {
    block_id: BlockId,
    variant: u3,
    pub fn toId(key: MaterialKey) MaterialId {
        const base = @intFromEnum(key.block_id) * MAX_VARIANTS;
        return @enumFromInt(base + key.variant);
    }
    pub fn fromId(id: MaterialId) MaterialKey {
        const val = @intFromEnum(id);
        return .{
            .block_id = @enumFromInt(val / MAX_VARIANTS),
            .variant = @intCast(val % MAX_VARIANTS),
        };
    }
};

const MAX_MATERIALS = block_infos.len * MAX_VARIANTS;

pub const MaterialRegistry = struct {
    gctx: *Gctx,
    pipeline: *RenderPipeline,
    allocator: std.mem.Allocator,

    materials: std.EnumArray(MaterialId, ?CachedMaterial),
    active_materials: SparseSet(bool, MAX_MATERIALS), // 值类型改为 bool

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, pipeline: *RenderPipeline) !Self {
        return .{
            .gctx = gctx,
            .pipeline = pipeline,
            .allocator = allocator,
            .materials = .{ .values = .{null} ** std.enums.values(MaterialId).len },
            .active_materials = SparseSet(bool, MAX_MATERIALS).init(),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.active_materials.iterator();
        while (iter.next()) |entry| {
            const key_usize = entry[0];
            const id: MaterialId = @enumFromInt(key_usize);
            if (self.materials.getPtr(id).*) |*cached| {
                cached.deinit(); // cached 是 *CachedMaterial
            }
        }
        self.active_materials.deinit(self.allocator);
    }

    /// 每帧开始时调用，重置所有活跃材质的引用计数
    pub fn resetRefCounts(self: *Self) void {
        var iter = self.active_materials.iterator();
        while (iter.next()) |entry| {
            const id: MaterialId = @enumFromInt(entry[0]);
            if (self.materials.getPtr(id).*) |*cached| {
                cached.ref_count = 0;
            }
        }
    }

    /// 获取或加载材质，增加引用计数。返回可写指针以便后续操作（如更新顶点）
    pub fn acquire(self: *Self, key: MaterialKey) !*CachedMaterial {
        const id = key.toId();
        // 检查是否未加载
        if (self.materials.get(id) == null) {
            const cached = try self.loadMaterial(key);
            self.materials.set(id, cached);
            self.active_materials.set(self.allocator, sparseKey(id), true);
        }
        // 获取可变指针并增加引用计数
        var cached = &(self.materials.getPtr(id).*).?;
        cached.ref_count += 1;
        return cached;
    }

    /// 每帧结束时调用，卸载引用计数为 0 的材质
    pub fn removeZeroRefMaterials(self: *Self) void {
        var iter = self.active_materials.iterator();
        while (iter.next()) |entry| {
            const id: MaterialId = @enumFromInt(entry[0]);
            if (self.materials.getPtr(id).*) |*cached| {
                if (cached.ref_count == 0) {
                    cached.deinit(self.gctx);
                    self.materials.set(id, null);
                    _ = self.active_materials.remove(entry[0]);
                }
            }
        }
    }

    /// 内部：加载材质纹理、创建占位顶点缓冲区
    fn loadMaterial(self: *Self, key: MaterialKey) !CachedMaterial {
        const block_id = key.block_id;
        const variant = key.variant;
        const block_info = block_id.prototype();

        // 构建纹理路径
        const color_path = try self.buildTexturePath(block_info.name, variant, false);
        defer self.allocator.free(color_path);
        const normal_path = try self.buildTexturePath(block_info.name, variant, true);
        defer self.allocator.free(normal_path);

        // 创建默认材质（包含独立默认纹理）
        var material = try Material.initDefault(self.gctx, self.pipeline);
        errdefer material.deinit();

        // 尝试加载颜色纹理，成功则替换默认纹理
        if (TextureRes.loadFromFile(self.allocator, self.gctx, color_path)) |color_tex| {
            material.setColorTexture(self.gctx, self.pipeline, color_tex);
        } else |_| {}

        // 尝试加载法线纹理
        if (TextureRes.loadFromFile(self.allocator, self.gctx, normal_path)) |normal_tex| {
            material.setNormalTexture(self.gctx, self.pipeline, normal_tex);
        } else |_| {}

        return CachedMaterial.init(self.gctx, material);
    }

    fn buildTexturePath(self: *Self, base_name: [:0]const u8, variant: u3, is_normal: bool) ![]u8 {
        const suffix = if (is_normal) "_n" else "";
        const file_name = try std.fmt.allocPrint(self.allocator, "{s}_{d}{s}.png", .{ base_name, variant, suffix });
        errdefer self.allocator.free(file_name);
        const full_path = try std.fs.path.join(self.allocator, &.{ "resources", "textures", file_name });
        self.allocator.free(file_name);
        return full_path;
    }

    fn sparseKey(id: MaterialId) usize {
        return @intFromEnum(id);
    }
};

pub const CachedMaterial = struct {
    material: Material,
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    vertex_count: u32,
    index_count: u32,
    ref_count: u32,
    pub fn init(gctx: *Gctx, material: Material) !CachedMaterial {
        const vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = 0,
            .usage = Wgpu.WGPUBufferUsage_Vertex | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        const index_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = 0,
            .usage = Wgpu.WGPUBufferUsage_Index | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        return .{
            .material = material,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .vertex_count = 0,
            .index_count = 0,
            .ref_count = 0,
        };
    }
    pub fn deinit(self: *CachedMaterial) void {
        self.material.deinit();
        if (self.vertex_buffer) |b| Wgpu.wgpuBufferRelease(b);
        if (self.index_buffer) |b| Wgpu.wgpuBufferRelease(b);
    }
    /// 替换整个顶点和索引缓冲区
    pub fn updateMesh(
        self: *CachedMaterial,
        gctx: *Gctx,
        vertices: []const VertexAttribute,
        indices: []const u32,
    ) !void {
        // 释放旧缓冲区
        if (self.vertex_buffer) |old| Wgpu.wgpuBufferRelease(old);
        if (self.index_buffer) |old| Wgpu.wgpuBufferRelease(old);
        // 上传顶点
        const vtx_size = @sizeOf(VertexAttribute) * vertices.len;
        self.vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = vtx_size,
            .usage = Wgpu.WGPUBufferUsage_Vertex | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        if (vtx_size > 0) {
            Wgpu.wgpuQueueWriteBuffer(gctx.queue, self.vertex_buffer, 0, vertices.ptr, vtx_size);
        }
        // 上传索引
        const idx_size = @sizeOf(u32) * indices.len;
        self.index_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = idx_size,
            .usage = Wgpu.WGPUBufferUsage_Index | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        if (idx_size > 0) {
            Wgpu.wgpuQueueWriteBuffer(gctx.queue, self.index_buffer, 0, indices.ptr, idx_size);
        }
        self.vertex_count = @intCast(vertices.len);
        self.index_count = @intCast(indices.len);
    }
};

pub const Direction = enum(u3) {
    up, // +Y   (索引 0)
    down, // -Y   (索引 1)
    north, // -Z   (索引 2)  注意：这里定义 north 为 -Z
    south, // +Z   (索引 3)
    west, // -X   (索引 4)
    east, // +X   (索引 5)

    /// 返回该方向的单位法线向量
    pub fn normal(self: Direction) Vec3 {
        return switch (self) {
            .up => Vec3.new(0, 1, 0),
            .down => Vec3.new(0, -1, 0),
            .north => Vec3.new(0, 0, -1),
            .south => Vec3.new(0, 0, 1),
            .west => Vec3.new(-1, 0, 0),
            .east => Vec3.new(1, 0, 0),
        };
    }

    /// 返回该方向的整数偏移向量（用于邻居查找）
    pub fn offset(self: Direction) Vec3i {
        return switch (self) {
            .up => Vec3i.new(0, 1, 0),
            .down => Vec3i.new(0, -1, 0),
            .north => Vec3i.new(0, 0, -1),
            .south => Vec3i.new(0, 0, 1),
            .west => Vec3i.new(-1, 0, 0),
            .east => Vec3i.new(1, 0, 0),
        };
    }
};

// 临时网格构建器
const MeshBuilder = struct {
    vertices: std.ArrayListUnmanaged(VertexAttribute),
    indices: std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) MeshBuilder {
        return .{
            .vertices = std.ArrayList(VertexAttribute){},
            .indices = std.ArrayList(u32){},
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *MeshBuilder) void {
        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }
};

// 核心：为一个区块生成网格数据并上传到材质缓冲区
pub fn buildChunkMesh(chunk: *const Chunk, registry: *MaterialRegistry) !void {
    const allocator = registry.allocator;

    var mesh_map = std.AutoHashMap(MaterialId, MeshBuilder).init(allocator);
    defer {
        var iter = mesh_map.valueIterator();
        while (iter.next()) |builder| builder.deinit();
        mesh_map.deinit();
    }

    for (0..CHUNK_SIZE_X) |x| {
        for (0..CHUNK_SIZE_Z) |z| {
            for (0..CHUNK_SIZE_Y) |y| {
                const block_state = chunk.blocks[x][y][z];
                const block_id = block_state.block_id;
                if (block_id == BlockId.fromName("air")) continue;
                const proto = block_id.prototype();

                // 计算方块旋转（保持单位旋转当无方向性时）
                const rot = if (proto.is_directional)
                    fromToRotation(Vec3.up, block_state.facing.normal())
                else
                    Quat.identity;

                const dirs = std.enums.values(Direction);
                for (dirs) |dir| {
                    // 世界方向（判断邻居、生成顶点位置）
                    const world_dir = dir;
                    const offset = dir.offset();
                    const nx = @as(i32, @intCast(x)) + offset.x;
                    const ny = @as(i32, @intCast(y)) + offset.y;
                    const nz = @as(i32, @intCast(z)) + offset.z;

                    var neighbor: BlockId = .fromName("air");
                    if (nx >= 0 and nx < CHUNK_SIZE_X and
                        ny >= 0 and ny < CHUNK_SIZE_Y and
                        nz >= 0 and nz < CHUNK_SIZE_Z)
                    {
                        neighbor = chunk.blocks[@intCast(nx)][@intCast(ny)][@intCast(nz)].block_id;
                    } else {
                        neighbor = .fromName("air");
                    }

                    const neighbor_proto = neighbor.prototype();
                    if (neighbor_proto.occludes) continue;
                    // 相邻透明且同种方块之间不渲染面（水-水、玻璃-玻璃等）
                    if (!proto.occludes and block_id == neighbor and neighbor != BlockId.fromName("air")) continue;

                    // 局部方向（用于材质变体和UV轴旋转）
                    const local_dir = if (proto.is_directional) blk: {
                        const world_vec = world_dir.normal();
                        const local_vec = rot.inverse().rotate(world_vec);
                        break :blk directionFromVec(local_vec);
                    } else world_dir;

                    // 材质变体选择
                    const face_index = @intFromEnum(local_dir);
                    const variant = proto.face_variants[face_index];
                    const mat_key = MaterialKey{ .block_id = block_id, .variant = variant };
                    const mat_id = mat_key.toId();

                    const gop = try mesh_map.getOrPut(mat_id);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = MeshBuilder.init(allocator);
                    }

                    // 获取标准姿态的面数据（局部方向）
                    const face_data = getStandardFaceData(local_dir);
                    const center = Vec3.new(
                        @as(f32, @floatFromInt(x)) + 0.5,
                        @as(f32, @floatFromInt(y)) + 0.5,
                        @as(f32, @floatFromInt(z)) + 0.5,
                    );

                    // 构建顶点和索引
                    const builder_ptr = gop.value_ptr; // 指向 MeshBuilder 的指针
                    const start_vertex = builder_ptr.vertices.items.len;

                    for (face_data.positions, face_data.uvs) |local_pos, uv| {
                        const world_pos = rot.rotate(local_pos).add(center);
                        const world_normal = rot.rotate(local_dir.normal());
                        try builder_ptr.vertices.append(allocator, VertexAttribute{
                            .position = world_pos,
                            .normal = world_normal,
                            .texcoord = uv,
                            .tangent = Vec4.new(1, 0, 0, 1),
                            .color = Vec4.new(1, 1, 1, 1),
                            .joint_indices = .{ 0, 0, 0, 0 },
                            .joint_weights = .{ 1, 0, 0, 0 },
                        });
                    }

                    // 两个三角形组成面
                    try builder_ptr.indices.appendSlice(allocator, &[_]u32{
                        @intCast(start_vertex), @intCast(start_vertex + 2), @intCast(start_vertex + 1),
                        @intCast(start_vertex), @intCast(start_vertex + 3), @intCast(start_vertex + 2),
                    });
                }
            }
        }
    }

    var mesh_iter = mesh_map.iterator();
    while (mesh_iter.next()) |entry| {
        const mat_id = entry.key_ptr.*;
        const builder = entry.value_ptr;

        if (builder.vertices.items.len == 0) continue;

        const material_key = MaterialKey.fromId(mat_id);
        const cached = try registry.acquire(material_key);
        try cached.updateMesh(registry.gctx, builder.vertices.items, builder.indices.items);
    }
}

pub const BlockState = struct {
    block_id: BlockId = BlockId.fromName("air"),
    facing: Direction = .up,
    durability: u32 = 10,
    /// 从一个方块ID创建默认状态（使用原型中的耐久度）
    pub fn init(block_id: BlockId) BlockState {
        return .{
            .block_id = block_id,
            .facing = .up,
            .durability = block_id.prototype().durability,
        };
    }
};

/// 返回从向量 from 到 to 的最短旋转四元数
fn fromToRotation(from: Vec3, to: Vec3) Quat {
    const f = from.norm();
    const t = to.norm();
    const dot = f.dot(t);
    if (dot > 0.9999) return Quat.identity;
    if (dot < -0.9999) {
        // 180° 旋转，找一个与 from 垂直的轴
        const perp = if (@abs(f.x) < 0.9) Vec3.new(1, 0, 0) else Vec3.new(0, 1, 0);
        const axis = f.cross(perp).norm();
        return Quat.fromAxisAngle(axis, std.math.pi);
    }
    const axis = f.cross(t).norm();
    const angle = std.math.acos(dot);
    return Quat.fromAxisAngle(axis, angle);
}

fn directionFromVec(v: Vec3) Direction {
    const ax = @abs(v.x);
    const ay = @abs(v.y);
    const az = @abs(v.z);
    if (ay >= ax and ay >= az) return if (v.y > 0) .up else .down;
    if (ax >= ay and ax >= az) return if (v.x > 0) .east else .west;
    return if (v.z > 0) .south else .north;
}

const FaceData = struct {
    positions: [4]Vec3,
    uvs: [4]Vec2,
};

fn getStandardFaceData(local_dir: Direction) FaceData {
    const h = 0.5;
    return switch (local_dir) {
        .up => FaceData{
            .positions = .{
                Vec3.new(-h, h, -h),
                Vec3.new(h, h, -h),
                Vec3.new(h, h, h),
                Vec3.new(-h, h, h),
            },
            .uvs = .{
                Vec2.new(0, 1), Vec2.new(1, 1), Vec2.new(1, 0), Vec2.new(0, 0),
            },
        },
        .down => FaceData{
            .positions = .{
                Vec3.new(-h, -h, h),
                Vec3.new(h, -h, h),
                Vec3.new(h, -h, -h),
                Vec3.new(-h, -h, -h),
            },
            .uvs = .{
                Vec2.new(0, 0), Vec2.new(1, 0), Vec2.new(1, 1), Vec2.new(0, 1),
            },
        },
        .north => FaceData{
            .positions = .{
                Vec3.new(-h, -h, -h),
                Vec3.new(h, -h, -h),
                Vec3.new(h, h, -h),
                Vec3.new(-h, h, -h),
            },
            .uvs = .{
                Vec2.new(0, 1), Vec2.new(1, 1), Vec2.new(1, 0), Vec2.new(0, 0),
            },
        },
        .south => FaceData{
            .positions = .{
                Vec3.new(h, -h, h),
                Vec3.new(-h, -h, h),
                Vec3.new(-h, h, h),
                Vec3.new(h, h, h),
            },
            .uvs = .{
                Vec2.new(1, 1), Vec2.new(0, 1), Vec2.new(0, 0), Vec2.new(1, 0),
            },
        },
        .east => FaceData{
            .positions = .{
                Vec3.new(h, -h, -h),
                Vec3.new(h, -h, h),
                Vec3.new(h, h, h),
                Vec3.new(h, h, -h),
            },
            .uvs = .{
                Vec2.new(0, 1), Vec2.new(1, 1), Vec2.new(1, 0), Vec2.new(0, 0),
            },
        },
        .west => FaceData{
            .positions = .{
                Vec3.new(-h, -h, h),
                Vec3.new(-h, -h, -h),
                Vec3.new(-h, h, -h),
                Vec3.new(-h, h, h),
            },
            .uvs = .{
                Vec2.new(0, 1), Vec2.new(1, 1), Vec2.new(1, 0), Vec2.new(0, 0),
            },
        },
    };
}

// ---------------------------------------------------------------
// 物理系统
// ---------------------------------------------------------------

// 物理常量（可调整）
const GRAVITY: f32 = 25.0;
const FLUID_GRAVITY: f32 = 5.0;
const SWIM_UP_SPEED: f32 = 5.0;
const SWIM_DOWN_SPEED: f32 = 3.0;
const SINK_TERMINAL: f32 = -2.0;
const GROUND_FRICTION: f32 = 0.6;
const AIR_FRICTION: f32 = 4.0;
const ACCELERATION: f32 = 30.0;
const PHYS_EPS = 1e-6;

pub const BlockWorld = struct {
    allocator: std.mem.Allocator,
    chunk: *Chunk,
    material_registry: MaterialRegistry,
    collision_list: std.ArrayListUnmanaged(AABB) = .{}, // 物理碰撞列表（复用）

    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, pipeline: *RenderPipeline) !BlockWorld {
        const chunk = try allocator.create(Chunk);
        errdefer allocator.destroy(chunk);
        Chunk.generate(.new(0, 0, 0), chunk);

        var material_registry = try MaterialRegistry.init(allocator, gctx, pipeline);
        errdefer material_registry.deinit();

        try buildChunkMesh(chunk, &material_registry);

        return BlockWorld{
            .allocator = allocator,
            .chunk = chunk,
            .material_registry = material_registry,
            .collision_list = .{},
        };
    }

    pub fn deinit(self: *BlockWorld) void {
        self.material_registry.deinit();
        self.collision_list.deinit(self.allocator);
        self.allocator.destroy(self.chunk);
    }

    pub fn updatePhysics(self: *BlockWorld, registry: *ECS.Registry, dt: f32) void {
        var view = registry.view(.{
            Comps.Position,
            Comps.Velocity,
            Comps.AABB,
            Comps.MoveSpeed,
            Comps.JumpVelocity,
            Comps.OnGround,
            Comps.MoveIntent,
        }, .{});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const pos = view.get(Comps.Position, entity);
            const vel = view.get(Comps.Velocity, entity);
            const aabb = view.get(Comps.AABB, entity);
            const move_speed = view.get(Comps.MoveSpeed, entity);
            const jump_vel = view.get(Comps.JumpVelocity, entity);
            const on_ground = view.get(Comps.OnGround, entity);
            var intent = view.get(Comps.MoveIntent, entity);

            const in_swimmable = isInSwimmable(pos, aabb, self.chunk);
            const resistance: f32 = if (in_swimmable) blk: {
                const mid = pos.vec.add(Vec3.new(0, aabb.height * 0.5, 0));
                const block_id = getBlockAt(self.chunk, mid);
                break :blk if (block_id.prototype().is_swimmable) block_id.prototype().fluid_resistance else 0.0;
            } else 0.0;

            const effective_gravity: f32 = if (in_swimmable) FLUID_GRAVITY else GRAVITY;
            const max_speed = move_speed.value * (1.0 - resistance);
            const acceleration = ACCELERATION * (1.0 - resistance);

            // ---- 垂直移动 ----
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
                // 跳跃
                if (intent.jump and on_ground.value) {
                    vel.vec.y = jump_vel.value;
                    on_ground.value = false;
                }
            }

            // ---- 水平移动 ----
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

            // ---- 碰撞移动 ----
            const dx = vel.vec.x * dt;
            const dy = vel.vec.y * dt;
            const dz = vel.vec.z * dt;
            moveEntity(pos, vel, aabb, on_ground, self.chunk, &self.collision_list, self.allocator, dx, dy, dz);

            // 消费跳跃意图（本帧已处理）
            intent.jump = false;
        }
    }

    fn getEntityAABB(pos: Vec3, aabb: *Comps.AABB) AABB {
        const half_w = aabb.width / 2.0;
        return AABB{
            .min_x = pos.x - half_w,
            .max_x = pos.x + half_w,
            .min_y = pos.y,
            .max_y = pos.y + aabb.height,
            .min_z = pos.z - half_w,
            .max_z = pos.z + half_w,
        };
    }

    fn moveEntity(
        pos: *Comps.Position,
        vel: *Comps.Velocity,
        aabb: *Comps.AABB,
        on_ground: *Comps.OnGround,
        chunk: *Chunk,
        collision_list: *std.ArrayListUnmanaged(AABB),
        allocator: std.mem.Allocator,
        xd: f32,
        yd: f32,
        zd: f32,
    ) void {
        var dx = xd;
        var dy = yd;
        var dz = zd;
        var box = getEntityAABB(pos.vec, aabb);

        // 收集碰撞方块
        collision_list.clearRetainingCapacity();
        getCollidingBlocks(chunk, box.expand(dx, dy, dz), collision_list, allocator);

        // Y 轴
        for (collision_list.items) |block| {
            dy = block.clipYCollide(box, dy);
        }
        box = box.move(0, dy, 0);
        const was_falling = yd < 0;
        const blocked_y = (yd != dy);
        on_ground.value = blocked_y and was_falling;
        if (on_ground.value) vel.vec.y = 0;

        // X 轴
        for (collision_list.items) |block| {
            dx = block.clipXCollide(box, dx);
        }
        box = box.move(dx, 0, 0);

        // Z 轴
        for (collision_list.items) |block| {
            dz = block.clipZCollide(box, dz);
        }
        box = box.move(0, 0, dz);

        pos.vec.x = (box.min_x + box.max_x) / 2.0;
        pos.vec.z = (box.min_z + box.max_z) / 2.0;
        pos.vec.y = box.min_y;

        // 去穿透：卡在方块中时尝试推出
        if (isColliding(pos.vec, aabb, chunk))
            pushOutOfBlocks(pos.vec, aabb, chunk, vel);
    }

    fn getCollidingBlocks(chunk: *Chunk, expanded_box: AABB, out_list: *std.ArrayListUnmanaged(AABB), allocator: std.mem.Allocator) void {
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
                    const block_id = getBlockAt(chunk, world_pos);
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
                    out_list.append(allocator, bb) catch continue;
                }
            }
        }
    }

    fn isInSwimmable(pos: *Comps.Position, aabb: *Comps.AABB, chunk: *Chunk) bool {
        const points = [_]Vec3{
            pos.vec.add(Vec3.new(0, 0.1, 0)),
            pos.vec.add(Vec3.new(0, aabb.height * 0.5, 0)),
            pos.vec.add(Vec3.new(0, aabb.height - 0.1, 0)),
        };
        for (points) |p| {
            if (getBlockAt(chunk, p).prototype().is_swimmable) return true;
        }
        return false;
    }

    fn isColliding(pos: Vec3, aabb: *Comps.AABB, chunk: *Chunk) bool {
        const box = getEntityAABB(pos, aabb);
        const min_x = @as(i32, @intFromFloat(@floor(box.min_x)));
        const max_x = @as(i32, @intFromFloat(@floor(box.max_x)));
        const min_y = @as(i32, @intFromFloat(@floor(box.min_y)));
        const max_y = @as(i32, @intFromFloat(@floor(box.max_y)));
        const min_z = @as(i32, @intFromFloat(@floor(box.min_z)));
        const max_z = @as(i32, @intFromFloat(@floor(box.max_z)));

        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                var z = min_z;
                while (z <= max_z) : (z += 1) {
                    const block_id = getBlockAt(chunk, Vec3.new(
                        @as(f32, @floatFromInt(x)) + 0.5,
                        @as(f32, @floatFromInt(y)) + 0.5,
                        @as(f32, @floatFromInt(z)) + 0.5,
                    ));
                    if (block_id == BlockId.fromName("air")) continue;
                    if (block_id.prototype().is_solid) return true;
                }
            }
        }
        return false;
    }

    fn pushOutOfBlocks(pos: Vec3, aabb: *Comps.AABB, chunk: *Chunk, vel: *Comps.Velocity) void {
        const half_w = aabb.width * 0.35;
        const points = [4]Vec3{
            pos.add(Vec3.new(-half_w, 0.5, half_w)),
            pos.add(Vec3.new(-half_w, 0.5, -half_w)),
            pos.add(Vec3.new(half_w, 0.5, -half_w)),
            pos.add(Vec3.new(half_w, 0.5, half_w)),
        };

        for (points) |point| {
            const px = point.x;
            const py = point.y;
            const pz = point.z;
            const block_x = @as(i32, @intFromFloat(@floor(px)));
            const block_y = @as(i32, @intFromFloat(@floor(py)));
            const block_z = @as(i32, @intFromFloat(@floor(pz)));

            if (!isBlockSolidAt(chunk, @floatFromInt(block_x), @floatFromInt(block_y), @floatFromInt(block_z)) and
                !isBlockSolidAt(chunk, @floatFromInt(block_x), @floatFromInt(block_y + 1), @floatFromInt(block_z))) continue;

            const dirs = [4]Direction{ .west, .east, .north, .south };
            var best_dir: ?Direction = null;
            var best_dist: f32 = 9999.0;

            const local_x = px - @as(f32, @floatFromInt(block_x));
            const local_z = pz - @as(f32, @floatFromInt(block_z));

            for (dirs) |dir| {
                const off = dir.offset();
                const nx = block_x + off.x;
                const ny = block_y;
                const nz = block_z + off.z;
                if (!isBlockSolidAt(chunk, @floatFromInt(nx), @floatFromInt(ny), @floatFromInt(nz)) and
                    !isBlockSolidAt(chunk, @floatFromInt(nx), @floatFromInt(ny + 1), @floatFromInt(nz)))
                {
                    const d = switch (dir) {
                        .west => local_x,
                        .east => 1.0 - local_x,
                        .north => local_z,
                        .south => 1.0 - local_z,
                        else => 9999.0,
                    };
                    if (d < best_dist) {
                        best_dir = dir;
                        best_dist = d;
                    }
                }
            }

            if (best_dir) |dir| {
                const off = dir.offset();
                vel.vec.x = @as(f32, @floatFromInt(off.x)) * 0.1;
                vel.vec.z = @as(f32, @floatFromInt(off.z)) * 0.1;
            }
        }
    }

    fn isBlockSolidAt(chunk: *Chunk, x: f32, y: f32, z: f32) bool {
        const block_id = getBlockAt(chunk, Vec3.new(x, y, z));
        if (block_id == BlockId.fromName("air")) return false;
        return block_id.prototype().is_solid;
    }

    pub fn getBlockAt(chunk: *Chunk, pos: Vec3) BlockId {
        const x = @as(i32, @intFromFloat(@floor(pos.x)));
        const y = @as(i32, @intFromFloat(@floor(pos.y)));
        const z = @as(i32, @intFromFloat(@floor(pos.z)));
        if (x >= 0 and x < CHUNK_SIZE_X and
            y >= 0 and y < CHUNK_SIZE_Y and
            z >= 0 and z < CHUNK_SIZE_Z)
        {
            return chunk.blocks[@intCast(x)][@intCast(y)][@intCast(z)].block_id;
        }
        return .fromName("air");
    }
};

pub const AABB = struct {
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,

    pub fn init(min_x: f32, min_y: f32, min_z: f32, max_x: f32, max_y: f32, max_z: f32) AABB {
        return .{ .min_x = min_x, .min_y = min_y, .min_z = min_z, .max_x = max_x, .max_y = max_y, .max_z = max_z };
    }

    pub fn expand(self: AABB, dx: f32, dy: f32, dz: f32) AABB {
        return AABB{
            .min_x = @min(self.min_x, self.min_x + dx),
            .max_x = @max(self.max_x, self.max_x + dx),
            .min_y = @min(self.min_y, self.min_y + dy),
            .max_y = @max(self.max_y, self.max_y + dy),
            .min_z = @min(self.min_z, self.min_z + dz),
            .max_z = @max(self.max_z, self.max_z + dz),
        };
    }

    pub fn move(self: AABB, dx: f32, dy: f32, dz: f32) AABB {
        return AABB{
            .min_x = self.min_x + dx,
            .max_x = self.max_x + dx,
            .min_y = self.min_y + dy,
            .max_y = self.max_y + dy,
            .min_z = self.min_z + dz,
            .max_z = self.max_z + dz,
        };
    }

    pub fn clipXCollide(self: AABB, moving_box: AABB, move_distance: f32) f32 {
        // 只有当 Y 轴和 Z 轴都有重叠时，才考虑 X 轴碰撞
        if (moving_box.max_y <= self.min_y or moving_box.min_y >= self.max_y) return move_distance;
        if (moving_box.max_z <= self.min_z or moving_box.min_z >= self.max_z) return move_distance;
        return clipAxisCollide(self.min_x, self.max_x, moving_box.min_x, moving_box.max_x, move_distance);
    }

    pub fn clipYCollide(self: AABB, moving_box: AABB, move_distance: f32) f32 {
        if (moving_box.max_x <= self.min_x or moving_box.min_x >= self.max_x) return move_distance;
        if (moving_box.max_z <= self.min_z or moving_box.min_z >= self.max_z) return move_distance;
        return clipAxisCollide(self.min_y, self.max_y, moving_box.min_y, moving_box.max_y, move_distance);
    }

    pub fn clipZCollide(self: AABB, moving_box: AABB, move_distance: f32) f32 {
        if (moving_box.max_x <= self.min_x or moving_box.min_x >= self.max_x) return move_distance;
        if (moving_box.max_y <= self.min_y or moving_box.min_y >= self.max_y) return move_distance;
        return clipAxisCollide(self.min_z, self.max_z, moving_box.min_z, moving_box.max_z, move_distance);
    }

    fn clipAxisCollide(block_min: f32, block_max: f32, box_min: f32, box_max: f32, move_dist: f32) f32 {
        if (move_dist > 0.0) {
            // 正向移动
            if (box_max + move_dist > block_min) {
                const max_allowed = block_min - box_max; // 可以是负数（已穿透）
                if (max_allowed < 0) {
                    // 已经穿透，正向移动会加深穿透 → 阻止
                    return 0;
                }
                return @min(move_dist, max_allowed - PHYS_EPS);
            }
        } else if (move_dist < 0.0) {
            // 负向移动
            if (box_min + move_dist < block_max) {
                const min_allowed = block_max - box_min; // 可以是正数（已穿透）
                if (min_allowed > 0) {
                    // 已经穿透，负向移动是脱离方向 → 允许
                    return move_dist;
                }
                return @max(move_dist, min_allowed + PHYS_EPS);
            }
        }
        return move_dist;
    }
};
