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
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const data = try allocator.alloc(u8, file_size);
        defer allocator.free(data);
        _ = try file.readAll(data);

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

pub const ModelNames = blk: {
    var fields: [MAX_MODELS]std.builtin.Type.EnumField = undefined;
    for (&fields, model_infos, 0..) |*field, def, i|
        field.* = .{ .name = def.name, .value = i };
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u32,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub const ModelId = enum(u32) {
    _,
    pub fn fromInt(i: anytype) ModelId {
        return @enumFromInt(i);
    }
    pub fn fromName(comptime str: []const u8) ModelId {
        const model_name_val = @field(ModelNames, str);
        return @enumFromInt(@intFromEnum(model_name_val));
    }
    pub fn info(self: ModelId) ModelInfo {
        return model_infos[@intFromEnum(self)];
    }
    pub fn name(self: ModelId) [:0]const u8 {
        return self.info().name;
    }
};

pub const Model = struct {
    meshes: []Mesh, // 对应gltf.data.meshes
    textures_res: []TextureRes, //对应gltf.data.textures
    anim_textures: []TextureRes, //对应gltf.data.animations
    materials: []Material, //对应gltf.data.materials
    nodes: []Node, //简化的nodes结构，对应gltf.data.nodes
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
        const model_file_buf = try std.fs.cwd().readFileAllocOptions(
            allocator,
            model_file_path,
            std.math.maxInt(usize),
            null,
            .@"16",
            null,
        );
        defer allocator.free(model_file_buf);
        var gltf = Gltf.init(allocator);
        defer gltf.deinit();
        try gltf.parse(model_file_buf);

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

        // 动画纹理，暂时不处理，先实现基础渲染
        model.anim_textures = try allocator.alloc(TextureRes, gltf.data.animations.len);
        for (model.anim_textures) |*anim_texture| {
            anim_texture.texture = null;
            anim_texture.view = null;
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
                var index_data = std.ArrayList(u32){};
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
                var vertex_data = std.ArrayList(VertexAttribute){};
                defer vertex_data.deinit(allocator);
                for (gltf_prim.attributes) |attribute| {
                    switch (attribute) {
                        .position => |idx| {
                            const accessor = gltf.data.accessors[idx];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            while (it.next()) |v| {
                                try vertex_data.append(allocator, .{
                                    .position = .new(v[0], v[1], v[2]),
                                    .texcoord = .new(0.1, 0.9),
                                    .joint_indices = .{ 0, 0, 0, 0 }, // 骨骼矩阵索引
                                    .joint_weights = .{ 0, 0, 0, 0 }, // 骨骼矩阵权重
                                });
                            }
                        },
                        .normal => |idx| {
                            const accessor = gltf.data.accessors[idx];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |n| : (i += 1) {
                                vertex_data.items[i].normal = .new(n[0], n[1], n[2]);
                            }
                        },
                        .texcoord => |idx| {
                            const accessor = gltf.data.accessors[idx];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |t| : (i += 1)
                                vertex_data.items[i].texcoord = .new(t[0], t[1]);
                        },
                        else => {},
                    }
                }
                const vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
                    .size = @sizeOf(VertexAttribute) * vertex_data.items.len,
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
                model.meshes[mesh_idx].primitives[prim_idx].vertex_buffer = vertex_buffer;
                // 绑定材质
                if (gltf_prim.material) |material_idx|
                    model.meshes[mesh_idx].primitives[prim_idx].material = model.materials[material_idx];
            }
        }

        // 返回
        return model;
    }

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        // 1. 释放所有纹理资源
        for (self.textures_res) |*tex| tex.deinit();
        allocator.free(self.textures_res);
        // 2. 释放动画纹理
        for (self.anim_textures) |*tex| tex.deinit();
        allocator.free(self.anim_textures);
        // 3. 释放材质资源
        for (self.materials) |*material| material.deinit();
        allocator.free(self.materials);

        // 4. 释放网格和 primitive 资源
        for (self.meshes) |mesh| {
            for (mesh.primitives) |primitive| {
                // 释放顶点缓冲区
                if (primitive.vertex_buffer) |buffer|
                    Wgpu.wgpuBufferRelease(buffer);

                // 释放索引缓冲区
                if (primitive.index_buffer) |buffer|
                    Wgpu.wgpuBufferRelease(buffer);
                // 注意：primitive.material 是引用，不在这里释放
                // 它指向 materials 数组，会在步骤3中释放
            }
            allocator.free(mesh.primitives);
        }
        allocator.free(self.meshes);

        // 5. 释放节点数据
        allocator.free(self.nodes);
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

pub const DrawBatch = struct {
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    index_count: u32,
    bind_group: Wgpu.WGPUBindGroup,
    instance_idx: u32,
};

pub const ResManager = struct {
    const MAX_ENTITIES = 500;
    const MAX_INSTANCES = 3 * MAX_ENTITIES;

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
        const idx = @intFromEnum(id);
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
    _padding: [4]f32 = undefined, // 结构体对齐到 16 字节
    pub fn init(window: Window) @This() {
        const aspect_ratio: f32 = window.width / window.height;
        // const proj_matrix = Mat4.perspective(70, aspect_ratio, 0.001, 500);
        const proj_matrix = Mat4.perspectiveReversedZ(
            70,
            aspect_ratio,
            0.1,
            500,
        );
        const view_matrix = Mat4.lookAt(Vec3.new(0.0, 0.0, -3.0), Vec3.zero, Vec3.up);
        return .{
            .proj_matrix = proj_matrix,
            .view_matrix = view_matrix,
            .camera_pos = Vec3.zero,
            .time = window.time,
            ._padding = undefined,
        };
    }
};

pub const VertexAttribute = struct {
    position: Vec3 = Vec3.zero,
    normal: Vec3 = Vec3.new(0, 1, 0),
    tangent: Vec4 = Vec4.new(1, 0, 0, 1),
    texcoord: Vec2 = Vec2.zero,
    color: Vec4 = Vec4.new(1, 1, 1, 1),
    joint_indices: [4]u32 = .{ 0, 0, 0, 0 },
    joint_weights: [4]f32 = .{ 1, 0, 0, 0 },
};

pub const EntityData = struct {
    transform: Mat4, //实体的世界变换
};

pub const InstanceData = struct {
    transform: Mat4, //渲染实例的变换
    entity_idx: u32, // 该渲染实例属于哪个游戏实体
    _padding: [3]f32 = undefined,
};

const Imports = @import("imports.zig");

const std = @import("std");
const Gctx = Imports.Gctx;

const Algebra = Imports.Algebra;
const Vec2 = Algebra.Vec2;
const Vec3 = Algebra.Vec3;
const Vec4 = Algebra.Vec4;
const Quat = Algebra.Quat;
const Mat4 = Algebra.Mat4;

const Window = Imports.Window;
const Gltf = Imports.Gltf;
const Wgpu = Imports.Wgpu;
const zigimg = Imports.zigimg;

const SparseIndexSet = Imports.SparseIndexSet;
const RenderPipeline = Imports.RenderPipeline;
