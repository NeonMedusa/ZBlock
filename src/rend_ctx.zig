const import = @import("imports.zig");
const ECS = import.ECS;
const GltfData = Gltf.Data;
const ZigImg = import.zigimg;
const RenderPipeline = @import("render_pipeline.zig");
const Game = @import("game.zig");

const TextureRes = struct {
    texture: Wgpu.WGPUTexture = null,
    view: Wgpu.WGPUTextureView = null,
};

const Mesh = struct {
    primitives: []Primitive,
};

pub const Primitive = struct {
    vertex_buffer: Wgpu.WGPUBuffer,
    index_buffer: Wgpu.WGPUBuffer,
    index_count: u32,
    // 设计为不可为空，因为Wgpu.WGPUTexture和Wgpu.WGPUTextureView是可空类型
    material: Material,
};

const MaterialConstants = struct {
    // 标志位
    has_base_color: u32 = 0,
    has_normal: u32 = 0,
    _padding: [2]f32 = undefined,
};

const Material = struct {
    color_texture: TextureRes, // 设计为不可为空，因为Wgpu.WGPUTexture和Wgpu.WGPUTextureView是可空类型
    normal_texture: TextureRes, // 设计为不可为空，因为Wgpu.WGPUTexture和Wgpu.WGPUTextureView是可空类型
    uniform_buffer: Wgpu.WGPUBuffer, // 存储 MaterialConstants
    bind_group: Wgpu.WGPUBindGroup, // 绑定组（根据纹理组合和布局创建）
};

const Node = struct {
    parent: ?usize,
    matrix: Mat4,
    mesh: ?usize,
};

pub const Model = struct {
    meshes: []Mesh, // 对应gltf.data.meshes
    textures_res: []TextureRes, //对应gltf.data.textures
    anim_textures: []TextureRes, //对应gltf.data.animations
    materials: []Material, //对应gltf.data.materials
    nodes: []Node, //简化的nodes结构，对应gltf.data.nodes
    pub fn load(
        allocator: std.mem.Allocator,
        gctx: Gctx,
        name: []const u8,
        pipeline: RenderPipeline,
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
            var img = try ZigImg.Image.fromMemory(allocator, img_source.data.?);
            defer img.deinit(allocator);

            // 转换为 RGBA32 格式（如果不是的话）
            if (img.pixels != .rgba32) try img.convert(allocator, .rgba32);

            // 现在可以安全地访问 rgba32
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
                &Wgpu.WGPUTexelCopyTextureInfo{
                    .texture = texture,
                    .mipLevel = 0,
                },
                img.pixels.rgba32.ptr,
                img.pixels.rgba32.len * @sizeOf(ZigImg.color.Rgba32),
                &Wgpu.struct_WGPUTexelCopyBufferLayout{
                    .offset = 0,
                    .bytesPerRow = @intCast(img.width * 4),
                    .rowsPerImage = @intCast(img.height),
                },
                &Wgpu.struct_WGPUExtent3D{
                    .width = @intCast(img.width),
                    .height = @intCast(img.height),
                    .depthOrArrayLayers = 1,
                },
            );

            const texture_view = Wgpu.wgpuTextureCreateView(
                texture,
                &Wgpu.struct_WGPUTextureViewDescriptor{
                    .aspect = Wgpu.WGPUTextureAspect_All,
                    .baseArrayLayer = 0,
                    .arrayLayerCount = texture_desc.size.depthOrArrayLayers,
                    .baseMipLevel = 0,
                    .mipLevelCount = 1,
                    .dimension = Wgpu.WGPUTextureViewDimension_2D, // 改为 _2D，不是 _2DArray
                    .format = texture_desc.format,
                },
            );

            model.textures_res[i] = .{
                .texture = texture,
                .view = texture_view,
            };
        }

        // 为材质绑定纹理
        model.materials = try allocator.alloc(Material, gltf.data.materials.len);
        const default_texture = createDefaultTexture(gctx) catch unreachable;
        for (gltf.data.materials, 0..) |gltf_meterial, i| {
            // 材质常量，后面会写入到material_uniform_buffer
            var material_constants = MaterialConstants{
                .has_base_color = 0,
                .has_normal = 0,
            };
            // 绑定色彩纹理
            if (gltf_meterial.metallic_roughness.base_color_texture) |color_tex_info| {
                material_constants.has_base_color = 1;
                model.materials[i].color_texture = model.textures_res[color_tex_info.index];
            } else { // 使用默认纹理
                model.materials[i].color_texture = default_texture;
            }
            // 绑定法线纹理
            if (gltf_meterial.normal_texture) |normal_tex_info| {
                material_constants.has_normal = 1;
                model.materials[i].normal_texture = model.textures_res[normal_tex_info.index];
            } else { // 使用默认纹理
                model.materials[i].normal_texture = default_texture;
            }
            // 材质常量缓冲区
            const material_uniform_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
                .size = @sizeOf(MaterialConstants),
                .usage = Wgpu.WGPUBufferUsage_Uniform | Wgpu.WGPUBufferUsage_CopyDst,
                .mappedAtCreation = 0,
            });
            Wgpu.wgpuQueueWriteBuffer(
                gctx.queue,
                material_uniform_buffer,
                0,
                &material_constants,
                Wgpu.wgpuBufferGetSize(material_uniform_buffer),
            );
            model.materials[i].uniform_buffer = material_uniform_buffer;
            // 创建绑定组（实际渲染时的纹理是在这里绑定的，或许我们可以删掉Material中的color_texture和normal_texture）
            // 又或者应该将创建绑定组的工作外包出去，但为了简单快速的验证代码，暂时先这样
            model.materials[i].bind_group = Wgpu.wgpuDeviceCreateBindGroup(gctx.device, &Wgpu.WGPUBindGroupDescriptor{
                .layout = pipeline.material_bgl,
                .entryCount = pipeline.entry_count,
                .entries = &[_]Wgpu.WGPUBindGroupEntry{
                    .{ // texture_uniform,我们刚刚创建的
                        .binding = 0,
                        .buffer = material_uniform_buffer,
                        .size = Wgpu.wgpuBufferGetSize(material_uniform_buffer),
                    },
                    .{ // color_texture，我们刚刚绑定的
                        .binding = 1,
                        .textureView = model.materials[i].color_texture.view orelse null,
                    },
                    .{ // normal_texture，我们刚刚绑定的
                        .binding = 2,
                        .textureView = model.materials[i].normal_texture.view orelse null,
                    },
                },
            });
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
                    var it = accessor.iterator(u16, &gltf, gltf.glb_binary.?);
                    while (it.next()) |indice|
                        try index_data.append(allocator, indice[0]);
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
                                const pos = [3]f32{ v[0], v[1], v[2] };
                                try vertex_data.append(allocator, .{
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
                                vertex_data.items[i].color_uv = .{ t[0], t[1] };
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
        for (self.textures_res) |tex| {
            if (tex.texture) |texture| {
                Wgpu.wgpuTextureRelease(texture);
            }
            if (tex.view) |view| {
                Wgpu.wgpuTextureViewRelease(view);
            }
        }
        allocator.free(self.textures_res);

        // 2. 释放动画纹理（如果有的话）
        for (self.anim_textures) |tex| {
            if (tex.texture) |texture| {
                Wgpu.wgpuTextureRelease(texture);
            }
            if (tex.view) |view| {
                Wgpu.wgpuTextureViewRelease(view);
            }
        }
        allocator.free(self.anim_textures);

        // 3. 释放材质资源
        for (self.materials) |material| {
            // 释放 uniform buffer
            if (material.uniform_buffer) |buffer| {
                Wgpu.wgpuBufferRelease(buffer);
            }
            // 释放绑定组
            if (material.bind_group) |bind_group| {
                Wgpu.wgpuBindGroupRelease(bind_group);
            }
            // 注意：color_texture 和 normal_texture 是引用，不在这里释放
            // 它们指向 textures_res 中的纹理，会在步骤1中释放
        }
        allocator.free(self.materials);

        // 4. 释放网格和 primitive 资源
        for (self.meshes) |mesh| {
            for (mesh.primitives) |primitive| {
                // 释放顶点缓冲区
                if (primitive.vertex_buffer) |buffer| {
                    Wgpu.wgpuBufferRelease(buffer);
                }
                // 释放索引缓冲区
                if (primitive.index_buffer) |buffer| {
                    Wgpu.wgpuBufferRelease(buffer);
                }
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

pub const ResManager = struct {
    const MAX_ENTITIES = 500; // 限制最大渲染游戏实体数
    const MAX_INSTANCES = 3 * MAX_ENTITIES; // 限制最大渲染实例数

    scene_uniform_buffer: Wgpu.WGPUBuffer, // 场景常量缓冲区
    entities_data: []EntityData,
    entities_data_buffer: Wgpu.WGPUBuffer, // 游戏实体的世界矩阵缓冲区
    instances_data: []InstanceData,
    instances_data_buffer: Wgpu.WGPUBuffer, // 渲染实例的世界矩阵缓冲区

    pub fn init(allocator: std.mem.Allocator, gctx: Gctx) !@This() {
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
        const instances_data = try allocator.alloc(InstanceData, MAX_ENTITIES);
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
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        Wgpu.wgpuBufferRelease(self.scene_uniform_buffer);
        allocator.free(self.entities_data);
        Wgpu.wgpuBufferRelease(self.entities_data_buffer);
        allocator.free(self.instances_data);
        Wgpu.wgpuBufferRelease(self.instances_data_buffer);
    }
};

fn createDefaultTexture(gctx: Gctx) !TextureRes {
    // 创建一个 1x1 的纹理
    const white_pixel = [_]u8{ 255, 255, 255, 255 };

    const texture_desc = Wgpu.WGPUTextureDescriptor{
        .usage = Wgpu.WGPUTextureUsage_CopyDst | Wgpu.WGPUTextureUsage_TextureBinding,
        .dimension = Wgpu.WGPUTextureDimension_2D,
        .size = .{
            .width = 1,
            .height = 1,
            .depthOrArrayLayers = 1,
        },
        .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
    };

    const texture = Wgpu.wgpuDeviceCreateTexture(gctx.device, &texture_desc);

    Wgpu.wgpuQueueWriteTexture(
        gctx.queue,
        &Wgpu.WGPUTexelCopyTextureInfo{
            .texture = texture,
            .mipLevel = 0,
        },
        &white_pixel,
        @sizeOf(@TypeOf(white_pixel)),
        &Wgpu.struct_WGPUTexelCopyBufferLayout{
            .offset = 0,
            .bytesPerRow = 4, // 1 pixel * 4 bytes
            .rowsPerImage = 1,
        },
        &Wgpu.struct_WGPUExtent3D{
            .width = 1,
            .height = 1,
            .depthOrArrayLayers = 1,
        },
    );

    const texture_view = Wgpu.wgpuTextureCreateView(
        texture,
        &Wgpu.struct_WGPUTextureViewDescriptor{
            .aspect = Wgpu.WGPUTextureAspect_All,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .dimension = Wgpu.WGPUTextureViewDimension_2D,
            .format = texture_desc.format,
        },
    );

    return TextureRes{
        .texture = texture,
        .view = texture_view,
    };
}

pub const SceneUniform = struct {
    proj_matrix: Mat4 = undefined, // 投影矩阵
    view_matrix: Mat4 = undefined, // 视图矩阵
    time: f32 = undefined, // 当前时间
    _padding: [3]f32 = undefined, // 需要对齐到16字节
    pub fn init(window: Window) @This() {
        const aspect_ratio: f32 = window.width / window.height;
        const proj_matrix = Mat4.perspective(70, aspect_ratio, 0.001, 100);
        const view_matrix = Mat4.lookAt(Vec3.new(0.0, 0.0, -3.0), Vec3.zero(), Vec3.up());
        return .{
            .proj_matrix = proj_matrix,
            .view_matrix = view_matrix,
            .time = window.time,
        };
    }
};

pub const VertexAttribute = struct {
    position: [3]f32, //顶点位置
    color_uv: [2]f32 = .{ 0, 0 }, //纹理UV
    joint_indices: [4]u32 = .{ 0, 0, 0, 0 }, // 骨骼矩阵索引
    joint_weights: [4]f32 = .{ 1, 0, 0, 0 }, // 骨骼矩阵权重
};

pub const EntityData = struct {
    transform: Mat4, //实体的世界变换
};

pub const InstanceData = struct {
    transform: Mat4, //渲染实例的变换
    entity_idx: u32, // 该渲染实例属于哪个游戏实体
    _padding: [3]f32 = undefined,
};

const std = @import("std");
const Gctx = @import("gctx.zig");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Vec4 = Algebra.Vec4;
const Quat = Algebra.Quat;
const Window = @import("window.zig");
const Gltf = @import("zgltf").Gltf;
const Wgpu = @import("imports.zig").Wgpu;
const zigimg = @import("zigimg");
