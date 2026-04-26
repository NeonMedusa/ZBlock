const std = @import("std");
const Imports = @import("imports.zig");
const Vec2 = Imports.Vec2;
const Vec3 = Imports.Vec3;
const Vec3i = Imports.Vec3i;
const Vec3u = Imports.Vec3u;
const Vec4 = Imports.Vec4;
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

/// 方块原型
pub const BlockProtoType = struct {
    name: [:0]const u8, // 方块名
    face_variants: [6]u3 = [1]u3{0} ** 6, // 每个面应用什么材质
    occludes: bool = true, // 新增：是否遮挡相邻方块的面
    opacity: f32 = 1.0, // 不透明度
    solidity: f32 = 1.0, // 流体-固体，1.0代表固体
};

/// 方块注册表
const block_infos = [_]BlockProtoType{
    .{
        .name = "air",
        .occludes = false,
        .opacity = 0.0,
        .solidity = 0.0,
    },
    .{
        .name = "grass",
        .face_variants = .{ 0, 0, 0, 0, 1, 2 },
    },
    .{ .name = "stone" },
    .{ .name = "dirt" },
    .{ .name = "sand" },
    .{
        .name = "water",
        .occludes = false,
        .opacity = 0.5,
        .solidity = 0.3,
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

pub const CHUNK_SIZE_X: u32 = 64;
pub const CHUNK_SIZE_Y: u32 = 256;
pub const CHUNK_SIZE_Z: u32 = 64;
pub const ChunkSize = Vec3u{
    .x = CHUNK_SIZE_X,
    .y = CHUNK_SIZE_Y,
    .z = CHUNK_SIZE_Z,
};

pub const Chunk = struct {
    blocks: [CHUNK_SIZE_X][CHUNK_SIZE_Y][CHUNK_SIZE_Z]BlockId,

    pub fn generate(world_origin: Vec3i) Chunk {
        const noise_scale: f32 = 0.05;
        const world_height: i32 = 128;
        const water_height: i32 = 64;
        var chunk: Chunk = undefined;

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
                    const block: BlockId = blk: {
                        if (y_i32 > ground_position) {
                            if (y_i32 < water_height) break :blk .fromName("water");
                            break :blk .fromName("air");
                        } else if (y_i32 == ground_position) {
                            if (y_i32 < water_height) break :blk .fromName("sand");
                            break :blk .fromName("grass");
                        } else {
                            // 地表以下
                            const depth = ground_position - y_i32;
                            if (depth >= 5) break :blk .fromName("stone");
                            break :blk .fromName("dirt");
                        }
                    };
                    chunk.blocks[x][y][z] = block;
                }
            }
        }
        return chunk;
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

test "foo" {
    const id = BlockId.fromInt(1);
    std.debug.print("\n{s}\n", .{id.name()});

    const grass_id = BlockId.fromName("grass");
    const water_prototype = grass_id.prototype();

    std.debug.print("{}\n", .{water_prototype.solidity});

    const grass_mat_key = MaterialKey{ .block_id = grass_id, .variant = 0 };
    const grass_mat_id = grass_mat_key.toId();
    std.debug.print("{}\n", .{grass_mat_id});

    const material_count = block_infos.len * 8;
    var active_materials = SparseSet(MaterialId, material_count).init();
    defer active_materials.deinit(std.testing.allocator);

    active_materials.set(std.testing.allocator, @intFromEnum(grass_mat_key.toId()), grass_mat_id);
    if (active_materials.getPtr(@intFromEnum(grass_mat_key.toId()))) |grass_mat|
        std.debug.print("Got it:{}\n", .{grass_mat});
}

const Direction = enum(u3) {
    forwards, // +Z
    backwards, // -Z
    right, // +X
    left, // -X
    up, // +Y
    down, // -Y

    pub fn normal(self: Direction) Vec3 {
        return switch (self) {
            .forwards => Vec3.new(0, 0, 1),
            .backwards => Vec3.new(0, 0, -1),
            .right => Vec3.new(1, 0, 0),
            .left => Vec3.new(-1, 0, 0),
            .up => Vec3.new(0, 1, 0),
            .down => Vec3.new(0, -1, 0),
        };
    }

    pub fn offset(self: Direction) Vec3i {
        return switch (self) {
            .forwards => Vec3i.new(0, 0, 1),
            .backwards => Vec3i.new(0, 0, -1),
            .right => Vec3i.new(1, 0, 0),
            .left => Vec3i.new(-1, 0, 0),
            .up => Vec3i.new(0, 1, 0),
            .down => Vec3i.new(0, -1, 0),
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

    // 添加一个完整的方形面（4 个顶点，两个三角形）
    pub fn addFace(self: *MeshBuilder, center: Vec3, dir: Direction, allocator: std.mem.Allocator) !void {
        const x = center.x;
        const y = center.y;
        const z = center.z;
        const h = 0.5;

        var positions: [4]Vec3 = undefined;
        var uvs: [4]Vec2 = undefined;
        const normal = dir.normal();

        switch (dir) {
            .up => {
                // 从上方看，CCW：左后 -> 右后 -> 右前 -> 左前
                positions = .{
                    Vec3.new(x - h, y + h, z - h), // v0
                    Vec3.new(x + h, y + h, z - h), // v1
                    Vec3.new(x + h, y + h, z + h), // v2
                    Vec3.new(x - h, y + h, z + h), // v3
                };
                uvs = .{
                    Vec2.new(0, 1), // V 翻转后，左下对应世界左后
                    Vec2.new(1, 1),
                    Vec2.new(1, 0),
                    Vec2.new(0, 0),
                };
            },
            .down => {
                // 从下方看，CCW：左前 -> 右前 -> 右后 -> 左后
                positions = .{
                    Vec3.new(x - h, y - h, z + h),
                    Vec3.new(x + h, y - h, z + h),
                    Vec3.new(x + h, y - h, z - h),
                    Vec3.new(x - h, y - h, z - h),
                };
                uvs = .{
                    Vec2.new(0, 0),
                    Vec2.new(1, 0),
                    Vec2.new(1, 1),
                    Vec2.new(0, 1),
                };
            },
            .forwards => {
                // 前 (+Z)，从 +Z 看 CCW：右下 -> 左下 -> 左上 -> 右上
                positions = .{
                    Vec3.new(x + h, y - h, z + h), // 右下
                    Vec3.new(x - h, y - h, z + h), // 左下
                    Vec3.new(x - h, y + h, z + h), // 左上
                    Vec3.new(x + h, y + h, z + h), // 右上
                };
                uvs = .{
                    Vec2.new(1, 1), // 翻转后：右下对应纹理右下
                    Vec2.new(0, 1), // 左下对应纹理左下
                    Vec2.new(0, 0), // 左上对应纹理左上
                    Vec2.new(1, 0), // 右上对应纹理右上
                };
            },
            .backwards => {
                // 后 (-Z)，从 -Z 看 CCW：左下 -> 右下 -> 右上 -> 左上
                positions = .{
                    Vec3.new(x - h, y - h, z - h),
                    Vec3.new(x + h, y - h, z - h),
                    Vec3.new(x + h, y + h, z - h),
                    Vec3.new(x - h, y + h, z - h),
                };
                uvs = .{
                    Vec2.new(0, 1),
                    Vec2.new(1, 1),
                    Vec2.new(1, 0),
                    Vec2.new(0, 0),
                };
            },
            .right => {
                // +X 面，从 +X 看 CCW：下后 -> 下前 -> 上前 -> 上后
                positions = .{
                    Vec3.new(x + h, y - h, z - h),
                    Vec3.new(x + h, y - h, z + h),
                    Vec3.new(x + h, y + h, z + h),
                    Vec3.new(x + h, y + h, z - h),
                };
                uvs = .{
                    Vec2.new(0, 1),
                    Vec2.new(1, 1),
                    Vec2.new(1, 0),
                    Vec2.new(0, 0),
                };
            },
            .left => {
                // -X 面，从 -X 看 CCW：下前 -> 下后 -> 上后 -> 上前
                positions = .{
                    Vec3.new(x - h, y - h, z + h),
                    Vec3.new(x - h, y - h, z - h),
                    Vec3.new(x - h, y + h, z - h),
                    Vec3.new(x - h, y + h, z + h),
                };
                uvs = .{
                    Vec2.new(0, 1),
                    Vec2.new(1, 1),
                    Vec2.new(1, 0),
                    Vec2.new(0, 0),
                };
            },
        }

        const base_index = @as(u32, @intCast(self.vertices.items.len));
        for (positions, uvs) |pos, uv| {
            try self.vertices.append(allocator, VertexAttribute{
                .position = pos,
                .normal = normal,
                .texcoord = uv,
                .tangent = Vec4.new(1, 0, 0, 1),
                .color = Vec4.new(1, 1, 1, 1),
                .joint_indices = .{ 0, 0, 0, 0 },
                .joint_weights = .{ 1, 0, 0, 0 },
            });
        }

        // 两个三角形 CCW 索引
        try self.indices.appendSlice(allocator, &[_]u32{
            base_index, base_index + 2, base_index + 1,
            base_index, base_index + 3, base_index + 2,
        });
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
                const block_id = chunk.blocks[x][y][z]; // [X][Y][Z]
                if (block_id == BlockId.fromName("air")) continue;
                const proto = block_id.prototype();

                const dirs = std.enums.values(Direction);
                for (dirs) |dir| {
                    const offset = dir.offset();
                    const nx = @as(i32, @intCast(x)) + offset.x;
                    const ny = @as(i32, @intCast(y)) + offset.y;
                    const nz = @as(i32, @intCast(z)) + offset.z;

                    var neighbor: BlockId = .fromName("air");
                    if (nx >= 0 and nx < CHUNK_SIZE_X and
                        ny >= 0 and ny < CHUNK_SIZE_Y and
                        nz >= 0 and nz < CHUNK_SIZE_Z)
                    {
                        neighbor = chunk.blocks[@intCast(nx)][@intCast(ny)][@intCast(nz)];
                    } else {
                        neighbor = .fromName("air");
                    }

                    if (neighbor.prototype().occludes) continue;

                    const face_index = @intFromEnum(dir);
                    const variant = proto.face_variants[face_index];
                    const mat_key = MaterialKey{ .block_id = block_id, .variant = variant };
                    const mat_id = mat_key.toId();

                    const gop = try mesh_map.getOrPut(mat_id);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = MeshBuilder.init(allocator);
                    }

                    const center = Vec3.new(
                        @as(f32, @floatFromInt(x)) + 0.5,
                        @as(f32, @floatFromInt(y)) + 0.5,
                        @as(f32, @floatFromInt(z)) + 0.5,
                    );
                    try gop.value_ptr.addFace(center, dir, registry.allocator);
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
