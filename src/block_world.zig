// block_world.zig
const std = @import("std");
const Imports = @import("imports.zig");
const Vec2 = Imports.Vec2;
const Vec3 = Imports.Vec3;
const Vec3i = Imports.Vec3i;
const Vec4 = Imports.Vec4;
const Quat = Imports.Quat;
const Wgpu = Imports.Wgpu;
const Material = Imports.RendCTX.Material;
const TextureRes = Imports.RendCTX.TextureRes;
const Gctx = Imports.Gctx;
const RenderPipeline = @import("render_pipeline.zig");
const SparseIndexSet = @import("sparse_set.zig").SparseIndexSet;
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
    is_swimmable: bool = false, // 是否可以在其中"游泳"（如水体）
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
    .{ .name = "foo" },
};

/// 生成"方块名→索引"的枚举
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
pub const MAX_VARIANTS = 8;

pub const MaterialKey = struct {
    block_id: BlockId,
    variant: u3,

    pub fn toId(key: MaterialKey) u32 {
        return @intFromEnum(key.block_id) * MAX_VARIANTS + key.variant;
    }

    pub fn fromId(id: u32) MaterialKey {
        return .{
            .block_id = @enumFromInt(id / MAX_VARIANTS),
            .variant = @intCast(id % MAX_VARIANTS),
        };
    }
};

const MAX_MATERIALS = block_infos.len * MAX_VARIANTS;
pub const MaterialIdx = u32;

pub const GlobalMaterial = struct {
    material: Material,
    ref_count: u32 = 0,

    pub fn deinit(self: *GlobalMaterial) void {
        self.material.deinit();
    }
};

pub const ChunkMesh = struct {
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    vertex_count: u32,
    index_count: u32,

    cpu_vertices: std.ArrayListUnmanaged(VertexAttribute) = .{},
    cpu_indices: std.ArrayListUnmanaged(u32) = .{},

    pub fn init(gctx: *Gctx) !ChunkMesh {
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
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .vertex_count = 0,
            .index_count = 0,
        };
    }

    pub fn deinit(self: *ChunkMesh, allocator: std.mem.Allocator) void {
        self.cpu_vertices.deinit(allocator);
        self.cpu_indices.deinit(allocator);
        if (self.vertex_buffer) |b| Wgpu.wgpuBufferRelease(b);
        if (self.index_buffer) |b| Wgpu.wgpuBufferRelease(b);
    }

    pub fn clearMeshData(self: *ChunkMesh) void {
        self.cpu_vertices.clearRetainingCapacity();
        self.cpu_indices.clearRetainingCapacity();
    }

    pub fn uploadMeshData(self: *ChunkMesh, gctx: *Gctx) !void {
        if (self.vertex_buffer) |old| Wgpu.wgpuBufferRelease(old);
        if (self.index_buffer) |old| Wgpu.wgpuBufferRelease(old);

        const vertices = self.cpu_vertices.items;
        const indices = self.cpu_indices.items;

        const vtx_size = @sizeOf(VertexAttribute) * vertices.len;
        self.vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = vtx_size,
            .usage = Wgpu.WGPUBufferUsage_Vertex | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        if (vtx_size > 0) {
            Wgpu.wgpuQueueWriteBuffer(gctx.queue, self.vertex_buffer, 0, vertices.ptr, vtx_size);
        }

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

pub const MaterialRegistry = struct {
    gctx: *Gctx,
    pipeline: *RenderPipeline,
    allocator: std.mem.Allocator,

    materials: [MAX_MATERIALS]?GlobalMaterial = [1]?GlobalMaterial{null} ** MAX_MATERIALS,
    active_materials: SparseIndexSet(MAX_MATERIALS),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, pipeline: *RenderPipeline) !Self {
        return .{
            .gctx = gctx,
            .pipeline = pipeline,
            .allocator = allocator,
            .active_materials = SparseIndexSet(MAX_MATERIALS).init(),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.active_materials.iterator();
        while (iter.next()) |key| {
            const id: u32 = @intCast(key);
            if (self.materials[id]) |*mat| {
                mat.deinit();
            }
        }
        self.active_materials.deinit(self.allocator);
    }

    pub fn acquire(self: *Self, key: MaterialKey) !*GlobalMaterial {
        const id = key.toId();
        if (self.materials[@intCast(id)] == null) {
            const global_mat = try self.loadGlobalMaterial(key);
            self.materials[@intCast(id)] = global_mat;
            self.active_materials.add(self.allocator, id);
        }
        var global_mat = &(self.materials[@intCast(id)].?);
        global_mat.ref_count += 1;
        return global_mat;
    }

    pub fn releaseById(self: *Self, id: MaterialIdx) void {
        if (self.materials[@intCast(id)]) |*mat| {
            std.debug.assert(mat.ref_count > 0);
            mat.ref_count -= 1;
        }
    }

    pub fn cleanupUnused(self: *Self) void {
        var iter = self.active_materials.iterator();
        while (iter.next()) |key| {
            const id: u32 = @intCast(key);
            if (self.materials[@intCast(id)]) |*mat| {
                if (mat.ref_count == 0) {
                    mat.deinit();
                    self.materials[@intCast(id)] = null;
                    _ = self.active_materials.remove(key);
                }
            }
        }
    }

    fn loadGlobalMaterial(self: *Self, key: MaterialKey) !GlobalMaterial {
        const block_id = key.block_id;
        const variant = key.variant;
        const block_info = block_id.prototype();

        const color_path = try self.buildTexturePath(block_info.name, variant, false);
        defer self.allocator.free(color_path);
        const normal_path = try self.buildTexturePath(block_info.name, variant, true);
        defer self.allocator.free(normal_path);

        var material = try Material.initDefault(self.gctx, self.pipeline);
        errdefer material.deinit();

        if (TextureRes.loadFromFile(self.allocator, self.gctx, color_path)) |color_tex| {
            material.setColorTexture(self.gctx, self.pipeline, color_tex);
        } else |_| {}

        if (TextureRes.loadFromFile(self.allocator, self.gctx, normal_path)) |normal_tex| {
            material.setNormalTexture(self.gctx, self.pipeline, normal_tex);
        } else |_| {}

        return .{ .material = material, .ref_count = 0 };
    }

    fn buildTexturePath(self: *Self, base_name: [:0]const u8, variant: u3, is_normal: bool) ![]u8 {
        const suffix = if (is_normal) "_n" else "";
        const full_path = try std.fmt.allocPrint(
            self.allocator,
            "resources/textures/{s}_{d}{s}.png",
            .{ base_name, variant, suffix },
        );
        return full_path;
    }
};

pub const ChunkMeshCache = struct {
    allocator: std.mem.Allocator,
    gctx: *Gctx,
    global_registry: *MaterialRegistry,

    meshes: std.AutoHashMap(MaterialIdx, ChunkMesh),

    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, global_registry: *MaterialRegistry) !ChunkMeshCache {
        var meshes = std.AutoHashMap(MaterialIdx, ChunkMesh).init(allocator);
        try meshes.ensureTotalCapacity(@intCast(MAX_MATERIALS));
        return .{
            .allocator = allocator,
            .gctx = gctx,
            .global_registry = global_registry,
            .meshes = meshes,
        };
    }

    pub fn deinit(self: *ChunkMeshCache) void {
        self.clear();
        self.meshes.deinit();
    }

    pub fn clear(self: *ChunkMeshCache) void {
        var it = self.meshes.iterator();
        while (it.next()) |entry| {
            const mat_idx = entry.key_ptr.*;
            entry.value_ptr.deinit(self.allocator);
            self.global_registry.releaseById(mat_idx);
        }
        self.meshes.clearRetainingCapacity();
    }

    pub fn getMesh(self: *ChunkMeshCache, mat_idx: MaterialIdx) !*ChunkMesh {
        const res = try self.meshes.getOrPut(mat_idx);
        if (!res.found_existing) {
            res.value_ptr.* = try ChunkMesh.init(self.gctx);
        }
        return res.value_ptr;
    }

    pub fn uploadAll(self: *ChunkMeshCache) !void {
        var it = self.meshes.valueIterator();
        while (it.next()) |mesh| {
            if (mesh.cpu_vertices.items.len > 0) {
                try mesh.uploadMeshData(self.gctx);
                mesh.clearMeshData();
            }
        }
    }
};

pub const MeshBuildResult = struct {
    origin: Vec3i,
    allocator: std.mem.Allocator,
    vertices: [MAX_MATERIALS]std.ArrayListUnmanaged(VertexAttribute) = [_]std.ArrayListUnmanaged(VertexAttribute){.{}} ** MAX_MATERIALS,
    indices: [MAX_MATERIALS]std.ArrayListUnmanaged(u32) = [_]std.ArrayListUnmanaged(u32){.{}} ** MAX_MATERIALS,

    pub fn deinit(self: *MeshBuildResult) void {
        for (0..MAX_MATERIALS) |i| {
            self.vertices[i].deinit(self.allocator);
            self.indices[i].deinit(self.allocator);
        }
    }
};

pub fn buildChunkMeshCPU(
    allocator: std.mem.Allocator,
    chunk_origin: Vec3i,
    chunk: *const Chunk,
    nb_west: ?*const Chunk,
    nb_east: ?*const Chunk,
    nb_north: ?*const Chunk,
    nb_south: ?*const Chunk,
) !MeshBuildResult {
    var result = MeshBuildResult{
        .origin = chunk_origin,
        .allocator = allocator,
    };
    errdefer result.deinit();

    for (0..CHUNK_SIZE_X) |x| {
        for (0..CHUNK_SIZE_Z) |z| {
            for (0..CHUNK_SIZE_Y) |y| {
                const block_state = chunk.blocks[x][y][z];
                const block_id = block_state.block_id;
                if (block_id == BlockId.fromName("air")) continue;
                const proto = block_id.prototype();

                const rot = if (proto.is_directional) block_state.facing.rotation() else Quat.identity;
                const inv_rot = if (proto.is_directional) block_state.facing.rotationInverse() else Quat.identity;

                const dirs = std.enums.values(Direction);
                for (dirs) |dir| {
                    const world_dir = dir;
                    const offset = dir.offset();
                    const nx = @as(i32, @intCast(x)) + offset.x;
                    const ny = @as(i32, @intCast(y)) + offset.y;
                    const nz = @as(i32, @intCast(z)) + offset.z;

                    var neighbor: BlockId = .fromName("air");
                    if (ny >= 0 and ny < CHUNK_SIZE_Y) {
                        if (nx >= 0 and nx < CHUNK_SIZE_X and
                            nz >= 0 and nz < CHUNK_SIZE_Z)
                        {
                            neighbor = chunk.blocks[@intCast(nx)][@intCast(ny)][@intCast(nz)].block_id;
                        } else {
                            const nb_chunk: ?*const Chunk = switch (world_dir) {
                                .west => nb_west,
                                .east => nb_east,
                                .north => nb_north,
                                .south => nb_south,
                                else => null,
                            };
                            if (nb_chunk) |nb| {
                                const wn_x = chunk_origin.x + nx;
                                const wn_z = chunk_origin.z + nz;
                                const nb_origin = BlockWorld.chunkOrigin(wn_x, wn_z);
                                const local_nx = wn_x - nb_origin.x;
                                const local_nz = wn_z - nb_origin.z;
                                if (local_nx >= 0 and local_nx < CHUNK_SIZE_X and
                                    local_nz >= 0 and local_nz < CHUNK_SIZE_Z)
                                {
                                    neighbor = nb.blocks[@intCast(local_nx)][@intCast(ny)][@intCast(local_nz)].block_id;
                                }
                            } else {
                                continue;
                            }
                        }
                    }

                    const neighbor_proto = neighbor.prototype();
                    if (neighbor_proto.occludes) continue;
                    if (!proto.occludes and block_id == neighbor and neighbor != BlockId.fromName("air")) continue;

                    const local_dir = if (proto.is_directional) blk: {
                        const world_vec = world_dir.normal();
                        const local_vec = inv_rot.rotate(world_vec);
                        break :blk directionFromVec(local_vec);
                    } else world_dir;

                    const face_index = @intFromEnum(local_dir);
                    const variant = proto.face_variants[face_index];
                    const mat_key = MaterialKey{ .block_id = block_id, .variant = variant };
                    const mat_idx = @as(usize, @intCast(mat_key.toId()));

                    const face_data = getStandardFaceData(local_dir);
                    const center = Vec3.new(
                        @as(f32, @floatFromInt(chunk_origin.x + @as(i32, @intCast(x)))) + 0.5,
                        @as(f32, @floatFromInt(chunk_origin.y + @as(i32, @intCast(y)))) + 0.5,
                        @as(f32, @floatFromInt(chunk_origin.z + @as(i32, @intCast(z)))) + 0.5,
                    );

                    const start_vertex: u32 = @intCast(result.vertices[mat_idx].items.len);
                    for (face_data.positions, face_data.uvs) |local_pos, uv| {
                        const world_pos = rot.rotate(local_pos).add(center);
                        const world_normal = rot.rotate(local_dir.normal());
                        try result.vertices[mat_idx].append(allocator, VertexAttribute{
                            .position = world_pos,
                            .normal = world_normal,
                            .texcoord = uv,
                            .tangent = Vec4.new(1, 0, 0, 1),
                            .color = Vec4.new(1, 1, 1, 1),
                            .joint_indices = .{ 0, 0, 0, 0 },
                            .joint_weights = .{ 1, 0, 0, 0 },
                        });
                    }
                    try result.indices[mat_idx].appendSlice(allocator, &[_]u32{
                        start_vertex, start_vertex + 2, start_vertex + 1,
                        start_vertex, start_vertex + 3, start_vertex + 2,
                    });
                }
            }
        }
    }

    return result;
}

pub fn applyMeshResult(
    cache: *ChunkMeshCache,
    result: *MeshBuildResult,
) !void {
    cache.clear();

    for (0..MAX_MATERIALS) |mat_idx_usize| {
        const mat_idx: MaterialIdx = @intCast(mat_idx_usize);
        const verts = result.vertices[mat_idx_usize].items;
        if (verts.len == 0) continue;

        const mat_key = MaterialKey.fromId(mat_idx);
        _ = try cache.global_registry.acquire(mat_key);

        const mesh = try cache.getMesh(mat_idx);
        try mesh.cpu_vertices.appendSlice(cache.allocator, verts);
        try mesh.cpu_indices.appendSlice(cache.allocator, result.indices[mat_idx_usize].items);
    }

    try cache.uploadAll();
}

pub const Direction = enum(u3) {
    up,
    down,
    north,
    south,
    west,
    east,

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

    pub fn offset(self: Direction) Vec3i {
        return self.normal().toVec3iFloor();
    }
    pub fn rotation(self: Direction) Quat {
        return switch (self) {
            .up => Quat.identity,
            .down => Quat.fromAxisAngle(Vec3.new(1, 0, 0), std.math.pi),
            .north => Quat.fromAxisAngle(Vec3.new(1, 0, 0), -std.math.pi / 2.0),
            .south => Quat.fromAxisAngle(Vec3.new(1, 0, 0), std.math.pi / 2.0),
            .west => Quat.fromAxisAngle(Vec3.new(0, 0, 1), -std.math.pi / 2.0),
            .east => Quat.fromAxisAngle(Vec3.new(0, 0, 1), std.math.pi / 2.0),
        };
    }

    pub fn rotationInverse(self: Direction) Quat {
        return switch (self) {
            .up => Quat.identity,
            .down => Quat.fromAxisAngle(Vec3.new(1, 0, 0), -std.math.pi),
            .north => Quat.fromAxisAngle(Vec3.new(1, 0, 0), std.math.pi / 2.0),
            .south => Quat.fromAxisAngle(Vec3.new(1, 0, 0), -std.math.pi / 2.0),
            .west => Quat.fromAxisAngle(Vec3.new(0, 0, 1), std.math.pi / 2.0),
            .east => Quat.fromAxisAngle(Vec3.new(0, 0, 1), -std.math.pi / 2.0),
        };
    }
};

pub const BlockState = struct {
    block_id: BlockId = BlockId.fromName("air"),
    facing: Direction = .up,
    durability: u32 = 10,
    pub fn init(block_id: BlockId) BlockState {
        return .{
            .block_id = block_id,
            .facing = .up,
            .durability = block_id.prototype().durability,
        };
    }
};

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

const DEFAULT_UVS = [4]Vec2{
    Vec2.new(0, 1), Vec2.new(1, 1), Vec2.new(1, 0), Vec2.new(0, 0),
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
            .uvs = DEFAULT_UVS,
        },
        .down => FaceData{
            .positions = .{
                Vec3.new(-h, -h, h),
                Vec3.new(h, -h, h),
                Vec3.new(h, -h, -h),
                Vec3.new(-h, -h, -h),
            },
            .uvs = .{ Vec2.new(0, 0), Vec2.new(1, 0), Vec2.new(1, 1), Vec2.new(0, 1) },
        },
        .north => FaceData{
            .positions = .{
                Vec3.new(-h, -h, -h),
                Vec3.new(h, -h, -h),
                Vec3.new(h, h, -h),
                Vec3.new(-h, h, -h),
            },
            .uvs = DEFAULT_UVS,
        },
        .south => FaceData{
            .positions = .{
                Vec3.new(h, -h, h),
                Vec3.new(-h, -h, h),
                Vec3.new(-h, h, h),
                Vec3.new(h, h, h),
            },
            .uvs = .{ Vec2.new(1, 1), Vec2.new(0, 1), Vec2.new(0, 0), Vec2.new(1, 0) },
        },
        .east => FaceData{
            .positions = .{
                Vec3.new(h, -h, -h),
                Vec3.new(h, -h, h),
                Vec3.new(h, h, h),
                Vec3.new(h, h, -h),
            },
            .uvs = DEFAULT_UVS,
        },
        .west => FaceData{
            .positions = .{
                Vec3.new(-h, -h, h),
                Vec3.new(-h, -h, -h),
                Vec3.new(-h, h, -h),
                Vec3.new(-h, h, h),
            },
            .uvs = DEFAULT_UVS,
        },
    };
}

/// 物理常量（可调整）
const GRAVITY: f32 = 25.0;
const FLUID_GRAVITY: f32 = 5.0;
const SWIM_UP_SPEED: f32 = 5.0;
const SWIM_DOWN_SPEED: f32 = 3.0;
const SINK_TERMINAL: f32 = -2.0;
const GROUND_FRICTION: f32 = 0.6;
const AIR_FRICTION: f32 = 4.0;
const ACCELERATION: f32 = 30.0;
const PHYS_EPS = 1e-6;

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

    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, pipeline: *RenderPipeline, max_chunks: usize) !BlockWorld {
        var material_registry = try MaterialRegistry.init(allocator, gctx, pipeline);
        errdefer material_registry.deinit();

        var chunks = std.AutoHashMap(Vec3i, LoadedChunk).init(allocator);
        errdefer chunks.deinit();
        try chunks.ensureTotalCapacity(@intCast(max_chunks));

        var pending = std.AutoHashMap(Vec3i, void).init(allocator);
        errdefer pending.deinit();

        return BlockWorld{
            .allocator = allocator,
            .gctx = gctx,
            .pipeline = pipeline,
            .material_registry = material_registry,
            .chunks = chunks,
            .pending = pending,
            .completed = .{},
            .worker_gpa = .{},
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

pub const AABB = struct {
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,

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
            if (box_max + move_dist > block_min) {
                const max_allowed = block_min - box_max;
                if (max_allowed < 0) {
                    return move_dist;
                }
                return @min(move_dist, max_allowed - PHYS_EPS);
            }
        } else if (move_dist < 0.0) {
            if (box_min + move_dist < block_max) {
                const min_allowed = block_max - box_min;
                if (min_allowed > 0) {
                    return move_dist;
                }
                return @max(move_dist, min_allowed + PHYS_EPS);
            }
        }
        return move_dist;
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
