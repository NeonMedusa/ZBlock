// resource_manager.zig:
vertex_buffer: Wgpu.WGPUBuffer, // 顶点缓冲区
index_buffer: Wgpu.WGPUBuffer, // 索引缓冲区
scene_uniform_buffer: Wgpu.WGPUBuffer, // 场景常量缓冲区
entities_data: []EntityData,
entities_data_buffer: Wgpu.WGPUBuffer, // 渲染实例的世界矩阵缓冲区
indexed_indirect_cmds: []IndexedIndirectCmd,
indexed_indirect_cmds_buffer: Wgpu.WGPUBuffer, // 间接绘制index命令缓冲区
models_info: std.EnumArray(ModelName, ModelInfo),
// 纹理图集数组，ALL_IN_BOOM！包含所有的颜色、法线、高光贴图
color_altas: Wgpu.WGPUTexture,
color_altas_view: Wgpu.WGPUTextureView,
// 好吧，虽然我也想ALL_IN_BOOM，但为了让色彩纹理将来能支持BC（块压缩），还是为动画单独创建一个纹理图集数组比较好
anime_altas: Wgpu.WGPUTexture,
anime_altas_view: Wgpu.WGPUTextureView,
// 为了能支持多个动画纹理，我们需要一个buffer存储纹理信息
textures_info_buffer: Wgpu.WGPUBuffer,
// 渲染相关设置
const MAX_ENTITIES = 500; // 限制最大实体数
const ATLAS_WIDTH = 4096; // 每张纹理图集的宽度
const ATLAS_HEIGHT = 4096; // 每张纹理图集的高度
pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    Wgpu.wgpuBufferRelease(self.vertex_buffer);
    Wgpu.wgpuBufferRelease(self.index_buffer);
    Wgpu.wgpuBufferRelease(self.scene_uniform_buffer);
    allocator.free(self.entities_data);
    Wgpu.wgpuBufferRelease(self.entities_data_buffer);
    allocator.free(self.indexed_indirect_cmds);
    Wgpu.wgpuBufferRelease(self.indexed_indirect_cmds_buffer);
    Wgpu.wgpuTextureRelease(self.color_altas);
    Wgpu.wgpuTextureViewRelease(self.color_altas_view);

    Wgpu.wgpuTextureRelease(self.anime_altas);
    Wgpu.wgpuTextureViewRelease(self.anime_altas_view);
    Wgpu.wgpuBufferRelease(self.textures_info_buffer);
}
pub fn init(allocator: std.mem.Allocator, gctx: *Gctx) !@This() {
    const indexed_indirect_cmds = try allocator.alloc(IndexedIndirectCmd, MAX_ENTITIES);
    const indexed_indirect_cmds_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &Wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(IndexedIndirectCmd) * MAX_ENTITIES,
        .usage = Wgpu.WGPUBufferUsage_Storage | Wgpu.WGPUBufferUsage_CopyDst | Wgpu.WGPUBufferUsage_Indirect,
        .mappedAtCreation = 0,
    });
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

    var models_info = std.EnumArray(ModelName, ModelInfo).initUndefined();

    // 加载模型填充缓冲区
    var vertex_data = std.ArrayList(VertexAttribute){};
    defer vertex_data.deinit(allocator);
    var index_data = std.ArrayList(u32){};
    defer index_data.deinit(allocator);

    { // 第一遍加载模型的顶点数据，并获取模型的贴图大小
        var model_it = models_info.iterator();
        while (model_it.next()) |model| {
            const file_name = try std.fmt.allocPrint(allocator, "{s}.glb", .{@tagName(model.key)});
            defer allocator.free(file_name);
            const file_path = try std.fs.path.join(allocator, &.{ "resources", "models", file_name });
            defer allocator.free(file_path);
            const file_buf = try std.fs.cwd().readFileAllocOptions(
                allocator,
                file_path,
                std.math.maxInt(usize),
                null,
                .@"16",
                null,
            );
            defer allocator.free(file_buf);
            var gltf = Gltf.init(allocator);
            defer gltf.deinit();
            try gltf.parse(file_buf);

            // 获取色彩纹理的尺寸信息，暂时只提取一个
            var color_texture_info = TextureInfo{};
            for (gltf.data.materials) |material| {
                if (material.metallic_roughness.base_color_texture) |gltf_texture_info| {
                    const color_texture_img_idx = gltf.data.textures[gltf_texture_info.index].source;
                    const img_source = gltf.data.images[color_texture_img_idx.?];
                    var img = try zigimg.Image.fromMemory(allocator, img_source.data.?);
                    defer img.deinit(allocator);
                    const size_x_f: f32 = @floatFromInt(img.width);
                    const size_y_f: f32 = @floatFromInt(img.height);
                    color_texture_info.size = .{ size_x_f, size_y_f };
                }
            }

            // 获取动画纹理的尺寸信息，暂时只提取第一个
            var anime_texture_info = TextureInfo{};
            if (gltf.data.animations.len != 0) {
                const anime = gltf.data.animations[0];
                const sampler = anime.samplers[0];
                const input_accessors = gltf.data.accessors[sampler.input];
                const num_keyframes = input_accessors.count;
                anime_texture_info.size[1] = @floatFromInt(num_keyframes);
            }
            // 记录每个skin的joints起始索引和joints总数
            // 当一个node同时包含mesh和skin时，mesh顶点属性中的joint_indices就是相对于这个skin的joints数组的索引
            // 我打算将所有的joint矩阵全都合并存到同一个数组中，所以需要计算该skin的joint在数组中的偏移量
            var total_joints_count: u32 = 0; // 总关节数
            var skins_joint_start_idx = std.ArrayList(u32){}; // skin的joint索引偏移
            defer skins_joint_start_idx.deinit(allocator);
            for (gltf.data.skins) |skin| {
                try skins_joint_start_idx.append(allocator, total_joints_count);
                total_joints_count += @intCast(skin.joints.len);
            }
            //动画纹理的宽度=1(关键帧的时间戳)+4x骨骼数量
            anime_texture_info.size[0] = @floatFromInt(1 + total_joints_count * 3);

            // 提取有mesh的节点的vertex和index数据
            var model_vertex_data = std.ArrayList(VertexAttribute){};
            defer model_vertex_data.deinit(allocator);
            var model_index_data = std.ArrayList(u32){};
            defer model_index_data.deinit(allocator);

            for (gltf.data.nodes, 0..) |node, node_idx| {
                // 应用joint索引偏移
                var joint_offset: u32 = 0;
                if (node.skin) |skin_idx|
                    joint_offset = skins_joint_start_idx.items[skin_idx];

                if (node.mesh) |mesh_idx| {
                    const world_matrix = calWorldMatrix(node_idx, &gltf);
                    const mesh = gltf.data.meshes[mesh_idx];
                    var mesh_vertex_data = std.ArrayList(VertexAttribute){};
                    defer mesh_vertex_data.deinit(allocator);
                    var mesh_index_data = std.ArrayList(u32){};
                    defer mesh_index_data.deinit(allocator);
                    for (mesh.primitives) |primitive| {
                        var primitive_vertex_data = std.ArrayList(VertexAttribute){};
                        defer primitive_vertex_data.deinit(allocator);
                        var primitive_index_data = std.ArrayList(u32){};
                        defer primitive_index_data.deinit(allocator);
                        // 处理索引，记录当前model的顶点数量作为偏移
                        const vertex_offset: u32 = @intCast(model_vertex_data.items.len);
                        if (primitive.indices) |indices_accessor_index| {
                            const accessor = gltf.data.accessors[indices_accessor_index];
                            var it = accessor.iterator(u16, &gltf, gltf.glb_binary.?);
                            while (it.next()) |indice|
                                try primitive_index_data.append(allocator, indice[0] + vertex_offset);
                        }
                        // 处理顶点
                        for (primitive.attributes) |attribute| {
                            switch (attribute) {
                                .position => |idx| {
                                    const accessor = gltf.data.accessors[idx];
                                    var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                                    while (it.next()) |v| {
                                        var pos = [3]f32{ v[0], v[1], v[2] };
                                        //对于没有动画的静态模型，直接为其计算世界变换
                                        if (gltf.data.animations.len == 0) {
                                            const world_pos = world_matrix.mulByVec3(.{ .data = .{ v[0], v[1], v[2] } });
                                            pos = .{ world_pos.data[0], world_pos.data[1], world_pos.data[2] };
                                        }
                                        try primitive_vertex_data.append(allocator, .{
                                            .position = pos,
                                            .color_uv = .{ 0.1, 0.9 },
                                            .joint_indices = .{ 0, 0, 0, 0 }, // 骨骼矩阵索引
                                            .joint_weights = .{ 0, 0, 0, 0 }, // 骨骼矩阵权重
                                        });
                                    }
                                },
                                .texcoord => |idx| {
                                    const accessor = gltf.data.accessors[idx];
                                    var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                                    var i: u32 = 0;
                                    while (it.next()) |t| : (i += 1)
                                        primitive_vertex_data.items[i].color_uv = .{ t[0], t[1] };
                                },
                                .joints => |idx| {
                                    const accessor = gltf.data.accessors[idx];
                                    switch (accessor.component_type) {
                                        .unsigned_byte => {
                                            var it = accessor.iterator(u8, &gltf, gltf.glb_binary.?);
                                            var i: u32 = 0;
                                            while (it.next()) |j| : (i += 1)
                                                primitive_vertex_data.items[i].joint_indices = .{
                                                    j[0] + joint_offset,
                                                    j[1] + joint_offset,
                                                    j[2] + joint_offset,
                                                    j[3] + joint_offset,
                                                };
                                        },
                                        .unsigned_short => {
                                            var it = accessor.iterator(u16, &gltf, gltf.glb_binary.?);
                                            var i: u32 = 0;
                                            while (it.next()) |j| : (i += 1)
                                                primitive_vertex_data.items[i].joint_indices = .{
                                                    j[0] + joint_offset,
                                                    j[1] + joint_offset,
                                                    j[2] + joint_offset,
                                                    j[3] + joint_offset,
                                                };
                                        },
                                        .unsigned_integer => {
                                            var it = accessor.iterator(u32, &gltf, gltf.glb_binary.?);
                                            var i: u32 = 0;
                                            while (it.next()) |j| : (i += 1)
                                                primitive_vertex_data.items[i].joint_indices = .{
                                                    j[0] + joint_offset,
                                                    j[1] + joint_offset,
                                                    j[2] + joint_offset,
                                                    j[3] + joint_offset,
                                                };
                                        },
                                        else => @panic("Type matching error, please refer to the definition of 'accessor.iterator'"),
                                    }
                                },
                                .weights => |idx| {
                                    const accessor = gltf.data.accessors[idx];
                                    var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                                    var i: u32 = 0;
                                    while (it.next()) |w| : (i += 1) {
                                        var weights = Vec4.new(w[0], w[1], w[2], w[3]);
                                        weights = weights.norm();
                                        primitive_vertex_data.items[i].joint_weights = .{ weights.x(), weights.y(), weights.z(), weights.w() };
                                    }
                                },
                                else => {},
                            }
                        }
                        // 将primitive数据添加到model数据中
                        try model_vertex_data.appendSlice(allocator, primitive_vertex_data.items);
                        try model_index_data.appendSlice(allocator, primitive_index_data.items);
                    }
                    // 将当前mesh数据追加到当前model数据中
                    try model_vertex_data.appendSlice(allocator, mesh_vertex_data.items);
                    try model_index_data.appendSlice(allocator, mesh_index_data.items);
                }
            }
            // 将当前model数据追加到全局数据中
            model.value.first_vertex_idx = @intCast(vertex_data.items.len);
            model.value.first_index_idx = @intCast(index_data.items.len);
            model.value.vertex_count = @intCast(model_vertex_data.items.len);
            model.value.index_count = @intCast(model_index_data.items.len);
            model.value.color_texture = color_texture_info;
            model.value.anime_texture = anime_texture_info;
            try vertex_data.appendSlice(allocator, model_vertex_data.items);
            try index_data.appendSlice(allocator, model_index_data.items);
        }
    }
    // 写入顶点和索引缓冲区
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

    // 第二遍，获取了所有的贴图大小后，将贴图进行二维装箱、写入纹理
    const pr = try TexturePacker.packTextures(
        allocator,
        &models_info,
        ATLAS_WIDTH,
        ATLAS_HEIGHT,
    );
    const color_atlas_count = pr.color_atlas_count;
    const color_altas_desc = Wgpu.WGPUTextureDescriptor{
        .usage = Wgpu.WGPUTextureUsage_CopyDst | Wgpu.WGPUTextureUsage_TextureBinding,
        .dimension = Wgpu.WGPUTextureDimension_2D,
        .size = .{
            .width = ATLAS_WIDTH,
            .height = ATLAS_HEIGHT,
            // 大于1表明这是一个纹理数组，填入多少就有多少张纹理
            // 写入纹理时通过修改origin的z轴来指定写入哪一张纹理
            .depthOrArrayLayers = color_atlas_count,
        },
        .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
    };
    const color_altas = Wgpu.wgpuDeviceCreateTexture(gctx.device, &color_altas_desc);
    const color_altas_view = Wgpu.wgpuTextureCreateView(
        color_altas,
        &Wgpu.struct_WGPUTextureViewDescriptor{
            .aspect = Wgpu.WGPUTextureAspect_All,
            .baseArrayLayer = 0,
            .arrayLayerCount = color_altas_desc.size.depthOrArrayLayers,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .dimension = Wgpu.WGPUTextureViewDimension_2DArray,
            .format = color_altas_desc.format,
        },
    );
    // 创建动画纹理图集
    const anime_atlas_count = pr.anime_atlas_count;
    const anime_altas_desc = Wgpu.WGPUTextureDescriptor{
        .usage = Wgpu.WGPUTextureUsage_CopyDst | Wgpu.WGPUTextureUsage_TextureBinding,
        .dimension = Wgpu.WGPUTextureDimension_2D,
        .size = .{
            .width = ATLAS_WIDTH,
            .height = ATLAS_HEIGHT,
            // 大于1表明这是一个纹理数组，填入多少就有多少张纹理
            // 写入纹理时通过修改origin的z轴来指定写入哪一张纹理
            .depthOrArrayLayers = anime_atlas_count,
        },
        .format = Wgpu.WGPUTextureFormat_RGBA32Float,
        .mipLevelCount = 1,
        .sampleCount = 1,
    };
    const anime_altas = Wgpu.wgpuDeviceCreateTexture(gctx.device, &anime_altas_desc);
    const anime_altas_view = Wgpu.wgpuTextureCreateView(
        anime_altas,
        &Wgpu.struct_WGPUTextureViewDescriptor{
            .aspect = Wgpu.WGPUTextureAspect_All,
            .baseArrayLayer = 0,
            .arrayLayerCount = anime_altas_desc.size.depthOrArrayLayers,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .dimension = Wgpu.WGPUTextureViewDimension_2DArray,
            .format = anime_altas_desc.format,
        },
    );
    // 提取并写入纹理数据
    var model_it = models_info.iterator();
    while (model_it.next()) |model| {
        const file_name = try std.fmt.allocPrint(allocator, "{s}.glb", .{@tagName(model.key)});
        defer allocator.free(file_name);
        const file_path = try std.fs.path.join(allocator, &.{ "resources", "models", file_name });
        defer allocator.free(file_path);
        const file_buf = try std.fs.cwd().readFileAllocOptions(
            allocator,
            file_path,
            std.math.maxInt(usize),
            null,
            .@"16",
            null,
        );
        defer allocator.free(file_buf);
        var gltf = Gltf.init(allocator);
        defer gltf.deinit();
        try gltf.parse(file_buf);
        // 提取并写入色彩纹理数据
        for (gltf.data.materials) |material| {
            if (material.metallic_roughness.base_color_texture) |color_texture_info| {
                const color_texture_img_idx = gltf.data.textures[color_texture_info.index].source;
                const img_source = gltf.data.images[color_texture_img_idx.?];
                var img = try zigimg.Image.fromMemory(allocator, img_source.data.?);
                defer img.deinit(allocator);
                try img.convert(allocator, .rgba32);

                Wgpu.wgpuQueueWriteTexture(
                    gctx.queue,
                    &Wgpu.WGPUTexelCopyTextureInfo{
                        .texture = color_altas,
                        .mipLevel = 0,
                        // xy为写入时的像素偏移，我们可以利用这个特性实现纹理图集，z轴用于指定写入到哪张纹理中
                        .origin = .{
                            .x = @intCast(model.value.color_texture.coords_offset[0]),
                            .y = @intCast(model.value.color_texture.coords_offset[1]),
                            .z = model.value.color_texture.index,
                        },
                    },
                    img.pixels.rgba32.ptr,
                    img.pixels.rgba32.len * @sizeOf(zigimg.color.Rgba32),
                    &Wgpu.struct_WGPUTexelCopyBufferLayout{
                        .offset = 0,
                        .bytesPerRow = @intCast(img.width * 4),
                        .rowsPerImage = @intCast(img.height),
                    },
                    &Wgpu.struct_WGPUExtent3D{
                        .width = @intFromFloat(model.value.color_texture.size[0]),
                        .height = @intFromFloat(model.value.color_texture.size[1]),
                        .depthOrArrayLayers = 1,
                    },
                );
            }
        }
        // 提取并写入动画纹理数据
        if (gltf.data.animations.len > 0) {
            const anime = gltf.data.animations[0];
            // 关键帧数量，先假设同一动画中所有sampler的关键帧数量和时间戳都是一样的，如果最后证明不行再另想办法
            const num_keyframes = gltf.data.accessors[anime.samplers[0].input].count;
            // 关键帧时间戳数组，同样假设同一动画中所有sampler的关键帧数量和时间戳都是一样的
            var keyframe_times = std.ArrayList(f32){};
            defer keyframe_times.deinit(allocator);
            var anime_duration: f32 = 0;
            var it = gltf.data.accessors[anime.samplers[0].input].iterator(f32, &gltf, gltf.glb_binary.?);
            while (it.next()) |keyframe_time| {
                try keyframe_times.append(allocator, keyframe_time[0]);
                anime_duration = keyframe_time[0];
            }
            model.value.anime_duration = anime_duration;
            // 为每个关键帧创建动画矩阵数组
            var keyframe_matrices = std.ArrayList([]?Mat4){};
            defer {
                for (keyframe_matrices.items) |matrices|
                    allocator.free(matrices);
                keyframe_matrices.deinit(allocator);
            }
            // 初始化所有关键帧的矩阵为null
            var keyframe_idx: u32 = 0;
            while (keyframe_idx < num_keyframes) : (keyframe_idx += 1) {
                const frame_matrices = try allocator.alloc(?Mat4, gltf.data.nodes.len);
                @memset(frame_matrices, null);
                try keyframe_matrices.append(allocator, frame_matrices);
            }
            // 应用每个channel的动画数据到对应的关键帧
            for (anime.channels) |channel| {
                const sampler = anime.samplers[channel.sampler];
                const output_accessor = gltf.data.accessors[sampler.output];
                var output_it = output_accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                //目标节点索引
                const target_node_idx = channel.target.node;
                // 对每个关键帧应用动画
                var frame_idx: usize = 0;
                while (output_it.next()) |output_data| : (frame_idx += 1) {
                    const frame_matrices = keyframe_matrices.items[frame_idx];
                    const base_mat = frame_matrices[target_node_idx] orelse Mat4.identity();
                    frame_matrices[target_node_idx] = switch (channel.target.property) {
                        .translation => base_mat.mul(Mat4.fromTranslate(Vec3.fromSlice(output_data))),
                        .rotation => base_mat.mul(Quat.new(output_data[3], output_data[0], output_data[1], output_data[2]).toMat4()),
                        .scale => base_mat.mul(Mat4.fromScale(Vec3.fromSlice(output_data))),
                        .weights => base_mat, // 处理 morph target 权重
                    };
                }
            }
            // 没有被动画影响的节点矩阵用gltf原始节点矩阵填充
            // 如果gltf的node的matrix为null，则应该用RTS向量组合，懒得写，暂时用单位矩阵填充
            // 目前看下来好像也没什么问题，出问题了再说
            for (keyframe_matrices.items) |frame_matrices| {
                for (0..frame_matrices.len) |mat_idx| {
                    if (frame_matrices[mat_idx] == null) {
                        frame_matrices[mat_idx] = Mat4.identity();
                        if (gltf.data.nodes[mat_idx].matrix) |gltf_mat|
                            frame_matrices[mat_idx] = Mat4.fromSlice(&gltf_mat);
                    }
                }
            }
            // 现在 keyframe_matrices 包含了每个关键帧的所有节点变换矩阵
            // 我们可以继续计算每个关键帧的所有节点的世界变换矩阵（考虑节点层次结构）
            var keyframe_world_matrices = std.ArrayList([]Mat4){};
            defer {
                for (keyframe_world_matrices.items) |matrices|
                    allocator.free(matrices);
                keyframe_world_matrices.deinit(allocator);
            }
            for (keyframe_matrices.items) |frame_matrices| {
                const world_matrices = try allocator.alloc(Mat4, gltf.data.nodes.len);
                // 计算每个节点的世界矩阵（考虑父子关系）
                for (gltf.data.nodes, 0..) |node, node_idx| {
                    var world_matrix = frame_matrices[node_idx].?;
                    // 如果有父节点，累积父节点的变换
                    var current_parent = node.parent;
                    while (current_parent) |parent_idx| {
                        world_matrix = frame_matrices[parent_idx].?.mul(world_matrix);
                        current_parent = gltf.data.nodes[parent_idx].parent;
                    }
                    world_matrices[node_idx] = world_matrix;
                }
                try keyframe_world_matrices.append(allocator, world_matrices);
            }
            // 获取骨骼矩阵
            var bone_matrices = std.ArrayList(Mat4){};
            defer bone_matrices.deinit(allocator);
            for (keyframe_world_matrices.items) |keyframe_world_matrice| {
                for (gltf.data.skins) |skin| {
                    // 预加载所有逆绑定矩阵
                    var inverse_bind_matrices: ?[]Mat4 = null;
                    defer if (inverse_bind_matrices) |matrices| allocator.free(matrices);
                    if (skin.inverse_bind_matrices) |ibms_accessor_idx| {
                        const ibms_accessor = gltf.data.accessors[ibms_accessor_idx];
                        var ibms_accessor_it = ibms_accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                        inverse_bind_matrices = try allocator.alloc(Mat4, ibms_accessor.count);
                        // 一次性加载所有逆绑定矩阵
                        for (0..ibms_accessor.count) |i| {
                            if (ibms_accessor_it.next()) |arr|
                                inverse_bind_matrices.?[i] = Mat4.fromSlice(arr[0..16]);
                        }
                    }

                    // 为每个关节计算骨骼矩阵
                    for (skin.joints, 0..) |joint_node_idx, joint_index| {
                        const joint_world_matrix = keyframe_world_matrice[joint_node_idx];
                        var final_bone_matrix = joint_world_matrix;
                        // 如果存在逆绑定矩阵，应用它
                        if (inverse_bind_matrices) |ibms|
                            final_bone_matrix = joint_world_matrix.mul(ibms[joint_index]);
                        try bone_matrices.append(allocator, final_bone_matrix);
                    }
                }
            }

            // 创建动画纹理数据
            var total_joints_count: usize = 0; // 总关节数
            for (gltf.data.skins) |skin|
                total_joints_count += skin.joints.len;

            const anime_texture_data = try create_anime_texture_data(
                allocator,
                keyframe_times.items,
                bone_matrices.items, // 计算出的骨骼矩阵数组
                @intCast(num_keyframes),
                @intCast(total_joints_count),
            );
            defer allocator.free(anime_texture_data);

            // 写入到wgpu纹理
            const anime_texture_width: u32 = @intFromFloat(model.value.anime_texture.size[0]);
            const anime_texture_height: u32 = @intFromFloat(model.value.anime_texture.size[1]);

            Wgpu.wgpuQueueWriteTexture(
                gctx.queue,
                &Wgpu.WGPUTexelCopyTextureInfo{
                    .texture = anime_altas,
                    .mipLevel = 0,
                    // xy为写入时的像素偏移，我们可以利用这个特性实现纹理图集，z轴用于指定写入到哪张纹理中
                    .origin = .{
                        .x = @intCast(model.value.anime_texture.coords_offset[0]),
                        .y = @intCast(model.value.anime_texture.coords_offset[1]),
                        .z = model.value.anime_texture.index,
                    },
                },
                anime_texture_data.ptr,
                anime_texture_data.len,
                &Wgpu.struct_WGPUTexelCopyBufferLayout{
                    .offset = 0,
                    .bytesPerRow = anime_texture_width * 16,
                    .rowsPerImage = anime_texture_height,
                },
                &Wgpu.struct_WGPUExtent3D{
                    .width = anime_texture_width,
                    .height = anime_texture_height,
                    .depthOrArrayLayers = 1,
                },
            );
        }
    }

    // !!!创建纹理信息缓冲区
    var textures_info = std.ArrayList(TextureInfo){};
    defer textures_info.deinit(allocator);
    var model_it2 = models_info.iterator();
    while (model_it2.next()) |model| {
        // !!!写入纹理信息缓冲区
        model.value.color_texture_idx = @intCast(textures_info.items.len);
        try textures_info.append(allocator, model.value.color_texture);
    }
    // !!!写入纹理信息缓冲区
    const texture_info_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
        .size = @sizeOf(TextureInfo) * textures_info.items.len,
        .usage = Wgpu.WGPUBufferUsage_Storage | Wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });
    Wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        texture_info_buffer,
        0,
        textures_info.items.ptr,
        @sizeOf(TextureInfo) * textures_info.items.len,
    );
    // 返回实例
    return @This(){
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .scene_uniform_buffer = scene_uniform_buffer,
        .indexed_indirect_cmds = indexed_indirect_cmds,
        .indexed_indirect_cmds_buffer = indexed_indirect_cmds_buffer,
        .entities_data = entities_data,
        .entities_data_buffer = entities_data_buffer,
        .color_altas = color_altas,
        .color_altas_view = color_altas_view,

        .anime_altas = anime_altas,
        .anime_altas_view = anime_altas_view,

        .models_info = models_info,
        .textures_info_buffer = texture_info_buffer,
    };
}

fn calWorldMatrix(node_idx: usize, gltf: *Gltf) Mat4 {
    var current_idx = node_idx;
    var world_matrix = Mat4.identity();
    while (true) {
        const node = gltf.data.nodes[current_idx];
        if (node.matrix) |matrix| {
            world_matrix = Mat4.fromSlice(&matrix).mul(world_matrix);
        }
        current_idx = node.parent orelse break;
    }
    return world_matrix;
}

fn create_anime_texture_data(
    allocator: std.mem.Allocator,
    keyframe_times: []const f32,
    bone_matrices: []const Mat4,
    num_keyframes: u32,
    num_bones: u32,
) ![]u8 {
    // 1. 计算纹理尺寸 - 改为每个骨骼存储3行
    const texture_width = 1 + num_bones * 3; // 宽度 = 1个时间戳 + 每个骨骼矩阵3行
    const texture_height = num_keyframes; // 高度 = 关键帧数量
    // 2. 计算内存布局
    const bytes_per_pixel = 16; // RGBA32Float = 4 floats × 4 bytes
    const bytes_per_row = texture_width * bytes_per_pixel;
    const total_size = bytes_per_row * texture_height;
    // 3. 分配内存
    const texture_data = try allocator.alloc(u8, total_size);
    errdefer allocator.free(texture_data);
    @memset(texture_data, 0);
    // 4. 将数据视为f32数组进行操作
    var data_as_f32 = std.mem.bytesAsSlice(f32, texture_data);
    // 5. 填充纹理数据
    for (0..num_keyframes) |frame_idx| {
        // 计算当前行的起始位置（每行有 texture_width × 4 个f32）
        const row_start = frame_idx * texture_width * 4;
        // 5.1 写入时间戳（第一个像素）
        data_as_f32[row_start + 0] = keyframe_times[frame_idx]; // R通道
        data_as_f32[row_start + 1] = 0.0; // G通道
        data_as_f32[row_start + 2] = 0.0; // B通道
        data_as_f32[row_start + 3] = 0.0; // A通道
        // 5.2 写入所有骨骼的矩阵（只存储前3行）
        for (0..num_bones) |bone_idx| {
            // 计算当前骨骼在bone_matrices中的索引
            const matrix_index = frame_idx * num_bones + bone_idx;
            const matrix = bone_matrices[matrix_index];
            // 计算当前骨骼在纹理中的起始位置
            // 跳过时间戳(1像素=4f32) + 前面所有骨骼(每个骨骼3像素=12f32)
            const bone_start = row_start + 4 + bone_idx * 12;
            // 写入矩阵的前3行，每行占1个像素（4个f32）
            for (0..3) |row| {
                const pixel_start = bone_start + row * 4;
                // 写入矩阵行数据
                data_as_f32[pixel_start + 0] = matrix.data[0][row]; // 第0列的第row个分量
                data_as_f32[pixel_start + 1] = matrix.data[1][row]; // 第1列的第row个分量
                data_as_f32[pixel_start + 2] = matrix.data[2][row]; // 第2列的第row个分量
                data_as_f32[pixel_start + 3] = matrix.data[3][row]; // 第3列的第row个分量
            }
            // 第4行 [0,0,0,1] 被省略，在shader中重建
        }
    }
    return texture_data;
}
const std = @import("std");
const ShaderType = @import("shader_types.zig");
const SceneUniform = ShaderType.SceneUniform;
const VertexAttribute = ShaderType.VertexAttribute;
const EntityData = ShaderType.EntityData;
const IndexedIndirectCmd = ShaderType.IndexedIndirectCmd;
const VertexIndirectCmd = ShaderType.VertexIndirectCmd;
const ModelInfo = ShaderType.ModelInfo;
const TextureInfo = ShaderType.TextureInfo;
const Gctx = @import("gctx.zig");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Vec4 = Algebra.Vec4;
const Quat = Algebra.Quat;
const Window = @import("window.zig");
const Gltf = @import("zgltf").Gltf;
const Wgpu = @import("cimports.zig").Wgpu;
const zigimg = @import("zigimg");
const ModelName = @import("model.zig").ModelName;
const TexturePacker = @import("texture_packer.zig");
