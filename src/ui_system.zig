// ui_system.zig
const UiSystem = @This();
allocator: std.mem.Allocator,
render_pipeline: UiRenderPipeline,
game_ptr: *Game,
// ui通用缓冲区
ubo: UiUniform,
uniform_buffer: Wgpu.WGPUBuffer,
// 顶点/索引缓冲区限制
max_vertices: usize,
max_indices: usize,
// 顶点/索引数据，每帧更新
frame_vertices: []UiVertex,
frame_indices: []u32,
// 追踪实际使用的数量
vertex_count: usize,
index_count: usize,
// 顶点/索引缓冲区，每帧更新
vertex_buffer: Wgpu.WGPUBuffer,
index_buffer: Wgpu.WGPUBuffer,
// 最基本的按钮
pub fn button(self: *UiSystem, x: f32, y: f32) bool {
    const input = self.game_ptr.input;
    const width: f32 = 100;
    const height: f32 = 30;
    // 根据鼠标位置调整状态
    const mouse_pos = input.getCursorPos();
    const is_hovered = (mouse_pos.x >= x and mouse_pos.x <= x + width and
        mouse_pos.y >= y and mouse_pos.y <= y + height);
    const is_clicked = is_hovered and input.isMouseButtonDown(.mouse_left);
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
// 析构函数
pub fn deinit(self: *@This()) void {
    // 释放CPU端内存
    self.allocator.free(self.frame_vertices);
    self.allocator.free(self.frame_indices);

    Wgpu.wgpuBufferRelease(self.vertex_buffer);
    Wgpu.wgpuBufferRelease(self.index_buffer);
    Wgpu.wgpuBufferRelease(self.uniform_buffer);
}
pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, game: *Game) !UiSystem {
    var self: UiSystem = undefined;

    const max_vertices = 65536;
    const max_indices = 131072;

    const frame_vertices = try allocator.alloc(UiVertex, max_vertices);
    const frame_indices = try allocator.alloc(u32, max_indices);

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
    const uniform_buffer = Wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
        .size = @sizeOf(UiUniform),
        .usage = Wgpu.WGPUBufferUsage_Uniform | Wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });
    const ubo = UiUniform.init(game.window);

    self.allocator = allocator;
    self.vertex_buffer = vertex_buffer;
    self.index_buffer = index_buffer;
    self.game_ptr = game;
    self.frame_vertices = frame_vertices;
    self.frame_indices = frame_indices;
    self.max_vertices = max_vertices;
    self.max_indices = max_indices;
    self.ubo = ubo;
    self.uniform_buffer = uniform_buffer;

    self.frame_vertices = frame_vertices;
    self.frame_indices = frame_indices;
    self.vertex_count = 0;
    self.index_count = 0;

    //注：先创建好所有buffer，再创建渲染管线
    self.render_pipeline = try UiRenderPipeline.init(gctx, "resources/shaders/ui_render_shader.wgsl", &self);
    return self;
}

// 每帧开始时重置数据
pub fn beginFrame(self: *@This()) void {
    // 重置计数器，复用内存
    self.vertex_count = 0;
    self.index_count = 0;
}

// 每帧结束时更新GPU缓冲区
pub fn endFrame(self: *@This(), gctx: *Gctx) !void {
    if (self.index_count == 0) return;
    // 只上传实际使用的数据
    Wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        self.vertex_buffer,
        0,
        self.frame_vertices.ptr,
        self.vertex_count * @sizeOf(UiVertex),
    );
    Wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        self.index_buffer,
        0,
        self.frame_indices.ptr,
        self.index_count * @sizeOf(u32),
    );
    Wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        self.uniform_buffer,
        0,
        &self.ubo,
        Wgpu.wgpuBufferGetSize(self.uniform_buffer),
    );
}

// 矩形绘制
pub fn drawRect(self: *UiSystem, x: f32, y: f32, width: f32, height: f32, color: [4]f32) void {
    // 检查是否有足够空间
    if (self.vertex_count + 4 > self.max_vertices or self.index_count + 6 > self.max_indices) {
        std.debug.print("UI缓冲区溢出！\n", .{});
        return;
    }
    const base_vertex = @as(u32, @intCast(self.vertex_count));
    // 直接写入预分配的内存
    self.frame_vertices[self.vertex_count] = .{ .pos = [3]f32{ x, y, 0 }, .color = color };
    self.frame_vertices[self.vertex_count + 1] = .{ .pos = [3]f32{ x + width, y, 0 }, .color = color };
    self.frame_vertices[self.vertex_count + 2] = .{ .pos = [3]f32{ x + width, y + height, 0 }, .color = color };
    self.frame_vertices[self.vertex_count + 3] = .{ .pos = [3]f32{ x, y + height, 0 }, .color = color };

    self.frame_indices[self.index_count] = base_vertex + 0;
    self.frame_indices[self.index_count + 1] = base_vertex + 1;
    self.frame_indices[self.index_count + 2] = base_vertex + 2;
    self.frame_indices[self.index_count + 3] = base_vertex + 0;
    self.frame_indices[self.index_count + 4] = base_vertex + 2;
    self.frame_indices[self.index_count + 5] = base_vertex + 3;

    self.vertex_count += 4;
    self.index_count += 6;
}
// UI顶点属性
pub const UiVertex = struct {
    pos: [3]f32, //顶点位置
    color: [4]f32, //背景颜色
};
// 渲染管线
const UiRenderPipeline = struct {
    handle: Wgpu.WGPURenderPipeline,
    bind_group_layout: Wgpu.WGPUBindGroupLayout,
    bind_group: Wgpu.WGPUBindGroup,
    pipeline_layout: Wgpu.WGPUPipelineLayout,
    shader_module: Wgpu.WGPUShaderModule,
    pub fn init(gctx: *Gctx, shader_file_path: []const u8, ui_system: *UiSystem) !@This() {
        const shader_module = try gctx.createShaderModule(shader_file_path);
        // 创建 binding group
        const bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
            .{ // uniform
                .binding = 0,
                .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
                .buffer = .{
                    .type = Wgpu.WGPUBufferBindingType_Uniform,
                    .hasDynamicOffset = 0,
                },
            },
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
                .{ // uniform
                    .binding = 0,
                    .buffer = ui_system.uniform_buffer,
                    .offset = 0,
                    .size = Wgpu.wgpuBufferGetSize(ui_system.uniform_buffer),
                },
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

pub const UiUniform = struct {
    ortho_matrix: Mat4,
    pub fn init(window: Window) @This() {
        const ortho_matrix = Mat4.orthographic(
            0,
            window.width,
            window.height,
            0,
            -1.0,
            1.0,
        );
        return @This(){
            .ortho_matrix = ortho_matrix,
        };
    }
};

const std = @import("std");
const Gctx = @import("gctx.zig");
const Game = @import("game.zig");
const Gltf = @import("zgltf");
const Wgpu = @import("imports.zig").Wgpu;
const Algebra = @import("algebra.zig");
const Mat4 = Algebra.Mat4;
const Window = @import("imports.zig").Window;
