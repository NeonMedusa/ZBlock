//ui_system.zig
const UiSystem = @This();
allocator: std.mem.Allocator,
render_pipeline: UiRenderPipeline,
window: *Window,
// 顶点/索引缓冲区限制
max_vertices: usize,
max_indices: usize,
// 顶点/索引数据，每帧更新
frame_vertices: std.ArrayList(UiVertex),
frame_indices: std.ArrayList(u32),
// 顶点/索引缓冲区，每帧更新
vertex_buffer: Wgpu.WGPUBuffer,
index_buffer: Wgpu.WGPUBuffer,
// 析构函数
pub fn deinit(self: *@This()) void {
    self.frame_vertices.deinit(self.allocator);
    self.frame_indices.deinit(self.allocator);
    Wgpu.wgpuBufferRelease(self.vertex_buffer);
    Wgpu.wgpuBufferRelease(self.index_buffer);
}
pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, window: *Window) !UiSystem {
    const max_vertices = 65536;
    const max_indices = 131072;
    const vertex_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
        .size = max_vertices * @sizeOf(UiVertex),
        .usage = Wgpu.WGPUBufferUsage_CopyDst | Wgpu.WGPUBufferUsage_Vertex,
        .mappedAtCreation = 0,
    });
    const index_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
        .size = max_indices * @sizeOf(u32),
        .usage = Wgpu.WGPUBufferUsage_CopyDst | Wgpu.WGPUBufferUsage_Index,
        .mappedAtCreation = 0,
    });
    return UiSystem{
        .allocator = allocator,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .render_pipeline = try UiRenderPipeline.init(gctx, "resources/shaders/ui_render_shader.wgsl"),
        .window = window,
        .frame_vertices = std.ArrayList(UiVertex){},
        .frame_indices = std.ArrayList(u32){},
        .max_vertices = max_vertices,
        .max_indices = max_indices,
    };
}

// 每帧开始时的重置
pub fn beginFrame(self: *@This()) void {
    self.frame_vertices.clearRetainingCapacity();
    self.frame_indices.clearRetainingCapacity();
}

// 修改 endFrame，只更新缓冲区，不渲染
pub fn endFrame(self: *@This(), gctx: *Gctx) !void {
    if (self.frame_vertices.items.len == 0) return;
    // 只更新GPU缓冲区，不执行渲染
    try self.updateGpuBuffers(gctx);
}

fn updateGpuBuffers(self: *@This(), gctx: *const Gctx) !void {
    // 更新顶点缓冲区
    if (self.frame_vertices.items.len > 0) {
        Wgpu.wgpuQueueWriteBuffer(
            gctx.queue,
            self.vertex_buffer,
            0,
            self.frame_vertices.items.ptr,
            @as(usize, @intCast(self.frame_vertices.items.len)) * @sizeOf(UiVertex),
        );
    }
    // 更新索引缓冲区
    Wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        self.index_buffer,
        0,
        self.frame_indices.items.ptr,
        @as(usize, @intCast(self.frame_indices.items.len)) * @sizeOf(u32),
    );
}

pub fn button(self: *UiSystem, x: f32, y: f32) bool {
    const width: f32 = 100;
    const height: f32 = 30;

    const mouse_pos = self.window.getCursorPos();
    const is_hovered = (mouse_pos.x >= x and mouse_pos.x <= x + width and
        mouse_pos.y >= y and mouse_pos.y <= y + height);
    const is_clicked = is_hovered and self.window.isMousePressed(.mouse_left);
    // 根据状态选择颜色
    const color = if (is_clicked) [4]f32{ 0.2, 0.2, 0.8, 1.0 } else if (is_hovered) [4]f32{ 0.8, 0.8, 0.2, 1.0 } else [4]f32{ 0.5, 0.5, 0.5, 1.0 };
    // 绘制按钮背景
    self.drawRect(x, y, width, height, color);
    // 绘制边框
    const border_color = [4]f32{ 0.1, 0.1, 0.1, 1.0 };
    self.drawRect(x, y, width, 1, border_color); // 上边框
    self.drawRect(x, y + height - 1, width, 1, border_color); // 下边框
    self.drawRect(x, y, 1, height, border_color); // 左边框
    self.drawRect(x + width - 1, y, 1, height, border_color); // 右边框
    // TODO: 添加文本渲染
    // self.drawText(x + 5, y + 5, text, [4]f32{ 1, 1, 1, 1 });
    return is_clicked;
}

// 矩形绘制
pub fn drawRect(self: *UiSystem, x: f32, y: f32, width: f32, height: f32, color: [4]f32) void {
    const base_vertex = @as(u16, @intCast(self.frame_vertices.items.len));
    // 定义矩形的4个顶点（Z坐标可以用于深度排序）
    const vertices = [_]UiVertex{
        .{ .pos = [3]f32{ x, y, 0 }, .color = color }, // 左下
        .{ .pos = [3]f32{ x + width, y, 0 }, .color = color }, // 右下
        .{ .pos = [3]f32{ x + width, y + height, 0 }, .color = color }, // 右上
        .{ .pos = [3]f32{ x, y + height, 0 }, .color = color }, // 左上
    };
    // 定义三角形的索引（两个三角形组成矩形）
    const indices = [_]u32{
        base_vertex + 0, base_vertex + 1, base_vertex + 2, // 第一个三角形
        base_vertex + 0, base_vertex + 2, base_vertex + 3, // 第二个三角形
    };
    // 添加到帧数据中
    self.frame_vertices.appendSlice(self.allocator, &vertices) catch return;
    self.frame_indices.appendSlice(self.allocator, &indices) catch return;
}

// UI顶点属性
pub const UiVertex = struct {
    pos: [3]f32, //顶点位置
    color: [4]f32, //背景颜色
};

const UiRenderPipeline = struct {
    handle: Wgpu.WGPURenderPipeline,
    bind_group_layout: Wgpu.WGPUBindGroupLayout,
    bind_group: Wgpu.WGPUBindGroup,
    pipeline_layout: Wgpu.WGPUPipelineLayout,
    shader_module: Wgpu.WGPUShaderModule,
    pub fn init(gctx: *Gctx, shader_file_path: []const u8) !@This() {
        const shader_module = try gctx.createShaderModule(shader_file_path);
        // 创建 binding group
        const bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
            // entries
        };
        const bind_group_layout = Wgpu.wgpuDeviceCreateBindGroupLayout(
            gctx.device,
            &Wgpu.WGPUBindGroupLayoutDescriptor{
                .entryCount = bgl_entries.len,
                .entries = &bgl_entries,
            },
        );
        const bind_group = Wgpu.wgpuDeviceCreateBindGroup(gctx.device, &Wgpu.WGPUBindGroupDescriptor{
            .layout = bind_group_layout,
            .entryCount = bgl_entries.len,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                //entries
            },
        });
        // 创建渲染管线
        const pipeline_layout = Wgpu.wgpuDeviceCreatePipelineLayout(gctx.device, &Wgpu.WGPUPipelineLayoutDescriptor{
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &bind_group_layout,
        });
        const attributes = Gctx.generateVertexAttributes(UiVertex);
        const pipeline_desc = Wgpu.WGPURenderPipelineDescriptor{
            .layout = pipeline_layout, // 添加管线布局
            .vertex = .{
                .bufferCount = 1,
                .buffers = &Wgpu.WGPUVertexBufferLayout{
                    .arrayStride = @sizeOf(UiVertex),
                    .stepMode = Wgpu.WGPUVertexStepMode_Vertex,
                    .attributeCount = attributes.len,
                    .attributes = &attributes,
                },
                .module = shader_module,
                .entryPoint = .{
                    .data = "vs_main",
                    .length = 7,
                },
            },
            .primitive = .{
                .topology = Wgpu.WGPUPrimitiveTopology_TriangleList,
            },
            .fragment = &Wgpu.WGPUFragmentState{
                .module = shader_module,
                .entryPoint = .{
                    .data = "fs_main",
                    .length = 7,
                },
                .targetCount = 1,
                .targets = &Wgpu.WGPUColorTargetState{
                    .format = Wgpu.WGPUTextureFormat_BGRA8UnormSrgb,
                    .writeMask = Wgpu.WGPUColorWriteMask_All,
                },
            },
            .multisample = .{
                .count = 1,
                .mask = Wgpu.WGPUColorWriteMask_All,
            },
            .depthStencil = &Wgpu.WGPUDepthStencilState{
                .format = Wgpu.WGPUTextureFormat_Depth24Plus,
                .depthWriteEnabled = 0, // 重要：UI不写入深度
                .depthCompare = Wgpu.WGPUCompareFunction_Always, // 总是通过深度测试
                .stencilFront = .{},
                .stencilBack = .{},
                .stencilReadMask = 0,
                .stencilWriteMask = 0,
                .depthBias = 0,
                .depthBiasSlopeScale = 0.0,
                .depthBiasClamp = 0.0,
            },
        };
        const pipeline = Wgpu.wgpuDeviceCreateRenderPipeline(gctx.device, &pipeline_desc);
        return @This(){
            .handle = pipeline,
            .bind_group_layout = bind_group_layout,
            .bind_group = bind_group,
            .pipeline_layout = pipeline_layout,
            .shader_module = shader_module,
        };
    }
    pub fn deinit(self: @This()) void {
        Wgpu.wgpuRenderPipelineRelease(self.handle);
        Wgpu.wgpuBindGroupLayoutRelease(self.bind_group_layout);
        Wgpu.wgpuBindGroupRelease(self.bind_group);
        Wgpu.wgpuPipelineLayoutRelease(self.pipeline_layout);
        Wgpu.wgpuShaderModuleRelease(self.shader_module);
    }
};

const std = @import("std");
const Gctx = @import("gctx.zig");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");
const Gltf = @import("zgltf");
const Wgpu = @import("cimports.zig").Wgpu;
const ResourceManager = @import("resource_manager.zig");
