pub const Interpolation = enum {
    /// The animated values are linearly interpolated between keyframes.
    /// When targeting a rotation, spherical linear interpolation (slerp)
    /// should be used to interpolate quaternions.
    linear,
    /// The animated values remain constant to the output of the first
    /// keyframe, until the next keyframe.
    step,
    /// The animation’s interpolation is computed using a cubic
    /// spline with specified tangents.
    cubicspline,
};
/// 包装后的节点层级结构
pub const SceneNode = struct {
    parent: ?*SceneNode = null,
    children: std.ArrayList(*SceneNode),
    local_translation: Vec3 = Vec3.zero(),
    local_scale: Vec3 = Vec3.one(),
    local_rotation: Quat = Quat.identity(),
    local_matrix: Mat4 = Mat4.identity(),
    world_matrix: Mat4 = Mat4.identity(),
    gpu_mesh_idx: ?usize = null,
    skin_idx: ?usize = null,
    pub fn init(gltf_node: *Gltf.Node) !SceneNode {
        var node = SceneNode{
            .children = std.ArrayList(*SceneNode){},
            .local_translation = Vec3{ .data = gltf_node.translation },
            .local_scale = Vec3{ .data = gltf_node.scale },
            .local_rotation = Quat.new(
                gltf_node.rotation[3],
                gltf_node.rotation[0],
                gltf_node.rotation[1],
                gltf_node.rotation[2],
            ),
            .gpu_mesh_idx = gltf_node.mesh,
            .skin_idx = gltf_node.skin,
        };
        if (gltf_node.matrix) |mat| {
            node.local_matrix = ArrToMat4(mat);
        } else {
            const t_mat = Mat4.fromTranslate(node.local_translation);
            const r_mat = node.local_rotation.toMat4();
            const s_mat = Mat4.fromScale(node.local_scale);
            node.local_matrix = Mat4.mul(t_mat, Mat4.mul(r_mat, s_mat));
        }
        return node;
    }
    pub fn getWorldMatrix(self: *SceneNode) Mat4 {
        self.world_matrix = if (self.parent) |parent|
            Mat4.mul(parent.getWorldMatrix(), self.local_matrix)
        else
            self.local_matrix;
        return self.world_matrix;
    }
};
// 蒙皮数据（用于 GPU 上传）
pub const SkinData = struct {
    joints: []*SceneNode,
    inverse_bind_matrices: []Mat4,
    skeleton: ?*SceneNode = null,
};

pub const AnimationClip = struct {
    name: []const u8,
    channels: std.ArrayList(AnimationChannel),
    samplers: std.ArrayList(AnimationSampler),
    duration: f32,
};

pub const AnimationChannel = struct {
    target_node: *SceneNode,
    target_property: Gltf.TargetProperty,
    sampler: *AnimationSampler,
};

pub const AnimationSampler = struct {
    input: []f32, // 时间戳
    output: []f32, // 输出值
    interpolation: Interpolation,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(*SceneNode),
    root_nodes: std.ArrayList(*SceneNode),
    skins: std.ArrayList(SkinData),
    meshes: std.ArrayList(GpuMesh),
    animations: std.ArrayList(AnimationClip),
    pub fn init(allocator: std.mem.Allocator) Model {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(*SceneNode){},
            .root_nodes = std.ArrayList(*SceneNode){},
            .skins = std.ArrayList(SkinData){},
            .meshes = std.ArrayList(GpuMesh){},
            .animations = std.ArrayList(AnimationClip){},
        };
    }
    // 从 Gltf 加载并构建层级
    pub fn loadFromGltf(
        self: *Model,
        allocator: std.mem.Allocator,
        gltf: *Gltf,
        vertex_data: *std.ArrayList(VertexAttribute),
        index_data: *std.ArrayList(u16),
    ) !void {
        // 创建所有节点
        for (gltf.data.nodes) |*gltf_node| {
            const node = try self.allocator.create(SceneNode);
            node.* = try SceneNode.init(gltf_node);
            try self.nodes.append(allocator, node);
        }
        // 构建父子关系
        for (gltf.data.nodes, 0..) |gltf_node, i| {
            if (gltf_node.parent) |parent_index| {
                self.nodes.items[i].parent = self.nodes.items[parent_index];
                try self.nodes.items[parent_index].children.append(allocator, self.nodes.items[i]);
            }
        }
        // 加载 Mesh
        var gpu_meshes = std.ArrayList(GpuMesh){};
        defer gpu_meshes.deinit(allocator);
        for (gltf.data.meshes) |mesh| {
            var cur_mesh_vertex_data = std.ArrayList(VertexAttribute){};
            defer cur_mesh_vertex_data.deinit(allocator);
            var cur_mesh_index_data = std.ArrayList(u16){};
            defer cur_mesh_index_data.deinit(allocator);
            for (mesh.primitives) |primitive| {
                // 由于一个mesh中可能会有多个primitive，所以我们需要为当前primitive计算索引偏移
                const vertex_start = cur_mesh_vertex_data.items.len;
                // 提取索引数据
                if (primitive.indices) |indices_accessor_index| {
                    const accessor = gltf.data.accessors[indices_accessor_index];
                    var it = accessor.iterator(u16, gltf, gltf.glb_binary.?);
                    while (it.next()) |indice|
                        try cur_mesh_index_data.append(allocator, indice[0] + @as(u16, @intCast(vertex_start)));
                } // 提取顶点数据
                for (primitive.attributes) |attribute| {
                    switch (attribute) {
                        .position => |idx| {
                            const accessor = gltf.data.accessors[idx];
                            var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                            var i: f32 = 0; // 暂时只添加一些随机性的颜色
                            while (it.next()) |v| : (i += 0.001) {
                                try cur_mesh_vertex_data.append(
                                    allocator,
                                    .{
                                        .pos = .{ v[0], v[1], v[2] },
                                        .normal = .{ 1, 1, 1 },
                                        .color = .{ @mod(i / 0.1, 1), @mod(i / 0.2, 1), @mod(i / 0.3, 1), 1 },
                                        .joint_indices = .{ 0, 0, 0, 0 },
                                        .joint_weights = .{ 1, 0, 0, 0 },
                                    },
                                );
                            }
                        },
                        .normal => |idx| {
                            const accessor = gltf.data.accessors[idx];
                            var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                            var i: usize = vertex_start;
                            while (it.next()) |n| : (i += 1)
                                cur_mesh_vertex_data.items[i].normal = .{ n[0], n[1], n[2] };
                        },
                        .color => |idx| {
                            const accessor = gltf.data.accessors[idx];
                            var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                            var i: usize = vertex_start;
                            while (it.next()) |c| : (i += 1)
                                cur_mesh_vertex_data.items[i].color = .{ c[0], c[1], c[2], c[3] };
                        },
                        .joints => |idx| {
                            const accessor = gltf.data.accessors[idx];
                            switch (accessor.component_type) {
                                .unsigned_byte => {
                                    var it = accessor.iterator(u8, gltf, gltf.glb_binary.?);
                                    var i: usize = vertex_start;
                                    while (it.next()) |j| : (i += 1)
                                        cur_mesh_vertex_data.items[i].joint_indices = .{ j[0], j[1], j[2], j[3] };
                                },
                                .unsigned_short => {
                                    var it = accessor.iterator(u16, gltf, gltf.glb_binary.?);
                                    var i: usize = vertex_start;
                                    while (it.next()) |j| : (i += 1)
                                        cur_mesh_vertex_data.items[i].joint_indices = .{ j[0], j[1], j[2], j[3] };
                                },
                                .unsigned_integer => {
                                    var it = accessor.iterator(u32, gltf, gltf.glb_binary.?);
                                    var i: usize = vertex_start;
                                    while (it.next()) |j| : (i += 1)
                                        cur_mesh_vertex_data.items[i].joint_indices = .{ j[0], j[1], j[2], j[3] };
                                },
                                else => @panic("Type matching error, please refer to the definition of 'accessor.iterator'"),
                            }
                        },
                        .weights => |idx| {
                            const accessor = gltf.data.accessors[idx];
                            var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                            var i: usize = vertex_start;
                            while (it.next()) |w| : (i += 1) {
                                var weights = Vec4.new(w[0], w[1], w[2], w[3]);
                                weights = weights.norm();
                                cur_mesh_vertex_data.items[i].joint_weights = .{ weights.x(), weights.y(), weights.z(), weights.w() };
                            }
                        },
                        else => {},
                    }
                }
            }
            // 记录当前mesh在VertexBuffer中的偏移、大小等信息
            try self.meshes.append(
                allocator,
                .{
                    .vertex_offset = @intCast(vertex_data.items.len * @sizeOf(VertexAttribute)),
                    .vertex_size = @intCast(cur_mesh_vertex_data.items.len * @sizeOf(VertexAttribute)),
                    .vertex_count = @intCast(cur_mesh_vertex_data.items.len),
                    .index_offset = @intCast(index_data.items.len * @sizeOf(u16)),
                    .index_size = @intCast(cur_mesh_index_data.items.len * @sizeOf(u16)),
                    .index_count = @intCast(cur_mesh_index_data.items.len),
                },
            );
            // 将当前mesh数据追加到全局数组中
            try vertex_data.appendSlice(allocator, cur_mesh_vertex_data.items);
            try index_data.appendSlice(allocator, cur_mesh_index_data.items);
        }

        // 处理皮肤数据
        for (gltf.data.skins) |gltf_skin| {
            var skin = SkinData{
                .joints = try self.allocator.alloc(*SceneNode, gltf_skin.joints.len),
                .inverse_bind_matrices = try self.allocator.alloc(Mat4, gltf_skin.joints.len),
                .skeleton = if (gltf_skin.skeleton) |idx| self.nodes.items[idx] else null,
            };
            // 提取关节节点
            for (gltf_skin.joints, 0..) |joint_idx, i|
                skin.joints[i] = self.nodes.items[joint_idx];
            // 提取逆绑定矩阵
            if (gltf_skin.inverse_bind_matrices) |matrices_accessor| {
                const accessor = gltf.data.accessors[matrices_accessor];
                var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                var i: usize = 0;
                while (it.next()) |arr| : (i += 1)
                    skin.inverse_bind_matrices[i] = ArrToMat4(arr[0..16].*);
            } else { // 如果没有提供逆绑定矩阵，使用单位矩阵
                for (skin.inverse_bind_matrices) |*mat|
                    mat.* = Mat4.identity();
            }
            try self.skins.append(allocator, skin);
        }

        try self.loadAnimations(allocator, gltf);
    }

    // 新增方法：加载动画
    fn loadAnimations(self: *Model, allocator: std.mem.Allocator, gltf: *Gltf) !void {
        for (gltf.data.animations) |gltf_animation| {
            // 处理可能为null的动画名称
            const anim_name = if (gltf_animation.name) |name|
                try self.allocator.dupe(u8, name)
            else
                try std.fmt.allocPrint(self.allocator, "animation_{d}", .{self.animations.items.len});
            var clip = AnimationClip{
                .name = anim_name,
                .channels = std.ArrayList(AnimationChannel){},
                .samplers = std.ArrayList(AnimationSampler){},
                .duration = 0,
            };
            // 加载采样器
            for (gltf_animation.samplers) |gltf_sampler| {
                const input_accessor = gltf.data.accessors[gltf_sampler.input];
                const output_accessor = gltf.data.accessors[gltf_sampler.output];
                // 提取时间戳数据
                var input_data = try self.allocator.alloc(f32, @as(usize, @intCast(input_accessor.count)));
                var input_it = input_accessor.iterator(f32, gltf, gltf.glb_binary.?);
                var i: usize = 0;
                while (input_it.next()) |v| : (i += 1) {
                    input_data[i] = v[0];
                    if (v[0] > clip.duration) {
                        clip.duration = v[0];
                    }
                }
                // 提取输出数据
                var output_data = try self.allocator.alloc(f32, @as(usize, @intCast(output_accessor.count * 4))); // 假设最大是vec4
                var output_it = output_accessor.iterator(f32, gltf, gltf.glb_binary.?);
                i = 0;
                while (output_it.next()) |v| {
                    for (v) |component| {
                        output_data[i] = component;
                        i += 1;
                    }
                }
                try clip.samplers.append(allocator, .{
                    .input = input_data,
                    .output = output_data,
                    .interpolation = switch (gltf_sampler.interpolation) {
                        .linear => .linear,
                        .step => .step,
                        .cubicspline => .cubicspline,
                    },
                });
            }
            // 加载通道
            for (gltf_animation.channels) |gltf_channel| {
                const node = self.nodes.items[gltf_channel.target.node];

                try clip.channels.append(
                    allocator,
                    .{
                        .target_node = node,
                        .target_property = gltf_channel.target.property,
                        .sampler = &clip.samplers.items[gltf_channel.sampler],
                    },
                );
            }
            try self.animations.append(allocator, clip);
        }
    }
};

pub const AnimationPlayer = struct {
    current_time: f32 = 0,
    playback_speed: f32 = 1.0,
    is_playing: bool = false,
    loop: bool = true,
    current_clip: ?*AnimationClip = null,
    pub fn update(self: *AnimationPlayer, delta_time: f32) void {
        if (!self.is_playing or self.current_clip == null) return;
        self.current_time += delta_time * self.playback_speed;
        if (self.current_time > self.current_clip.?.duration) {
            if (self.loop) {
                self.current_time = 0;
            } else {
                self.current_time = self.current_clip.?.duration;
                self.is_playing = false;
            }
        }
        self.applyAnimation();
    }
    pub fn play(self: *AnimationPlayer, clip: *AnimationClip) void {
        self.current_clip = clip;
        self.current_time = 0;
        self.is_playing = true;
    }
    fn applyAnimation(self: *AnimationPlayer) void {
        const clip = self.current_clip orelse return;
        for (clip.channels.items) |channel| {
            const sampler = channel.sampler;
            const node = channel.target_node;
            // 找到当前时间对应的关键帧
            var prev_index: usize = 0;
            while (prev_index < sampler.input.len - 1 and sampler.input[prev_index + 1] <= self.current_time) {
                prev_index += 1;
            }
            if (prev_index >= sampler.input.len - 1) {
                prev_index = sampler.input.len - 2;
            }
            const next_index = prev_index + 1;
            const t0 = sampler.input[prev_index];
            const t1 = sampler.input[next_index];
            const alpha = if (t0 == t1) 0.0 else (self.current_time - t0) / (t1 - t0);
            // 根据不同的插值类型处理
            switch (sampler.interpolation) {
                .linear => {
                    switch (channel.target_property) {
                        .translation => {
                            const prev = Vec3.new(
                                sampler.output[prev_index * 3],
                                sampler.output[prev_index * 3 + 1],
                                sampler.output[prev_index * 3 + 2],
                            );
                            const next = Vec3.new(
                                sampler.output[next_index * 3],
                                sampler.output[next_index * 3 + 1],
                                sampler.output[next_index * 3 + 2],
                            );
                            node.local_translation = Vec3.lerp(prev, next, alpha);
                        },
                        .rotation => {
                            const prev = Quat.new(
                                sampler.output[prev_index * 4 + 3],
                                sampler.output[prev_index * 4],
                                sampler.output[prev_index * 4 + 1],
                                sampler.output[prev_index * 4 + 2],
                            );
                            const next = Quat.new(
                                sampler.output[next_index * 4 + 3],
                                sampler.output[next_index * 4],
                                sampler.output[next_index * 4 + 1],
                                sampler.output[next_index * 4 + 2],
                            );
                            node.local_rotation = Quat.slerp(prev, next, alpha);
                        },
                        .scale => {
                            const prev = Vec3.new(
                                sampler.output[prev_index * 3],
                                sampler.output[prev_index * 3 + 1],
                                sampler.output[prev_index * 3 + 2],
                            );
                            const next = Vec3.new(
                                sampler.output[next_index * 3],
                                sampler.output[next_index * 3 + 1],
                                sampler.output[next_index * 3 + 2],
                            );
                            node.local_scale = Vec3.lerp(prev, next, alpha);
                        },
                        .weights => {
                            // 处理 morph target 权重
                            // 这里需要根据你的模型实现
                        },
                    }
                },
                .step => {
                    // 直接使用前一关键帧的值
                    switch (channel.target_property) {
                        .translation => {
                            node.local_translation = Vec3.new(
                                sampler.output[prev_index * 3],
                                sampler.output[prev_index * 3 + 1],
                                sampler.output[prev_index * 3 + 2],
                            );
                        },
                        .rotation => {
                            node.local_rotation = Quat.new(
                                sampler.output[prev_index * 4 + 3],
                                sampler.output[prev_index * 4],
                                sampler.output[prev_index * 4 + 1],
                                sampler.output[prev_index * 4 + 2],
                            );
                        },
                        .scale => {
                            node.local_scale = Vec3.new(
                                sampler.output[prev_index * 3],
                                sampler.output[prev_index * 3 + 1],
                                sampler.output[prev_index * 3 + 2],
                            );
                        },
                        .weights => {
                            // 处理 morph target 权重
                        },
                    }
                },
                .cubicspline => {
                    // 三次样条插值 - 更复杂的插值方式
                    // 实现类似上面的线性插值，但需要考虑切线
                    // 这里需要根据你的需求实现
                },
            }
            // 更新节点的局部矩阵
            const t_mat = Mat4.fromTranslate(node.local_translation);
            const r_mat = node.local_rotation.toMat4();
            const s_mat = Mat4.fromScale(node.local_scale);
            node.local_matrix = Mat4.mul(t_mat, Mat4.mul(r_mat, s_mat));
        }
    }
};

pub const ModelManager = struct {
    allocator: std.mem.Allocator,
    vertex_buffer: wgpu.WGPUBuffer,
    index_buffer: wgpu.WGPUBuffer,
    models: std.StringHashMap(Model),
    pub fn init(gctx: Gctx, allocator: std.mem.Allocator) !@This() {
        // var all_vertex_data = std.ArrayList(VertexAttribute).init(allocator);
        var all_vertex_data = std.ArrayList(VertexAttribute){};
        defer all_vertex_data.deinit(allocator);
        // var all_index_data = std.ArrayList(u16).init(allocator);
        var all_index_data = std.ArrayList(u16){};
        defer all_index_data.deinit(allocator);
        var models = std.StringHashMap(Model).init(allocator);
        // 打开models目录
        var models_dir = try std.fs.cwd().openDir("resources/models", .{ .iterate = true });
        defer models_dir.close();
        var dir_iter = try models_dir.walk(allocator);
        defer dir_iter.deinit();
        // 遍历目录中的所有文件
        while (try dir_iter.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".glb")) continue;
            // 加载并解析模型
            const file_path = try std.fs.path.join(allocator, &.{ "resources/models", entry.basename });
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
            // 创建模型，让模型填充vertex_data和index_data
            var model = Model.init(allocator);
            try model.loadFromGltf(
                allocator,
                &gltf,
                &all_vertex_data,
                &all_index_data,
            );
            // 记录当前模型的信息
            const model_name = try allocator.dupe(u8, std.fs.path.stem(entry.basename));
            try models.put(model_name, model);
        }
        const vertex_buffer_desc = wgpu.WGPUBufferDescriptor{
            .size = @sizeOf(VertexAttribute) * all_vertex_data.items.len,
            .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Vertex,
            .mappedAtCreation = 0,
        };
        const vertex_buffer = wgpu.wgpuDeviceCreateBuffer(
            gctx.device,
            &vertex_buffer_desc,
        );
        wgpu.wgpuQueueWriteBuffer(
            gctx.queue,
            vertex_buffer,
            0,
            @ptrCast(all_vertex_data.items.ptr),
            vertex_buffer_desc.size,
        );

        const index_buffer_desc = wgpu.WGPUBufferDescriptor{
            .size = @sizeOf(u16) * all_index_data.items.len,
            .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Index,
            .mappedAtCreation = 0,
        };
        const index_buffer = wgpu.wgpuDeviceCreateBuffer(
            gctx.device,
            &index_buffer_desc,
        );
        wgpu.wgpuQueueWriteBuffer(
            gctx.queue,
            index_buffer,
            0,
            @ptrCast(all_index_data.items.ptr),
            index_buffer_desc.size,
        );

        return ModelManager{
            .allocator = allocator,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .models = models,
        };
    }
    pub fn deinit(self: *ModelManager) void {
        var it = self.models.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.models.deinit();
        wgpu.wgpuBufferRelease(self.vertex_buffer);
        wgpu.wgpuBufferRelease(self.index_buffer);
    }
};

pub fn ArrToMat4(arr: [16]f32) Mat4 {
    return .{
        .data = [4][4]f32{
            .{ arr[0], arr[1], arr[2], arr[3] },
            .{ arr[4], arr[5], arr[6], arr[7] },
            .{ arr[8], arr[9], arr[10], arr[11] },
            .{ arr[12], arr[13], arr[14], arr[15] },
        },
    };
}

const wgpu = @import("cimprots.zig").wgpu;
const Gctx = @import("gctx.zig");
const std = @import("std");
const Gltf = @import("zgltf").Gltf;
const VertexAttribute = @import("shader_types.zig").VertexAttribute;
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Quat = Algebra.Quat;
const Vec4 = Algebra.Vec4;
const GpuMesh = @import("shader_types.zig").GpuMesh;
