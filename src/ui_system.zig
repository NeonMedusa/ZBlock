// ui_system.zig
const UiSystem = @This();

// SDF 图集常量
const GLYPH_SIZE: u32 = 64; // 每个字形 SDF 槽位尺寸（宽高一致）
const ATLAS_SIZE: u32 = 2048; // 图集总尺寸（R8 单通道，4MB）
const GLYPHS_PER_ROW: u32 = ATLAS_SIZE / GLYPH_SIZE;
const GLYPH_SLOTS: u32 = GLYPHS_PER_ROW * GLYPHS_PER_ROW;
const ATLAS_ROW_STRIDE: u32 = 256; // wgpuQueueWriteTexture 要求字节行对齐到 256

// SDF 生成参数
const SDF_PADDING: c_int = 4;
const SDF_ONEDGE: u8 = 128;
const SDF_PIXEL_DIST_SCALE: f32 = 64.0; // 64 值单位 = 1 像素距离
const SDF_SCALE_HEIGHT: f32 = 64.0; // 生成 SDF 的基准字号

// 一个图集中的字形槽位
const GlyphSlot = struct {
    codepoint: u21, // Unicode 码点
    advance: i32, // font-units 的 advance width
    lsb: i32, // font-units 的 left side bearing
    sdf_width: c_int, // SDF 位图宽度（像素）
    sdf_height: c_int, // SDF 位图高度（像素）
    sdf_xoff: c_int, // SDF 位图 x 偏移
    sdf_yoff: c_int, // SDF 位图 y 偏移
};

allocator: std.mem.Allocator,
render_pipeline: UiRenderPipeline,
game_ptr: *Game,
// 字体与 SDF 图集
font_data: []u8,
font_info: Stb.stbtt_fontinfo,
ascent: i32,
descent: i32,
line_gap: i32,
canonical_scale: f32, // 生成 SDF 时用的字体缩放比
sdf_texture: Wgpu.WGPUTexture,
sdf_texture_view: Wgpu.WGPUTextureView,
sdf_sampler: Wgpu.WGPUSampler,
glyph_slots: [GLYPH_SLOTS]?GlyphSlot,
next_slot: u32,
lru_counter: u64,
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
    var input = self.game_ptr.input;
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
    return is_clicked;
}

// 析构函数
pub fn deinit(self: *@This()) void {
    // 释放 CPU 端内存
    self.allocator.free(self.font_data);
    self.allocator.free(self.frame_vertices);
    self.allocator.free(self.frame_indices);

    Wgpu.wgpuBufferRelease(self.vertex_buffer);
    Wgpu.wgpuBufferRelease(self.index_buffer);
    Wgpu.wgpuBufferRelease(self.uniform_buffer);
    Wgpu.wgpuTextureRelease(self.sdf_texture);
    Wgpu.wgpuTextureViewRelease(self.sdf_texture_view);
    Wgpu.wgpuSamplerRelease(self.sdf_sampler);
}

pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, game: *Game, font_path: []const u8) !UiSystem {
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

    // 加载字体
    const font_data = try std.fs.cwd().readFileAllocOptions(
        allocator,
        font_path,
        std.math.maxInt(usize),
        null,
        .@"8",
        null,
    );

    var font_info: Stb.stbtt_fontinfo = undefined;
    if (Stb.stbtt_InitFont(&font_info, font_data.ptr, 0) == 0) {
        return error.FontInitFailed;
    }

    var ascent: c_int = undefined;
    var descent: c_int = undefined;
    var line_gap: c_int = undefined;
    Stb.stbtt_GetFontVMetrics(&font_info, &ascent, &descent, &line_gap);

    const canonical_scale = Stb.stbtt_ScaleForPixelHeight(&font_info, SDF_SCALE_HEIGHT);

    // 创建 SDF 图集纹理
    const sdf_texture = Wgpu.wgpuDeviceCreateTexture(gctx.device, &.{
        .usage = @as(Wgpu.WGPUTextureUsage, Wgpu.WGPUTextureUsage_CopyDst) | Wgpu.WGPUTextureUsage_TextureBinding,
        .dimension = Wgpu.WGPUTextureDimension_2D,
        .size = .{
            .width = ATLAS_SIZE,
            .height = ATLAS_SIZE,
            .depthOrArrayLayers = 1,
        },
        .format = Wgpu.WGPUTextureFormat_R8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
        .viewFormatCount = 0,
        .viewFormats = null,
    });

    const sdf_texture_view = Wgpu.wgpuTextureCreateView(sdf_texture, null);

    const sdf_sampler = Wgpu.wgpuDeviceCreateSampler(gctx.device, &.{
        .addressModeU = Wgpu.WGPUAddressMode_ClampToEdge,
        .addressModeV = Wgpu.WGPUAddressMode_ClampToEdge,
        .addressModeW = Wgpu.WGPUAddressMode_ClampToEdge,
        .magFilter = Wgpu.WGPUFilterMode_Linear,
        .minFilter = Wgpu.WGPUFilterMode_Linear,
        .mipmapFilter = Wgpu.WGPUMipmapFilterMode_Nearest,
        .lodMinClamp = 0.0,
        .lodMaxClamp = 32.0,
        .compare = Wgpu.WGPUCompareFunction_Undefined,
        .maxAnisotropy = 1,
    });

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
    self.vertex_count = 0;
    self.index_count = 0;
    self.font_data = font_data;
    self.font_info = font_info;
    self.ascent = ascent;
    self.descent = descent;
    self.line_gap = line_gap;
    self.canonical_scale = canonical_scale;
    self.sdf_texture = sdf_texture;
    self.sdf_texture_view = sdf_texture_view;
    self.sdf_sampler = sdf_sampler;
    self.glyph_slots = .{null} ** GLYPH_SLOTS;
    self.next_slot = 0;
    self.lru_counter = 0;
    // 先创建好所有 buffer，再创建渲染管线
    self.render_pipeline = try UiRenderPipeline.init(gctx, "resources/shaders/ui_render_shader.wgsl", &self);
    return self;
}

// 每帧开始时重置数据
pub fn beginFrame(self: *@This()) void {
    self.vertex_count = 0;
    self.index_count = 0;
}

// 每帧结束时更新 GPU 缓冲区
pub fn endFrame(self: *@This(), gctx: *Gctx) !void {
    if (self.index_count == 0) return;
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
    if (self.vertex_count + 4 > self.max_vertices or self.index_count + 6 > self.max_indices) {
        std.debug.print("UI缓冲区溢出！\n", .{});
        return;
    }
    const base_vertex = @as(u32, @intCast(self.vertex_count));
    const no_tex = [2]f32{ -1, -1 };
    self.frame_vertices[self.vertex_count] = .{ .pos = [3]f32{ x, y, 0 }, .color = color, .texcoord = no_tex };
    self.frame_vertices[self.vertex_count + 1] = .{ .pos = [3]f32{ x + width, y, 0 }, .color = color, .texcoord = no_tex };
    self.frame_vertices[self.vertex_count + 2] = .{ .pos = [3]f32{ x + width, y + height, 0 }, .color = color, .texcoord = no_tex };
    self.frame_vertices[self.vertex_count + 3] = .{ .pos = [3]f32{ x, y + height, 0 }, .color = color, .texcoord = no_tex };

    self.frame_indices[self.index_count] = base_vertex + 0;
    self.frame_indices[self.index_count + 1] = base_vertex + 1;
    self.frame_indices[self.index_count + 2] = base_vertex + 2;
    self.frame_indices[self.index_count + 3] = base_vertex + 0;
    self.frame_indices[self.index_count + 4] = base_vertex + 2;
    self.frame_indices[self.index_count + 5] = base_vertex + 3;

    self.vertex_count += 4;
    self.index_count += 6;
}

// 获取或生成一个字形，返回槽位索引
fn getOrCreateGlyph(self: *UiSystem, gctx: *Gctx, codepoint: u21) ?u32 {
    // 查缓存
    for (self.glyph_slots, 0..) |maybe_slot, i| {
        if (maybe_slot) |slot| {
            if (slot.codepoint == codepoint) {
                self.lru_counter += 1;
                return @as(u32, @intCast(i));
            }
        }
    }

    // 槽位已满时 LRU 淘汰
    var slot_idx: u32 = undefined;
    if (self.next_slot < GLYPH_SLOTS) {
        slot_idx = self.next_slot;
        self.next_slot += 1;
    } else {
        // 简单 FIFO 淘汰（用满后从头覆盖）
        slot_idx = @as(u32, @intCast(self.lru_counter % GLYPH_SLOTS));
    }

    // 生成 SDF 位图
    var sdf_w: c_int = undefined;
    var sdf_h: c_int = undefined;
    var sdf_xoff: c_int = undefined;
    var sdf_yoff: c_int = undefined;
    const sdf_data = Stb.stbtt_GetCodepointSDF(
        &self.font_info,
        self.canonical_scale,
        @as(c_int, @intCast(codepoint)),
        SDF_PADDING,
        SDF_ONEDGE,
        SDF_PIXEL_DIST_SCALE,
        &sdf_w,
        &sdf_h,
        &sdf_xoff,
        &sdf_yoff,
    );
    if (sdf_data == null) return null;
    defer Stb.stbtt_FreeBitmap(sdf_data, null);

    // 获取 font-units 度量
    var advance: c_int = undefined;
    var lsb: c_int = undefined;
    Stb.stbtt_GetCodepointHMetrics(&self.font_info, @as(c_int, @intCast(codepoint)), &advance, &lsb);

    // 将 SDF 位图居中写入槽位缓冲区：每行对齐到 ATLAS_ROW_STRIDE
    const clamped_w = @min(@as(u32, @intCast(sdf_w)), GLYPH_SIZE);
    const clamped_h = @min(@as(u32, @intCast(sdf_h)), GLYPH_SIZE);
    const offset_x = (GLYPH_SIZE - clamped_w) / 2;
    const offset_y = (GLYPH_SIZE - clamped_h) / 2;

    // [*c]u8 转为 [*]const u8 —— Zig 0.15 中 C 指针切片必须显式转换
    const sdf_ptr: [*]const u8 = @ptrCast(sdf_data);

    var slot_buf: [GLYPH_SIZE * ATLAS_ROW_STRIDE]u8 = .{0} ** (GLYPH_SIZE * ATLAS_ROW_STRIDE);
    for (0..clamped_h) |row| {
        const src_start: usize = @intCast(row * clamped_w);
        const dst_start: usize = (@as(usize, @intCast(offset_y)) + row) * ATLAS_ROW_STRIDE + @as(usize, @intCast(offset_x));
        const len: usize = @intCast(clamped_w);
        @memcpy(slot_buf[dst_start .. dst_start + len], sdf_ptr[src_start .. src_start + len]);
    }

    // 上传 64×64 区域到 GPU 图集
    const slot_x = (slot_idx % GLYPHS_PER_ROW) * GLYPH_SIZE;
    const slot_y = (slot_idx / GLYPHS_PER_ROW) * GLYPH_SIZE;
    Wgpu.wgpuQueueWriteTexture(
        gctx.queue,
        &Wgpu.WGPUTexelCopyTextureInfo{
            .texture = self.sdf_texture,
            .mipLevel = 0,
            .origin = .{ .x = slot_x, .y = slot_y, .z = 0 },
            .aspect = Wgpu.WGPUTextureAspect_All,
        },
        &slot_buf,
        GLYPH_SIZE * ATLAS_ROW_STRIDE,
        &Wgpu.WGPUTexelCopyBufferLayout{
            .offset = 0,
            .bytesPerRow = ATLAS_ROW_STRIDE,
            .rowsPerImage = GLYPH_SIZE,
        },
        &Wgpu.WGPUExtent3D{
            .width = GLYPH_SIZE,
            .height = GLYPH_SIZE,
            .depthOrArrayLayers = 1,
        },
    );

    // 记录槽位
    self.glyph_slots[@as(usize, @intCast(slot_idx))] = GlyphSlot{
        .codepoint = codepoint,
        .advance = advance,
        .lsb = lsb,
        .sdf_width = sdf_w,
        .sdf_height = sdf_h,
        .sdf_xoff = sdf_xoff,
        .sdf_yoff = sdf_yoff,
    };
    self.lru_counter += 1;

    return slot_idx;
}

// 计算单个字形的 UV（在 64×64 槽中居中后的有效纹理区域）
fn glyphUVs(slot_idx: u32, slot: GlyphSlot) [4][2]f32 {
    const slot_x = @as(f32, @floatFromInt((slot_idx % GLYPHS_PER_ROW) * GLYPH_SIZE));
    const slot_y = @as(f32, @floatFromInt((slot_idx / GLYPHS_PER_ROW) * GLYPH_SIZE));
    const atlas_f = @as(f32, @floatFromInt(ATLAS_SIZE));

    const cw = @as(f32, @floatFromInt(@as(u32, @intCast(slot.sdf_width))));
    const ch = @as(f32, @floatFromInt(@as(u32, @intCast(slot.sdf_height))));
    const ox = (GLYPH_SIZE - cw) / 2.0;
    const oy = (GLYPH_SIZE - ch) / 2.0;

    const u_min = (slot_x + ox) / atlas_f;
    const v_min = (slot_y + oy) / atlas_f;
    const u_max = (slot_x + ox + cw) / atlas_f;
    const v_max = (slot_y + oy + ch) / atlas_f;

    return .{
        .{ u_min, v_min },
        .{ u_max, v_min },
        .{ u_max, v_max },
        .{ u_min, v_max },
    };
}

// 绘制文本
pub fn drawText(self: *UiSystem, gctx: *Gctx, x: f32, y: f32, text: []const u8, font_size: f32, color: [4]f32) void {
    const render_scale = font_size / SDF_SCALE_HEIGHT;

    var cursor_x: f32 = x;
    var prev_codepoint: u21 = 0;

    var utf8_view = std.unicode.Utf8View.init(text) catch return;
    var utf8_iter = utf8_view.iterator();

    while (utf8_iter.nextCodepoint()) |cp| {
        if (cp == '\n') {
            cursor_x = x;
            prev_codepoint = 0;
            continue;
        }

        const slot_idx = self.getOrCreateGlyph(gctx, cp) orelse {
            cursor_x += 10.0 * render_scale;
            prev_codepoint = cp;
            continue;
        };

        const slot = self.glyph_slots[@as(usize, @intCast(slot_idx))] orelse unreachable;

        if (prev_codepoint != 0) {
            const kern = Stb.stbtt_GetCodepointKernAdvance(
                &self.font_info,
                @as(c_int, @intCast(prev_codepoint)),
                @as(c_int, @intCast(cp)),
            );
            cursor_x += @as(f32, @floatFromInt(kern)) * self.canonical_scale * render_scale;
        }

        const glyph_x = cursor_x + @as(f32, @floatFromInt(slot.lsb)) * self.canonical_scale * render_scale;
        const glyph_y = y + @as(f32, @floatFromInt(slot.sdf_yoff)) * render_scale;
        const glyph_w = @as(f32, @floatFromInt(slot.sdf_width)) * render_scale;
        const glyph_h = @as(f32, @floatFromInt(slot.sdf_height)) * render_scale;

        if (self.vertex_count + 4 <= self.max_vertices and self.index_count + 6 <= self.max_indices) {
            const base_vertex = @as(u32, @intCast(self.vertex_count));
            const uvs = glyphUVs(slot_idx, slot);

            self.frame_vertices[self.vertex_count] = .{ .pos = [3]f32{ glyph_x, glyph_y, 0 }, .color = color, .texcoord = uvs[0] };
            self.frame_vertices[self.vertex_count + 1] = .{ .pos = [3]f32{ glyph_x + glyph_w, glyph_y, 0 }, .color = color, .texcoord = uvs[1] };
            self.frame_vertices[self.vertex_count + 2] = .{ .pos = [3]f32{ glyph_x + glyph_w, glyph_y + glyph_h, 0 }, .color = color, .texcoord = uvs[2] };
            self.frame_vertices[self.vertex_count + 3] = .{ .pos = [3]f32{ glyph_x, glyph_y + glyph_h, 0 }, .color = color, .texcoord = uvs[3] };

            self.frame_indices[self.index_count] = base_vertex + 0;
            self.frame_indices[self.index_count + 1] = base_vertex + 1;
            self.frame_indices[self.index_count + 2] = base_vertex + 2;
            self.frame_indices[self.index_count + 3] = base_vertex + 0;
            self.frame_indices[self.index_count + 4] = base_vertex + 2;
            self.frame_indices[self.index_count + 5] = base_vertex + 3;

            self.vertex_count += 4;
            self.index_count += 6;
        }

        cursor_x += @as(f32, @floatFromInt(slot.advance)) * self.canonical_scale * render_scale;
        prev_codepoint = cp;
    }
}

// 自动换行文本框
pub fn drawTextBox(self: *UiSystem, gctx: *Gctx, x: f32, y: f32, max_width: f32, text: []const u8, font_size: f32, color: [4]f32) void {
    const render_scale = font_size / SDF_SCALE_HEIGHT;
    const line_height = font_size * 1.4;

    var cursor_x: f32 = x;
    var cursor_y: f32 = y;
    var prev_codepoint: u21 = 0;

    var utf8_view = std.unicode.Utf8View.init(text) catch return;
    var utf8_iter = utf8_view.iterator();

    while (utf8_iter.nextCodepoint()) |cp| {
        if (cp == '\n') {
            cursor_x = x;
            cursor_y += line_height;
            prev_codepoint = 0;
            continue;
        }

        const slot_idx = self.getOrCreateGlyph(gctx, cp) orelse {
            cursor_x += 10.0 * render_scale;
            prev_codepoint = cp;
            continue;
        };

        const slot = self.glyph_slots[@as(usize, @intCast(slot_idx))] orelse unreachable;
        const advance = @as(f32, @floatFromInt(slot.advance)) * self.canonical_scale * render_scale;

        if (cursor_x + advance > x + max_width and cursor_x > x) {
            cursor_x = x;
            cursor_y += line_height;
            prev_codepoint = 0;
        }

        if (prev_codepoint != 0) {
            const kern = Stb.stbtt_GetCodepointKernAdvance(
                &self.font_info,
                @as(c_int, @intCast(prev_codepoint)),
                @as(c_int, @intCast(cp)),
            );
            cursor_x += @as(f32, @floatFromInt(kern)) * self.canonical_scale * render_scale;
        }

        const glyph_x = cursor_x + @as(f32, @floatFromInt(slot.lsb)) * self.canonical_scale * render_scale;
        const glyph_y = cursor_y + @as(f32, @floatFromInt(slot.sdf_yoff)) * render_scale;
        const glyph_w = @as(f32, @floatFromInt(slot.sdf_width)) * render_scale;
        const glyph_h = @as(f32, @floatFromInt(slot.sdf_height)) * render_scale;

        if (self.vertex_count + 4 <= self.max_vertices and self.index_count + 6 <= self.max_indices) {
            const base_vertex = @as(u32, @intCast(self.vertex_count));
            const uvs = glyphUVs(slot_idx, slot);

            self.frame_vertices[self.vertex_count] = .{ .pos = [3]f32{ glyph_x, glyph_y, 0 }, .color = color, .texcoord = uvs[0] };
            self.frame_vertices[self.vertex_count + 1] = .{ .pos = [3]f32{ glyph_x + glyph_w, glyph_y, 0 }, .color = color, .texcoord = uvs[1] };
            self.frame_vertices[self.vertex_count + 2] = .{ .pos = [3]f32{ glyph_x + glyph_w, glyph_y + glyph_h, 0 }, .color = color, .texcoord = uvs[2] };
            self.frame_vertices[self.vertex_count + 3] = .{ .pos = [3]f32{ glyph_x, glyph_y + glyph_h, 0 }, .color = color, .texcoord = uvs[3] };

            self.frame_indices[self.index_count] = base_vertex + 0;
            self.frame_indices[self.index_count + 1] = base_vertex + 1;
            self.frame_indices[self.index_count + 2] = base_vertex + 2;
            self.frame_indices[self.index_count + 3] = base_vertex + 0;
            self.frame_indices[self.index_count + 4] = base_vertex + 2;
            self.frame_indices[self.index_count + 5] = base_vertex + 3;

            self.vertex_count += 4;
            self.index_count += 6;
        }

        cursor_x += advance;
        prev_codepoint = cp;
    }
}

// UiVertex 定义（顺序必须与 shader 中 layout 一致）
pub const UiVertex = struct {
    pos: [3]f32, // 顶点位置（屏幕像素坐标）
    color: [4]f32, // 颜色
    texcoord: [2]f32, // SDF 图集 UV；(-1,-1) 表示非文本矩形
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

        // Binding 布局（3 个入口）
        const bgl_entries = [_]Wgpu.WGPUBindGroupLayoutEntry{
            .{ // binding 0: uniform
                .binding = 0,
                .visibility = Wgpu.WGPUShaderStage_Vertex | Wgpu.WGPUShaderStage_Fragment,
                .buffer = .{
                    .type = Wgpu.WGPUBufferBindingType_Uniform,
                    .hasDynamicOffset = 0,
                },
            },
            .{ // binding 1: SDF 纹理
                .binding = 1,
                .visibility = Wgpu.WGPUShaderStage_Fragment,
                .texture = .{
                    .sampleType = Wgpu.WGPUTextureSampleType_Float,
                    .viewDimension = Wgpu.WGPUTextureViewDimension_2D,
                    .multisampled = 0,
                },
            },
            .{ // binding 2: 采样器
                .binding = 2,
                .visibility = Wgpu.WGPUShaderStage_Fragment,
                .sampler = .{
                    .type = Wgpu.WGPUSamplerBindingType_Filtering,
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

        // Bind group（3 个 entry）
        const bind_group = Wgpu.wgpuDeviceCreateBindGroup(gctx.device, &Wgpu.WGPUBindGroupDescriptor{
            .layout = bind_group_layout,
            .entryCount = bgl_entries.len,
            .entries = &[_]Wgpu.WGPUBindGroupEntry{
                .{ // binding 0: uniform
                    .binding = 0,
                    .buffer = ui_system.uniform_buffer,
                    .offset = 0,
                    .size = Wgpu.wgpuBufferGetSize(ui_system.uniform_buffer),
                },
                .{ // binding 1: SDF 纹理视图
                    .binding = 1,
                    .textureView = ui_system.sdf_texture_view,
                },
                .{ // binding 2: 采样器
                    .binding = 2,
                    .sampler = ui_system.sdf_sampler,
                },
            },
        });

        // 管线布局
        const pipeline_layout = Wgpu.wgpuDeviceCreatePipelineLayout(gctx.device, &Wgpu.WGPUPipelineLayoutDescriptor{
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &bind_group_layout,
        });

        // 顶点属性自动推导
        const attributes = Gctx.generateVertexAttributes(UiVertex);

        // Alpha blending 配置：文字透明区域不覆写背景
        const blend_state = Wgpu.WGPUBlendState{
            .color = .{
                .operation = Wgpu.WGPUBlendOperation_Add,
                .srcFactor = Wgpu.WGPUBlendFactor_SrcAlpha,
                .dstFactor = Wgpu.WGPUBlendFactor_OneMinusSrcAlpha,
            },
            .alpha = .{
                .operation = Wgpu.WGPUBlendOperation_Add,
                .srcFactor = Wgpu.WGPUBlendFactor_One,
                .dstFactor = Wgpu.WGPUBlendFactor_OneMinusSrcAlpha,
            },
        };

        const pipeline_desc = Wgpu.WGPURenderPipelineDescriptor{
            .layout = pipeline_layout,
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
                    .blend = &blend_state,
                    .writeMask = Wgpu.WGPUColorWriteMask_All,
                },
            },
            .multisample = .{
                .count = 1,
                .mask = Wgpu.WGPUColorWriteMask_All,
            },
            .depthStencil = &Wgpu.WGPUDepthStencilState{
                .format = Wgpu.WGPUTextureFormat_Depth24Plus,
                .depthWriteEnabled = 0,
                .depthCompare = Wgpu.WGPUCompareFunction_Always,
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
const Imports = @import("imports.zig");
const Game = Imports.Game;
const Wgpu = Imports.Wgpu;
const Algebra = @import("algebra.zig");
const Mat4 = Algebra.Mat4;
const Window = Imports.Window;
const Stb = @import("stb").c;
