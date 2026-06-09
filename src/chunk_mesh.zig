// chunk_mesh.zig
const std = @import("std");
const Imports = @import("imports.zig");
const Vec2 = Imports.Vec2;
const Vec3 = Imports.Vec3;
const Vec3i = Imports.Vec3i;
const Quat = Imports.Quat;
const Wgpu = Imports.Wgpu;
const Material = Imports.RendCTX.Material;
const TextureRes = Imports.RendCTX.TextureRes;
const Gctx = Imports.Gctx;
const RenderPipeline = @import("render_pipeline.zig");
const StaticVertex = Imports.RendCTX.StaticVertex;
const SparseIndexSet = @import("sparse_set.zig").SparseIndexSet;
const BlockRegistry = @import("block_registry.zig");
const BlockId = BlockRegistry.BlockId;
const block_infos = BlockRegistry.block_infos;
const Direction = @import("direction.zig").Direction;
const directionFromVec = @import("direction.zig").directionFromVec;
const FaceData = @import("direction.zig").FaceData;
const getStandardFaceData = @import("direction.zig").getStandardFaceData;
const Chunk = @import("block_world.zig").Chunk;
const BlockWorld = @import("block_world.zig").BlockWorld;
const CHUNK_WIDTH = @import("block_world.zig").CHUNK_WIDTH;
const CHUNK_HEIGHT = @import("block_world.zig").CHUNK_HEIGHT;

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

pub const MAX_MATERIALS = block_infos.len * MAX_VARIANTS;
pub const MaterialIdx = u32;

pub const GlobalMaterial = struct {
    material: Material,
    ref_count: u32 = 0,

    pub fn deinit(self: *GlobalMaterial) void {
        self.material.deinit();
    }
};

pub const ChunkMesh = struct {
    /// GPU 端顶点/索引缓冲区 + CPU 端待上传数据。
    /// 一个 ChunkMesh 对应一种材质。
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    vertex_count: u32,
    index_count: u32,

    cpu_vertices: std.ArrayListUnmanaged(StaticVertex) = .{},
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

    pub fn clearCpuData(self: *ChunkMesh, allocator: std.mem.Allocator) void {
        self.cpu_vertices.clearAndFree(allocator);
        self.cpu_indices.clearAndFree(allocator);
    }

    pub fn uploadMeshData(self: *ChunkMesh, gctx: *Gctx) !void {
        if (self.vertex_buffer) |old| Wgpu.wgpuBufferRelease(old);
        if (self.index_buffer) |old| Wgpu.wgpuBufferRelease(old);

        const vertices = self.cpu_vertices.items;
        const indices = self.cpu_indices.items;

        const vtx_size = @sizeOf(StaticVertex) * vertices.len;
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

    /// 获取或加载全局材质，增加引用计数。必须在主线程调用。
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
            "resources/textures/blocks/{s}_{d}{s}.png",
            .{ base_name, variant, suffix },
        );
        return full_path;
    }
};

pub const MeshBuildResult = struct {
    origin: Vec3i,
    allocator: std.mem.Allocator,
    vertices: [MAX_MATERIALS]std.ArrayListUnmanaged(StaticVertex) = [_]std.ArrayListUnmanaged(StaticVertex){.{}} ** MAX_MATERIALS,
    indices: [MAX_MATERIALS]std.ArrayListUnmanaged(u32) = [_]std.ArrayListUnmanaged(u32){.{}} ** MAX_MATERIALS,

    pub fn deinit(self: *MeshBuildResult) void {
        for (0..MAX_MATERIALS) |i| {
            self.vertices[i].deinit(self.allocator);
            self.indices[i].deinit(self.allocator);
        }
    }
};

/// 在 worker 线程中运行：遍历方块生成 CPU 侧顶点/索引数据。
/// 不接触 GPU 和材质引用计数。邻居区块通过指针传入以支持跨区块面剔除。
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

    for (0..CHUNK_WIDTH) |x| {
        for (0..CHUNK_WIDTH) |z| {
            for (0..CHUNK_HEIGHT) |y| {
                const block_state = chunk.getBlock(@intCast(x), @intCast(y), @intCast(z));
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
                    if (ny >= 0 and ny < CHUNK_HEIGHT) {
                        if (nx >= 0 and nx < CHUNK_WIDTH and
                            nz >= 0 and nz < CHUNK_WIDTH)
                        {
                            neighbor = chunk.getBlockId(@intCast(nx), @intCast(ny), @intCast(nz));
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
                                if (local_nx >= 0 and local_nx < CHUNK_WIDTH and
                                    local_nz >= 0 and local_nz < CHUNK_WIDTH)
                                {
                                    neighbor = nb.getBlockId(@intCast(local_nx), @intCast(ny), @intCast(local_nz));
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
                        try result.vertices[mat_idx].append(allocator, StaticVertex{
                            .position = world_pos,
                            .normal = world_normal,
                            .texcoord = uv,
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

/// 在主线程调用：释放旧网格，acquire 材质，写入新顶点/索引到 Chunk 的 meshes HashMap，上传 GPU。
pub fn applyMeshResult(
    meshes: *std.AutoHashMap(MaterialIdx, ChunkMesh),
    allocator: std.mem.Allocator,
    gctx: *Gctx,
    global_registry: *MaterialRegistry,
    result: *MeshBuildResult,
) !void {
    // 释放旧网格
    {
        var it = meshes.iterator();
        while (it.next()) |entry| {
            const mat_idx = entry.key_ptr.*;
            entry.value_ptr.deinit(allocator);
            global_registry.releaseById(mat_idx);
        }
        meshes.clearRetainingCapacity();
    }

    for (0..MAX_MATERIALS) |mat_idx_usize| {
        const mat_idx: MaterialIdx = @intCast(mat_idx_usize);
        const verts = result.vertices[mat_idx_usize].items;
        if (verts.len == 0) continue;

        const mat_key = MaterialKey.fromId(mat_idx);
        _ = try global_registry.acquire(mat_key);

        const mesh_entry = try meshes.getOrPut(mat_idx);
        if (!mesh_entry.found_existing) {
            mesh_entry.value_ptr.* = try ChunkMesh.init(gctx);
        }
        try mesh_entry.value_ptr.cpu_vertices.appendSlice(allocator, verts);
        try mesh_entry.value_ptr.cpu_indices.appendSlice(allocator, result.indices[mat_idx_usize].items);
    }

    // 上传所有非空材质网格到 GPU，上传后清空 CPU 暂存
    {
        var it = meshes.valueIterator();
        while (it.next()) |mesh| {
            if (mesh.cpu_vertices.items.len > 0) {
                try mesh.uploadMeshData(gctx);
                mesh.clearCpuData(allocator);
            }
        }
    }
}
