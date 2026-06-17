const io = @import("imports.zig").io;
const Mesh = struct {
    primitives: []Primitive,
};

pub const Primitive = struct {
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    index_count: u32,
    material: Material, // 设计为不可为空，因为Wgpu.WGPUTexture和Wgpu.WGPUTextureView是可空类型
};

pub const MaterialConstants = struct {
    has_base_color: u32 = 0,
    has_normal: u32 = 0,
    _padding: [2]f32 = undefined,
};

pub const TextureRes = struct {
    texture: Wgpu.WGPUTexture,
    view: Wgpu.WGPUTextureView,
    /// 创建一个 1x1 白色默认纹理（常用于占位）
    pub fn createDefault(gctx: *Gctx) !TextureRes {
        const pixels = [_]u8{ 255, 255, 255, 255 };
        return createFromPixels(gctx, 1, 1, &pixels);
    }
    /// 从原始像素数据创建纹理（RGBA8 格式）
    pub fn createFromPixels(gctx: *Gctx, width: u32, height: u32, pixels: []const u8) !TextureRes {
        std.debug.assert(pixels.len == width * height * 4);
        const texture_desc = Wgpu.WGPUTextureDescriptor{
            .usage = Wgpu.WGPUTextureUsage_CopyDst | Wgpu.WGPUTextureUsage_TextureBinding,
            .dimension = Wgpu.WGPUTextureDimension_2D,
            .size = .{
                .width = width,
                .height = height,
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
            pixels.ptr,
            pixels.len,
            &Wgpu.WGPUTexelCopyBufferLayout{
                .offset = 0,
                .bytesPerRow = width * 4,
                .rowsPerImage = height,
            },
            &Wgpu.WGPUExtent3D{
                .width = width,
                .height = height,
                .depthOrArrayLayers = 1,
            },
        );

        const view = Wgpu.wgpuTextureCreateView(texture, &Wgpu.WGPUTextureViewDescriptor{
            .aspect = Wgpu.WGPUTextureAspect_All,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .dimension = Wgpu.WGPUTextureViewDimension_2D,
            .format = texture_desc.format,
        });

        return .{ .texture = texture, .view = view };
    }
    /// 从内存中的图像数据加载（支持 PNG、JPG 等格式）
    pub fn loadFromMemory(allocator: std.mem.Allocator, gctx: *Gctx, data: []const u8) !TextureRes {
        var img = try zigimg.Image.fromMemory(allocator, data);
        defer img.deinit(allocator);

        if (img.pixels != .rgba32) try img.convert(allocator, .rgba32);

        const rgba = img.pixels.rgba32;
        const pixels = std.mem.sliceAsBytes(rgba);

        const width: u32 = @intCast(img.width);
        const height: u32 = @intCast(img.height);

        return createFromPixels(gctx, width, height, pixels);
    }
    /// 从文件路径加载纹理
    pub fn loadFromFile(allocator: std.mem.Allocator, gctx: *Gctx, path: []const u8) !TextureRes {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        const file_size = try file.length(io);
        const data = try allocator.alloc(u8, file_size);
        defer allocator.free(data);
        const n2 = try file.readStreaming(io, &.{data});
        _ = n2;

        return loadFromMemory(allocator, gctx, data);
    }
    /// 释放 GPU 资源
    pub fn deinit(self: *TextureRes) void {
        if (self.view) |v| Wgpu.wgpuTextureViewRelease(v);
        if (self.texture) |t| Wgpu.wgpuTextureRelease(t);
    }
};

pub const Material = struct {
    color_texture: TextureRes,
    normal_texture: TextureRes,
    uniform_buffer: Wgpu.WGPUBuffer,
    bind_group: Wgpu.WGPUBindGroup,
    constants: MaterialConstants,
    /// 创建默认材质（为 color 和 normal 分别创建独立的 1x1 白色纹理）
    pub fn initDefault(gctx: *Gctx, pipeline: *RenderPipeline) !Material {
        const default_color = try TextureRes.createDefault(gctx);
        errdefer default_color.deinit();
        const default_normal = try TextureRes.createDefault(gctx);
        errdefer default_normal.deinit();

        const constants = MaterialConstants{
            .has_base_color = 0,
            .has_normal = 0,
            ._padding = undefined,
        };

        const uniform_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(MaterialConstants),
            .usage = Wgpu.WGPUBufferUsage_Uniform | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        errdefer Wgpu.wgpuBufferRelease(uniform_buffer);
        Wgpu.wgpuQueueWriteBuffer(gctx.queue, uniform_buffer, 0, &constants, @sizeOf(MaterialConstants));

        const bind_group = Wgpu.wgpuDeviceCreateBindGroup(gctx.device, &.{
            .layout = pipeline.material_bgl,
            .entryCount = 3,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ .binding = 0, .buffer = uniform_buffer, .size = Wgpu.wgpuBufferGetSize(uniform_buffer) },
                .{ .binding = 1, .textureView = default_color.view },
                .{ .binding = 2, .textureView = default_normal.view },
            },
        });
        errdefer Wgpu.wgpuBindGroupRelease(bind_group);

        return .{
            .color_texture = default_color,
            .normal_texture = default_normal,
            .uniform_buffer = uniform_buffer,
            .bind_group = bind_group,
            .constants = constants,
        };
    }
    /// 释放材质拥有的所有 GPU 资源（包括纹理）
    pub fn deinit(self: *Material) void {
        self.color_texture.deinit();
        self.normal_texture.deinit();
        Wgpu.wgpuBufferRelease(self.uniform_buffer);
        Wgpu.wgpuBindGroupRelease(self.bind_group);
        self.* = undefined;
    }
    /// 替换颜色纹理（旧纹理会自动释放）
    pub fn setColorTexture(self: *Material, gctx: *Gctx, pipeline: *RenderPipeline, new_tex: TextureRes) void {
        self.color_texture.deinit();
        self.color_texture = new_tex;
        self.constants.has_base_color = 1;
        self.syncUniformBuffer(gctx);
        self.rebuildBindGroup(gctx, pipeline);
    }
    /// 替换法线纹理（旧纹理会自动释放）
    pub fn setNormalTexture(self: *Material, gctx: *Gctx, pipeline: *RenderPipeline, new_tex: TextureRes) void {
        self.normal_texture.deinit();
        self.normal_texture = new_tex;
        self.constants.has_normal = 1;
        self.syncUniformBuffer(gctx);
        self.rebuildBindGroup(gctx, pipeline);
    }
    /// 更新材质常量缓冲区
    fn syncUniformBuffer(self: *Material, gctx: *Gctx) void {
        Wgpu.wgpuQueueWriteBuffer(
            gctx.queue,
            self.uniform_buffer,
            0,
            &self.constants,
            @sizeOf(MaterialConstants),
        );
    }
    /// 重建绑定组（当绑定的纹理或 buffer 改变时调用）
    fn rebuildBindGroup(self: *Material, gctx: *Gctx, pipeline: *RenderPipeline) void {
        if (self.bind_group) |old| Wgpu.wgpuBindGroupRelease(old);
        self.bind_group = Wgpu.wgpuDeviceCreateBindGroup(gctx.device, &.{
            .layout = pipeline.material_bgl,
            .entryCount = 3,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ .binding = 0, .buffer = self.uniform_buffer, .size = Wgpu.wgpuBufferGetSize(self.uniform_buffer) },
                .{ .binding = 1, .textureView = self.color_texture.view },
                .{ .binding = 2, .textureView = self.normal_texture.view },
            },
        });
    }
};

const Node = struct {
    parent: ?usize,
    matrix: Mat4,
    mesh: ?usize,
};

pub const Interpolation = enum { linear, step, cubic };

pub const AnimChannel = struct {
    joint_index: u32,
    interpolation: Interpolation,
    property: TargetProperty,
    times: []f32,
    values: []f32,
    stride: u32,
};

pub const TargetProperty = enum { translation, rotation, scale };

pub const AnimClip = struct {
    name: []const u8,
    duration: f32,
    channels: []AnimChannel,
};

pub const ClipName = struct {
    pub const idle = "idle";
    pub const walk = "walk";
    pub const run = "run";
    pub const death = "death";
    pub const attack = "attack";
};

pub const Skeleton = struct {
    joint_count: u32,
    inverse_bind_matrices: []Mat4,
    parent_indices: []i32,
};

pub const MAX_BONES: u32 = 128;
pub const MAX_ANIM_ENTITIES: u32 = 1000;
pub const TOTAL_BONES: usize = MAX_ANIM_ENTITIES * MAX_BONES;

pub const ModelInfo = struct {
    name: [:0]const u8,
    path: [:0]const u8,
};

const model_infos = [_]ModelInfo{
    .{ .name = "foo", .path = "resources/models/foo.glb" },
    .{ .name = "CesiumMan", .path = "resources/models/CesiumMan.glb" },
    .{ .name = "Wolf", .path = "resources/models/Wolf.glb" },
    .{ .name = "Buggy", .path = "resources/models/Buggy.glb" },
    .{ .name = "BarramundiFish", .path = "resources/models/BarramundiFish.glb" },
    .{ .name = "Avocado", .path = "resources/models/Avocado.glb" },
};

pub const MAX_MODELS = model_infos.len;

pub const ModelId = packed struct(u32) {
    id: u32,
    pub fn fromInt(i: anytype) ModelId {
        return .{ .id = @intCast(i) };
    }
    pub fn fromName(comptime str: []const u8) ModelId {
        inline for (&model_infos, 0..) |m, i| {
            if (comptime std.mem.eql(u8, m.name, str)) return .{ .id = i };
        }
        @compileError("unknown model: " ++ str);
    }
    pub fn info(self: ModelId) ModelInfo {
        return model_infos[self.id];
    }
    pub fn name(self: ModelId) [:0]const u8 {
        return self.info().name;
    }
};

pub const Model = struct {
    meshes: []Mesh, // 对应gltf.data.meshes
    textures_res: []TextureRes, //对应gltf.data.textures
    materials: []Material, //对应gltf.data.materials
    nodes: []Node, //简化的nodes结构，对应gltf.data.nodes
    skeleton: ?Skeleton = null,
    animations: []AnimClip = &.{},
    anim_mapping: std.StringHashMapUnmanaged([]const u8) = .{},
    anim_mapping_loaded: bool = false,
    pub fn load(
        allocator: std.mem.Allocator,
        gctx: *Gctx,
        name: []const u8,
        pipeline: *RenderPipeline,
    ) !Model {
        // 加载GLTF文件
        const model_file_name = try std.fmt.allocPrint(allocator, "{s}.glb", .{name});
        defer allocator.free(model_file_name);
        const model_file_path = try std.fs.path.join(allocator, &.{ "resources", "models", model_file_name });
        defer allocator.free(model_file_path);

        // 加载
        const model_file_buf = try std.Io.Dir.cwd().readFileAlloc(io, model_file_path, allocator, .unlimited);
        defer allocator.free(model_file_buf);
        var gltf = Gltf.init(allocator);
        defer gltf.deinit();
        try gltf.parse(@as([]align(4) const u8, @alignCast(model_file_buf)));

        var model: Model = undefined;

        // 复制node结构
        model.nodes = try allocator.alloc(Node, gltf.data.nodes.len);
        for (gltf.data.nodes, 0..) |gltf_node, i| {
            const matrix = calWorldMatrix(i, &gltf);
            model.nodes[i] = Node{
                .parent = gltf_node.parent,
                .matrix = matrix,
                .mesh = gltf_node.mesh,
            };
        }

        // 提取骨骼（skins）
        if (gltf.data.skins.len > 0) {
            const gltf_skin = &gltf.data.skins[0];
            const joint_count = gltf_skin.joints.len;
            var ibms = try allocator.alloc(Mat4, joint_count);
            var parents = try allocator.alloc(i32, joint_count);

            // 提取逆绑定矩阵
            if (gltf_skin.inverse_bind_matrices) |ibm_idx| {
                const accessor = gltf.data.accessors[ibm_idx];
                var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                var i: usize = 0;
                while (it.next()) |arr| : (i += 1)
                    ibms[i] = Mat4.fromSlice(arr[0..16]);
            } else {
                @memset(ibms, Mat4.identity);
            }

            // 计算骨骼的 parent_indices
            for (gltf_skin.joints, 0..) |node_idx, i| {
                const parent_node = gltf.data.nodes[node_idx].parent;
                parents[i] = if (parent_node) |p| blk: {
                    var found: i32 = -1;
                    for (gltf_skin.joints, 0..) |j, idx| {
                        if (j == p) {
                            found = @intCast(idx);
                            break;
                        }
                    }
                    break :blk found;
                } else -1;
            }

            model.skeleton = Skeleton{
                .joint_count = @intCast(joint_count),
                .inverse_bind_matrices = ibms,
                .parent_indices = parents,
            };
        }

        // 提取动画
        model.animations = try allocator.alloc(AnimClip, gltf.data.animations.len);
        for (gltf.data.animations, 0..) |gltf_anim, anim_idx| {
            const anim_name = gltf_anim.name orelse "<unnamed>";
            const clip_name = try allocator.dupe(u8, anim_name);
            var clip = AnimClip{
                .name = clip_name,
                .duration = 0,
                .channels = &.{},
            };

            // 计算动画总时长
            for (gltf_anim.samplers) |s| {
                const input_acc = gltf.data.accessors[s.input];
                var it = input_acc.iterator(f32, &gltf, gltf.glb_binary.?);
                while (it.next()) |v| {
                    if (v[0] > clip.duration) clip.duration = v[0];
                }
            }

            // 构建 channels
            var channels = try allocator.alloc(AnimChannel, gltf_anim.channels.len);
            for (gltf_anim.channels, 0..) |gltf_chan, ch_idx| {
                const sampler = &gltf_anim.samplers[gltf_chan.sampler];
                const input_acc = gltf.data.accessors[sampler.input];
                const output_acc = gltf.data.accessors[sampler.output];

                // 读 keyframe times
                var times = try allocator.alloc(f32, @as(usize, @intCast(input_acc.count)));
                {
                    var it = input_acc.iterator(f32, &gltf, gltf.glb_binary.?);
                    var i: usize = 0;
                    while (it.next()) |v| : (i += 1) times[i] = v[0];
                }

                // 读 keyframe values
                const num_keyframes = @as(usize, @intCast(input_acc.count));
                const component_count: u32 = switch (gltf_chan.target.property) {
                    .translation, .scale => 3,
                    .rotation => 4,
                    else => 0,
                };
                // CUBICSPLINE 时每个关键帧有 3 分量（in/value/out），取中间 value
                const cubic_factor: u32 = if (sampler.interpolation == .cubicspline) 3 else 1;
                const values_per_frame = component_count * cubic_factor;
                const total_values = num_keyframes * values_per_frame;
                var values = try allocator.alloc(f32, total_values);
                {
                    var it = output_acc.iterator(f32, &gltf, gltf.glb_binary.?);
                    var i: usize = 0;
                    while (it.next()) |v| {
                        for (v) |comp| {
                            if (i < total_values) {
                                values[i] = comp;
                                i += 1;
                            }
                        }
                    }
                }

                // 对于 CUBICSPLINE，跳过 in/out tangent，只取 value
                // LINEAR/STEP 直接使用
                channels[ch_idx] = .{
                    .joint_index = blk: {
                        const global_node = gltf_chan.target.node;
                        if (gltf.data.skins.len > 0) {
                            const gs = &gltf.data.skins[0];
                            for (gs.joints, 0..) |n, j| {
                                if (n == global_node) break :blk @as(u32, @intCast(j));
                            }
                        }
                        break :blk @as(u32, @intCast(global_node));
                    },
                    .property = switch (gltf_chan.target.property) {
                        .translation => .translation,
                        .rotation => .rotation,
                        .scale => .scale,
                        else => .translation,
                    },
                    .interpolation = switch (sampler.interpolation) {
                        .linear => .linear,
                        .step => .step,
                        .cubicspline => .cubic,
                    },
                    .times = times,
                    .values = values,
                    .stride = if (sampler.interpolation == .cubicspline) component_count else values_per_frame,
                };
            }
            clip.channels = channels;
            model.animations[anim_idx] = clip;
        }

        // 加载动画映射 JSON（可选）
        {
            const json_path = try std.fmt.allocPrint(allocator, "resources/models/{s}.anim.json", .{name});
            defer allocator.free(json_path);
            if (loadAnimMapping(allocator, json_path)) |mapping| {
                model.anim_mapping = mapping;
                model.anim_mapping_loaded = true;
            } else |_| {}
        }

        // 加载纹理
        model.textures_res = try allocator.alloc(TextureRes, gltf.data.textures.len);
        for (gltf.data.textures, 0..) |gltf_tex, i| {
            const img_source = gltf.data.images[gltf_tex.source.?];
            model.textures_res[i] = try TextureRes.loadFromMemory(allocator, gctx, img_source.data.?);
        }

        // 为材质绑定纹理
        model.materials = try allocator.alloc(Material, gltf.data.materials.len);
        for (gltf.data.materials, 0..) |gltf_material, i| {
            var mat = try Material.initDefault(gctx, pipeline);
            errdefer mat.deinit();
            // 处理颜色纹理
            if (gltf_material.metallic_roughness.base_color_texture) |color_tex_info| {
                const tex = model.textures_res[color_tex_info.index];
                // 注意：这里需要将 tex 的所有权转移给材质，材质会释放自己的默认纹理
                mat.setColorTexture(gctx, pipeline, tex);
            }
            // 处理法线纹理
            if (gltf_material.normal_texture) |normal_tex_info| {
                const tex = model.textures_res[normal_tex_info.index];
                mat.setNormalTexture(gctx, pipeline, tex);
            }
            model.materials[i] = mat;
        }

        // 加载网格
        model.meshes = try allocator.alloc(Mesh, gltf.data.meshes.len);
        for (gltf.data.meshes, 0..) |gltf_mesh, mesh_idx| {
            model.meshes[mesh_idx] = .{
                .primitives = try allocator.alloc(Primitive, gltf_mesh.primitives.len),
            };
            for (gltf_mesh.primitives, 0..) |gltf_prim, prim_idx| {
                // 索引
                var index_data: std.ArrayList(u32) = .empty;
                defer index_data.deinit(allocator);
                if (gltf_prim.indices) |indices_accessor_index| {
                    const accessor = gltf.data.accessors[indices_accessor_index];
                    // 使用 inline 循环避免重复代码
                    inline for (.{ u8, u16, u32 }) |IndexType| {
                        if (accessor.component_type == Gltf.ComponentType.fromType(IndexType)) {
                            var it = accessor.iterator(IndexType, &gltf, gltf.glb_binary.?);
                            while (it.next()) |indices| {
                                for (indices) |idx| {
                                    try index_data.append(allocator, @as(u32, idx));
                                }
                            }
                            break;
                        }
                    } else {
                        // 没有匹配的类型
                        std.debug.print("Unsupported index type: {}\n", .{accessor.component_type});
                        return error.UnsupportedIndexType;
                    }
                }
                const index_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
                    .size = @sizeOf(u32) * index_data.items.len,
                    .usage = Wgpu.WGPUBufferUsage_CopyDst | Wgpu.WGPUBufferUsage_Index,
                    .mappedAtCreation = 0,
                });
                Wgpu.wgpuQueueWriteBuffer(
                    gctx.queue,
                    index_buffer,
                    0,
                    index_data.items.ptr,
                    Wgpu.wgpuBufferGetSize(index_buffer),
                );
                model.meshes[mesh_idx].primitives[prim_idx].index_buffer = index_buffer;
                model.meshes[mesh_idx].primitives[prim_idx].index_count = @intCast(index_data.items.len);
                // 顶点
                const has_skin = gltf.data.skins.len > 0;
                if (has_skin) {
                    try loadPrimitiveVertices(SkinnedVertex, allocator, gctx, &gltf, gltf_prim, &model.meshes[mesh_idx].primitives[prim_idx]);
                } else {
                    try loadPrimitiveVertices(StaticVertex, allocator, gctx, &gltf, gltf_prim, &model.meshes[mesh_idx].primitives[prim_idx]);
                }
                // 绑定材质
                if (gltf_prim.material) |material_idx|
                    model.meshes[mesh_idx].primitives[prim_idx].material = model.materials[material_idx];
            }
        }

        // 返回
        return model;
    }

    fn loadPrimitiveVertices(comptime V: type, allocator: std.mem.Allocator, gctx: *Gctx, gltf: *Gltf, gltf_prim: anytype, prim: *Primitive) !void {
        var vertex_data: std.ArrayList(V) = .empty;
        defer vertex_data.deinit(allocator);
        for (gltf_prim.attributes) |attribute| {
            switch (attribute) {
                .position => |idx| {
                    const accessor = gltf.data.accessors[idx];
                    var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                    while (it.next()) |v| {
                        try vertex_data.append(allocator, .{ .position = .new(v[0], v[1], v[2]) });
                    }
                },
                .normal => |idx| {
                    const accessor = gltf.data.accessors[idx];
                    var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                    var i: u32 = 0;
                    while (it.next()) |n| : (i += 1)
                        vertex_data.items[i].normal = .new(n[0], n[1], n[2]);
                },
                .texcoord => |idx| {
                    const accessor = gltf.data.accessors[idx];
                    var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                    var i: u32 = 0;
                    while (it.next()) |t| : (i += 1)
                        vertex_data.items[i].texcoord = .new(t[0], t[1]);
                },
                .joints => |idx| {
                    if (V != StaticVertex) {
                        const accessor = gltf.data.accessors[idx];
                        inline for (.{ u8, u16, u32 }) |J| {
                            if (accessor.component_type == Gltf.ComponentType.fromType(J)) {
                                var it = accessor.iterator(J, gltf, gltf.glb_binary.?);
                                var i: usize = 0;
                                while (it.next()) |j| : (i += 1)
                                    vertex_data.items[i].joint_indices = .{ j[0], j[1], j[2], j[3] };
                                break;
                            }
                        }
                    }
                },
                .weights => |idx| {
                    if (V != StaticVertex) {
                        const accessor = gltf.data.accessors[idx];
                        var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                        var i: usize = 0;
                        while (it.next()) |w| : (i += 1) {
                            const sum: f32 = w[0] + w[1] + w[2] + w[3];
                            if (sum > 0) {
                                vertex_data.items[i].joint_weights = .{ w[0] / sum, w[1] / sum, w[2] / sum, w[3] / sum };
                            }
                        }
                    }
                },
                else => {},
            }
        }
        const vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(V) * vertex_data.items.len,
            .usage = Wgpu.WGPUBufferUsage_CopyDst | Wgpu.WGPUBufferUsage_Vertex,
            .mappedAtCreation = 0,
        });
        Wgpu.wgpuQueueWriteBuffer(
            gctx.queue,
            vertex_buffer,
            0,
            vertex_data.items.ptr,
            Wgpu.wgpuBufferGetSize(vertex_buffer),
        );
        prim.vertex_buffer = vertex_buffer;
    }

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        // 1. 释放所有纹理资源
        for (self.textures_res) |*tex| tex.deinit();
        allocator.free(self.textures_res);
        // 2. 释放材质资源
        for (self.materials) |*material| material.deinit();
        allocator.free(self.materials);

        // 3. 释放网格和 primitive 资源
        for (self.meshes) |mesh| {
            for (mesh.primitives) |primitive| {
                if (primitive.vertex_buffer) |buffer|
                    Wgpu.wgpuBufferRelease(buffer);
                if (primitive.index_buffer) |buffer|
                    Wgpu.wgpuBufferRelease(buffer);
            }
            allocator.free(mesh.primitives);
        }
        allocator.free(self.meshes);

        // 4. 释放节点数据
        allocator.free(self.nodes);

        // 5. 释放骨骼数据
        if (self.skeleton) |skel| {
            allocator.free(skel.inverse_bind_matrices);
            allocator.free(skel.parent_indices);
        }

        // 6. 释放动画数据
        for (self.animations) |clip| {
            allocator.free(clip.name);
            for (clip.channels) |ch| {
                allocator.free(ch.times);
                allocator.free(ch.values);
            }
            allocator.free(clip.channels);
        }
        allocator.free(self.animations);

        // 7. 释放动画映射
        if (self.anim_mapping_loaded) {
            var it = self.anim_mapping.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            self.anim_mapping.deinit(allocator);
        }
    }
};

fn calWorldMatrix(node_idx: usize, gltf: *Gltf) Mat4 {
    var current_idx = node_idx;
    var world_matrix = Mat4.identity;
    while (true) {
        const node = gltf.data.nodes[current_idx];
        if (node.matrix) |matrix| {
            world_matrix = Mat4.fromSlice(&matrix).mul(world_matrix);
        }
        current_idx = node.parent orelse break;
    }
    return world_matrix;
}

fn loadAnimMapping(allocator: std.mem.Allocator, path: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path_z, allocator, .limited(8192)) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var map = std.StringHashMapUnmanaged([]const u8){};
    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .string) {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const val = try allocator.dupe(u8, entry.value_ptr.*.string);
            map.put(allocator, key, val) catch {};
        }
    }
    return map;
}

pub const DrawBatch = struct {
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    index_count: u32,
    bind_group: Wgpu.WGPUBindGroup,
    instance_idx: u32,
    vertex_format: VertexFormat,
};

pub const ResManager = struct {
    const MAX_ENTITIES = 501; // 500 实体 + 1 区块占位
    const MAX_INSTANCES = 3 * MAX_ENTITIES + 5000; // 实体 + 区块（~4225）

    scene_uniform_buffer: Wgpu.WGPUBuffer,
    entities_data: []EntityData,
    entities_data_buffer: Wgpu.WGPUBuffer,
    instances_data: []InstanceData,
    instances_data_buffer: Wgpu.WGPUBuffer,

    draw_batches: [MAX_INSTANCES]DrawBatch = undefined,
    draw_batch_count: u32 = 0,

    allocator: std.mem.Allocator,
    models: [MAX_MODELS]Model = undefined,
    ref_counts: [MAX_MODELS]u32 = [_]u32{0} ** MAX_MODELS,
    active_models: SparseIndexSet(MAX_MODELS) = .{},
    gctx: *Gctx,
    pipeline: *RenderPipeline,

    pub fn getOrLoadModel(self: *ResManager, id: ModelId) *const Model {
        const idx = @as(u32, @bitCast(id));
        self.ref_counts[idx] += 1;
        if (!self.active_models.has(idx)) {
            self.models[idx] = Model.load(
                self.allocator,
                self.gctx,
                id.name(),
                self.pipeline,
            ) catch |err| {
                std.debug.print("Failed to load model '{s}': {}\n", .{ id.name(), err });
                if (idx == 0) @panic("Cannot load default model");
                return self.getOrLoadModel(ModelId.fromInt(0));
            };
            self.active_models.add(self.allocator, idx);
        }
        return &self.models[idx];
    }

    pub fn resetRefCount(self: *ResManager) void {
        @memset(&self.ref_counts, 0);
    }

    pub fn removeZeroRefModel(self: *ResManager) void {
        var iter = self.active_models.iterator();
        while (iter.next()) |idx| {
            if (self.ref_counts[idx] == 0) {
                self.models[idx].deinit(self.allocator);
                _ = self.active_models.remove(idx);
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, pipeline: *RenderPipeline) !@This() {
        const scene_uniform_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
            .size = @sizeOf(SceneUniform),
            .usage = Wgpu.WGPUBufferUsage_Uniform | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        const entities_data = try allocator.alloc(EntityData, MAX_ENTITIES);
        const entities_data_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &Wgpu.WGPUBufferDescriptor{
            .size = @sizeOf(EntityData) * MAX_ENTITIES,
            .usage = Wgpu.WGPUBufferUsage_Storage | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        const instances_data = try allocator.alloc(InstanceData, MAX_INSTANCES);
        const instances_data_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &Wgpu.WGPUBufferDescriptor{
            .size = @sizeOf(InstanceData) * MAX_INSTANCES,
            .usage = Wgpu.WGPUBufferUsage_Storage | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });
        return @This(){
            .scene_uniform_buffer = scene_uniform_buffer,
            .entities_data = entities_data,
            .entities_data_buffer = entities_data_buffer,
            .instances_data = instances_data,
            .instances_data_buffer = instances_data_buffer,
            .allocator = allocator,
            .pipeline = pipeline,
            .gctx = gctx,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        Wgpu.wgpuBufferRelease(self.scene_uniform_buffer);
        allocator.free(self.entities_data);
        Wgpu.wgpuBufferRelease(self.entities_data_buffer);
        allocator.free(self.instances_data);
        Wgpu.wgpuBufferRelease(self.instances_data_buffer);

        var iter = self.active_models.iterator();
        while (iter.next()) |idx| {
            self.models[idx].deinit(self.allocator);
        }
        self.active_models.deinit(self.allocator);
    }
};

pub const SceneUniform = struct {
    proj_matrix: Mat4 = undefined, // 投影矩阵
    view_matrix: Mat4 = undefined, // 视图矩阵
    camera_pos: Vec3 = undefined, // 摄像机世界坐标
    time: f32 = undefined, // 当前时间
    sun_direction: Vec3 = undefined, // 太阳方向
    sun_intensity: f32 = undefined, // 太阳强度
    sun_color: Vec3 = undefined, // 太阳颜色
    moon_brightness: f32 = undefined, // 月亮强度
    ambient_ground: Vec3 = undefined, // 白天环境光色，独立于 horizon_color
    _pad: f32 = undefined,
    shadow_vp: Mat4 = undefined, // 太阳视角 VP 矩阵（阴影贴图）
    moon_color: Vec3 = undefined, // 月亮颜色
    _pad2: f32 = undefined,

    pub fn init(window: Window) @This() {
        const aspect_ratio: f32 = window.width / window.height;
        const proj_matrix = Mat4.perspectiveReversedZ(
            70,
            aspect_ratio,
            0.1,
            500,
        );
        const view_matrix = Mat4.lookAt(Vec3.new(0.0, 0.0, 0.0), Vec3.unit_z, Vec3.up);
        return .{
            .proj_matrix = proj_matrix,
            .view_matrix = view_matrix,
            .camera_pos = Vec3.zero,
            .time = window.time,
            .sun_direction = Vec3.new(0, 1, 0),
            .sun_intensity = 1.0,
            .sun_color = Vec3.new(1, 1, 1),
            .moon_brightness = 0.3,
            .ambient_ground = Vec3.new(1, 1, 1), // 环境光
            ._pad = undefined,
            .shadow_vp = Mat4.identity,
            .moon_color = Vec3.new(0.5, 0.55, 0.8),
        };
    }
};

pub const VertexFormat = enum { static_model, skinned_model, chunk };

// 静态顶点：32 字节，用于无骨骼 glTF 模型。
// 没有关节信息，只能用 pipeline_static 渲染。
pub const StaticVertex = struct {
    position: Vec3 = Vec3.zero,
    normal: Vec3 = Vec3.new(0, 1, 0),
    texcoord: Vec2 = Vec2.zero,
};

// 紧凑区块顶点：4 字节（packed struct，GPU 侧以 u32 读取）。
// bx:5  by:8  bz:5  face_dir:3  world_dir:3  corner:2  _pad:6  = 32 bits
// face_dir 是局部面方向（UV用），world_dir 是世界面方向（法线用）
// bx/bz 相对 chunk 原点（0~16 角点坐标），by 垂直坐标（0~255）
pub const ChunkVertex = packed struct {
    bx: u5,
    by: u8,
    bz: u5,
    face_dir: u3,
    world_dir: u3,
    corner: u2,
    _pad: u6 = 0,

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("ChunkVertex must be 4 bytes");
    }
};

// 蒙皮顶点：64 字节，用于带骨骼动画的模型。
// 前三个字段与 StaticVertex 完全一致，所以共用同一个 vertex buffer 时
// static pipeline 能正确读取前 32 字节（忽略后 32 字节）。
pub const SkinnedVertex = struct {
    position: Vec3 = Vec3.zero,
    normal: Vec3 = Vec3.new(0, 1, 0),
    texcoord: Vec2 = Vec2.zero,
    joint_indices: [4]u32 = .{ 0, 0, 0, 0 },
    joint_weights: [4]f32 = .{ 1, 0, 0, 0 },
};

pub const EntityData = struct {
    transform: Mat4,
    bone_offset: i32 = -1,
    _padding: [3]i32 = undefined,
};

pub const InstanceData = struct {
    transform: Mat4,
    entity_idx: u32,
    bone_offset: i32 = -1,
    _padding: [2]i32 = undefined,
};

const std = @import("std");
const Gctx = @import("gctx.zig");
const Algebra = @import("algebra.zig");
const Window = @import("window.zig");
const SparseIndexSet = @import("sparse_set.zig").SparseIndexSet;
const RenderPipeline = @import("render_pipeline.zig");

const Vec2 = Algebra.Vec2;
const Vec3 = Algebra.Vec3;
const Vec4 = Algebra.Vec4;
const Quat = Algebra.Quat;
const Mat4 = Algebra.Mat4;

const Gltf = @import("imports.zig").Gltf;
const Wgpu = @import("imports.zig").Wgpu;
const zigimg = @import("zigimg");
