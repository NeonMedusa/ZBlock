const std = @import("std");
const Imports = @import("imports.zig");
const Vec3 = Imports.Vec3;
const Vec3i = Imports.Vec3i;
const Vec3u = Imports.Vec3u;
const Wgpu = Imports.Wgpu;
const Material = Imports.RendCTX.Material;
const MaterialConstants = Imports.RendCTX.MaterialConstants;
const TextureRes = Imports.RendCTX.TextureRes;
const Gctx = Imports.Gctx;
const RenderPipeline = @import("render_pipeline.zig");
const IMG = Imports.zigimg;

/// 方块类型唯一标识符
pub const BlockID = enum(u32) {
    air,
    grass,
    stone,
    dirt,
    sand,
    water,
};

/// 材质资源标识符（对应 MaterialRegistry 中的材质实例）
pub const MaterialID = enum(u32) {
    none,
    grass_side,
    grass_top,
    grass_bottom,
    stone,
    dirt,
    sand,
    water,
};

/// 方块朝向（六面）
pub const Face = enum(u3) {
    front = 0,
    back = 1,
    left = 2,
    right = 3,
    top = 4,
    bottom = 5,
};

/// 描述一种方块类型的静态属性（物理、渲染、名称等）
pub const BlockType = struct {
    id: BlockID,
    name: []const u8,
    /// 六个面分别对应的材质ID
    materials: [6]MaterialID,
    /// 不透明度：0.0 = 完全透明，1.0 = 完全不透明
    opacity: f32,
    /// 坚实度：1.0 = 完全固体（可站立、有碰撞），<1.0 为流体或软物质
    solidity: f32,
    /// 光滑度：影响移动惯性（如冰面）
    slipperiness: f32 = 0.6,
    /// 是否可视为固体（用于碰撞检测）
    pub fn isSolid(self: BlockType) bool {
        return self.solidity >= 0.9;
    }
};

/// 描述一种方块类型的静态属性（物理、渲染、名称等）
pub const BlockTypeV2 = struct {
    id: BlockID,
    name: []const u8,
    materials: [6]u3, //000000表示六个面全部应用名为@tagName(id)_0.png的纹理，020000表示第二个面应用名为@tagName(id)_2.png的纹理
    /// 不透明度：0.0 = 完全透明，1.0 = 完全不透明
    opacity: f32,
    /// 坚实度：1.0 = 完全固体（可站立、有碰撞），<1.0 为流体或软物质
    solidity: f32,
    /// 光滑度：影响移动惯性（如冰面）
    slipperiness: f32 = 0.6,
    /// 是否可视为固体（用于碰撞检测）
    pub fn isSolid(self: BlockType) bool {
        return self.solidity >= 0.9;
    }
};

/// 方块类型注册表（全局静态数据）
pub const BlockRegistry = struct {
    types: std.EnumArray(BlockID, BlockType),
    /// 初始化所有方块类型定义
    pub fn init(allocator: std.mem.Allocator) !BlockRegistry {
        _ = allocator;
        var self = BlockRegistry{ .types = undefined };
        self.types.set(.air, .{
            .id = .air,
            .name = "air",
            .materials = [1]MaterialID{.none} ** 6,
            .opacity = 0.0,
            .solidity = 0.0,
            .slipperiness = 0.0,
        });
        self.types.set(.grass, .{
            .id = .grass,
            .name = "grass",
            .materials = .{
                .grass_side, .grass_side, .grass_side,
                .grass_side, .grass_top,  .grass_bottom,
            },
            .opacity = 1.0,
            .solidity = 1.0,
        });
        self.types.set(.stone, .{
            .id = .stone,
            .name = "stone",
            .materials = [_]MaterialID{.stone} ** 6,
            .opacity = 1.0,
            .solidity = 1.0,
        });
        self.types.set(.dirt, .{
            .id = .dirt,
            .name = "dirt",
            .materials = [_]MaterialID{.dirt} ** 6,
            .opacity = 1.0,
            .solidity = 1.0,
        });
        self.types.set(.sand, .{
            .id = .sand,
            .name = "sand",
            .materials = [_]MaterialID{.sand} ** 6,
            .opacity = 1.0,
            .solidity = 1.0,
        });
        self.types.set(.water, .{
            .id = .water,
            .name = "water",
            .materials = [_]MaterialID{.water} ** 6,
            .opacity = 0.5,
            .solidity = 0.3,
            .slipperiness = 0.9,
        });
        return self;
    }
    /// 根据 BlockID 获取对应的 BlockType
    pub fn getType(self: BlockRegistry, id: BlockID) BlockType {
        return self.types.get(id);
    }
};

/// 材质资源管理器
pub const MaterialRegistry = struct {
    materials: std.EnumArray(MaterialID, ?Material),
    ref_counts: std.EnumArray(MaterialID, u32),
    gctx: *Gctx,
    pipeline: *RenderPipeline,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, pipeline: *RenderPipeline) MaterialRegistry {
        return .{
            .materials = std.EnumArray(MaterialID, ?Material).initDefault(undefined, null),
            .ref_counts = std.EnumArray(MaterialID, u32).initDefault(undefined, 0),
            .gctx = gctx,
            .pipeline = pipeline,
            .allocator = allocator,
        };
    }

    /// 获取或加载材质，同时增加引用计数。
    pub fn getOrLoadMaterial(self: *MaterialRegistry, id: MaterialID) !*Material {
        if (id == .none) return error.InvalidMaterial;
        // 增加引用计数
        const cnt = &self.ref_counts.getPtr(id);
        cnt.* += 1;
        // 如果材质尚未加载，则加载它
        if (self.materials.get(id) == null)
            try self.loadMaterial(id);
        return &self.materials.get(id).?;
    }

    /// 重置所有引用计数（每帧开始时调用）
    pub fn resetRefCounts(self: *MaterialRegistry) void {
        for (self.ref_counts.values()) |*cnt|
            cnt.* = 0;
    }

    /// 卸载引用计数为 0 的材质（每帧结束时调用）
    pub fn removeZeroRefMaterials(self: *MaterialRegistry) void {
        const ids = std.enums.values(MaterialID);
        for (ids) |id| {
            if (id == .none) continue;
            if (self.ref_counts.get(id) == 0) {
                if (self.materials.get(id)) |*mat| {
                    // 释放颜色纹理
                    if (mat.color_texture.texture) |tex|
                        Wgpu.wgpuTextureRelease(tex);
                    if (mat.color_texture.view) |view|
                        Wgpu.wgpuTextureViewRelease(view);
                    // 释放法线纹理
                    if (mat.normal_texture.texture) |tex|
                        Wgpu.wgpuTextureRelease(tex);
                    if (mat.normal_texture.view) |view|
                        Wgpu.wgpuTextureViewRelease(view);
                    // 释放 uniform buffer
                    Wgpu.wgpuBufferRelease(mat.uniform_buffer);
                    // 释放 bind group
                    Wgpu.wgpuBindGroupRelease(mat.bind_group);
                    self.materials.set(id, null);
                }
            }
        }
    }

    /// 获取材质的绑定组（调用前需保证材质已加载）
    pub fn getBindGroup(self: MaterialRegistry, id: MaterialID) *Wgpu.BindGroup {
        return self.materials.get(id).?.bind_group;
    }

    fn loadMaterial(self: *MaterialRegistry, id: MaterialID) !void {
        // 1. 创建默认材质（颜色和法线均为占位纹理）
        const mat = try Imports.RendCTX.createDefaultMaterial(self.gctx, self.pipeline);
        errdefer mat.deinit(self.gctx); // 如果后续出错，释放已创建的默认材质

        // 2. 根据枚举名构建文件路径
        const name = @tagName(id);
        const color_file_name = try std.fmt.allocPrint(self.allocator, "{s}.png", .{name});
        defer self.allocator.free(color_file_name);
        const color_path = try std.fs.path.join(self.allocator, &.{ "resources", "textures", color_file_name });
        defer self.allocator.free(color_path);

        const normal_file_name = try std.fmt.allocPrint(self.allocator, "{s}_n.png", .{name});
        defer self.allocator.free(normal_file_name);
        const normal_path = try std.fs.path.join(self.allocator, &.{ "resources", "textures", normal_file_name });
        defer self.allocator.free(normal_path);

        // 3. 尝试加载颜色纹理（失败则保留默认纹理）
        if (loadTextureFromFile(self.allocator, self.gctx, color_path)) |color_tex| {
            // 替换默认纹理：先释放旧的，再赋新值
            if (mat.color_texture.texture) |old_tex| Wgpu.wgpuTextureRelease(old_tex);
            if (mat.color_texture.view) |old_view| Wgpu.wgpuTextureViewRelease(old_view);
            mat.color_texture = .{ .texture = color_tex.texture, .view = color_tex.view };
            // 更新材质常量，标记有颜色纹理
            var constants = MaterialConstants{ .has_base_color = 1, .has_normal = 0 };
            // 需要读取当前 uniform buffer 的内容？直接重新写入
            Wgpu.wgpuQueueWriteBuffer(
                self.gctx.queue,
                mat.uniform_buffer,
                0,
                &constants,
                @sizeOf(MaterialConstants),
            );
        }

        // 4. 尝试加载法线纹理（失败则标记has_normal = 0）
        if (loadTextureFromFile(self.allocator, self.gctx, normal_path)) |normal_tex| {
            if (mat.normal_texture.texture) |old_tex| Wgpu.wgpuTextureRelease(old_tex);
            if (mat.normal_texture.view) |old_view| Wgpu.wgpuTextureViewRelease(old_view);
            mat.normal_texture = .{ .texture = normal_tex.texture, .view = normal_tex.view };
            // 更新材质常量，注意保留颜色标志位
            var constants = MaterialConstants{ .has_base_color = 1, .has_normal = 1 };
            if (mat.color_texture.texture == null) constants.has_base_color = 0; // 如果颜色纹理也没加载成功
            Wgpu.wgpuQueueWriteBuffer(
                self.gctx.queue,
                mat.uniform_buffer,
                0,
                &constants,
                @sizeOf(MaterialConstants),
            );
        }

        // 5. 重新创建绑定组（因为纹理可能已改变）
        if (mat.bind_group) |old_bg| Wgpu.wgpuBindGroupRelease(old_bg);
        mat.bind_group = Wgpu.wgpuDeviceCreateBindGroup(self.gctx.device, &Wgpu.WGPUBindGroupDescriptor{
            .layout = self.pipeline.material_bgl,
            .entryCount = 3,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{
                    .binding = 0,
                    .buffer = mat.uniform_buffer,
                    .size = Wgpu.wgpuBufferGetSize(mat.uniform_buffer),
                },
                .{
                    .binding = 1,
                    .textureView = mat.color_texture.view orelse null,
                },
                .{
                    .binding = 2,
                    .textureView = mat.normal_texture.view orelse null,
                },
            },
        });

        // 6. 存入注册表
        self.materials.set(id, mat);
    }
};

// 区块数据结构
pub const CHUNK_SIZE_X: u32 = 16;
pub const CHUNK_SIZE_Y: u32 = 512;
pub const CHUNK_SIZE_Z: u32 = 16;
pub const ChunkSize = Vec3u{
    .x = CHUNK_SIZE_X,
    .y = CHUNK_SIZE_Y,
    .z = CHUNK_SIZE_Z,
};

/// 存储一个区块的方块数据
pub const Chunk = struct {
    // 使用 [y][x][z] 布局，便于垂直遍历（y 轴为主序）
    blocks: [CHUNK_SIZE_Y][CHUNK_SIZE_X][CHUNK_SIZE_Z]BlockID,
    /// 获取指定局部坐标的方块ID
    pub fn getBlock(self: *Chunk, pos: Vec3u) BlockID {
        return self.blocks[pos.y][pos.x][pos.z];
    }
    /// 设置指定局部坐标的方块ID
    pub fn setBlock(self: *Chunk, pos: Vec3u, id: BlockID) void {
        self.blocks[pos.y][pos.x][pos.z] = id;
    }
};

/// 将世界坐标转换为区块坐标（区块索引）
pub fn worldToChunkPos(world_pos: Vec3i) Vec3i {
    return .{
        .x = @divFloor(world_pos.x, CHUNK_SIZE_X),
        .y = @divFloor(world_pos.y, CHUNK_SIZE_Y),
        .z = @divFloor(world_pos.z, CHUNK_SIZE_Z),
    };
}

/// 将世界坐标转换为区块内的局部坐标（非负）
pub fn worldToChunkLocal(world_pos: Vec3i) Vec3u {
    return .{
        .x = @intCast(@mod(world_pos.x, CHUNK_SIZE_X)),
        .y = @intCast(@mod(world_pos.y, CHUNK_SIZE_Y)),
        .z = @intCast(@mod(world_pos.z, CHUNK_SIZE_Z)),
    };
}

pub fn loadTextureFromFile(allocator: std.mem.Allocator, gctx: *Gctx, file_path: []const u8) !TextureRes {
    // 读取文件
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const file_size = try file.getEndPos();
    const file_data = try allocator.alloc(u8, file_size);
    defer allocator.free(file_data);
    _ = try file.readAll(file_data);
    // 用 ZigImg 解码
    var img = try IMG.Image.fromMemory(allocator, file_data);
    defer img.deinit(allocator);
    if (img.pixels != .rgba32) try img.convert(allocator, .rgba32);
    // 创建 WGPU 纹理
    const texture_desc = Wgpu.WGPUTextureDescriptor{
        .usage = Wgpu.WGPUTextureUsage_CopyDst | Wgpu.WGPUTextureUsage_TextureBinding,
        .dimension = Wgpu.WGPUTextureDimension_2D,
        .size = .{
            .width = @intCast(img.width),
            .height = @intCast(img.height),
            .depthOrArrayLayers = 1,
        },
        .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
    };
    const texture = Wgpu.wgpuDeviceCreateTexture(gctx.device, &texture_desc);
    Wgpu.wgpuQueueWriteTexture(
        gctx.queue,
        &Wgpu.WGPUTexelCopyTextureInfo{ .texture = texture, .mipLevel = 0 },
        img.pixels.rgba32.ptr,
        img.pixels.rgba32.len * @sizeOf(IMG.color.Rgba32),
        &Wgpu.WGPUTexelCopyBufferLayout{
            .offset = 0,
            .bytesPerRow = @intCast(img.width * 4),
            .rowsPerImage = @intCast(img.height),
        },
        &Wgpu.WGPUExtent3D{
            .width = @intCast(img.width),
            .height = @intCast(img.height),
            .depthOrArrayLayers = 1,
        },
    );
    const texture_view = Wgpu.wgpuTextureCreateView(
        texture,
        &Wgpu.WGPUTextureViewDescriptor{
            .aspect = Wgpu.WGPUTextureAspect_All,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .dimension = Wgpu.WGPUTextureViewDimension_2D,
            .format = texture_desc.format,
        },
    );
    return .{ .texture = texture, .view = texture_view };
}
