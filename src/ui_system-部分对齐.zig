// ui_system.zig — 基于 SDF（Signed Distance Field）的 UI 文字渲染系统
const UiSystem = @This();
const ft = @import("freetype").c;

const GLYPH_SIZE: u32 = 64;
const ATLAS_SIZE: u32 = 2048;
const GLYPHS_PER_ROW: u32 = ATLAS_SIZE / GLYPH_SIZE;
const GLYPH_SLOTS: u32 = GLYPHS_PER_ROW * GLYPHS_PER_ROW;

/// 标准字号（覆盖位图生成的分辨率）
const SCALE_HEIGHT: f32 = 64;

// 一个图集中的字形槽位
const GlyphSlot = struct {
    codepoint: u21,
    gen_size: u32, // 位图对应的生成字号
    advance: i32,
    lsb: i32,
    sdf_width: c_int,
    sdf_height: c_int,
    sdf_xoff: c_int,
    sdf_yoff: c_int,
};

allocator: std.mem.Allocator,
render_pipeline: UiRenderPipeline,
game_ptr: *Game,
// 字体与图集
font_data: []u8,
font_info: Stb.stbtt_fontinfo,
ft_lib: ft.FT_Library,
ft_face: ft.FT_Face,
ascent: i32,
descent: i32,
line_gap: i32,
canonical_scale: f32, // 生成 SDF 时用的字体缩放比
sdf_texture: Wgpu.WGPUTexture,
sdf_texture_view: Wgpu.WGPUTextureView,
sdf_sampler: Wgpu.WGPUSampler,
glyph_slots: [GLYPH_SLOTS]?GlyphSlot,
next_slot: u32,
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
// 分层计数器：bg_index_count 之前的索引为下层（背景），之后为上层（文字/前景）
bg_index_count: usize = 0,
// 顶点/索引缓冲区，每帧更新
vertex_buffer: Wgpu.WGPUBuffer,
index_buffer: Wgpu.WGPUBuffer,
device: Wgpu.WGPUDevice,
frame_under_counter: u32 = 0,

// 游标布局
cursor_x: f32 = 0,
cursor_y: f32 = 0,
row_top_y: f32 = 0,
row_bottom_y: f32 = 0,
cursor_col_x: f32 = 0,
next_same_line: bool = false,
same_line_spacing: f32 = 0,

// 带文字的按钮：背景 + 居中文字 + 点击检测
pub fn textButton(self: *UiSystem, x: f32, y: f32, w: f32, h: f32, label: []const u8, font_size: f32) bool {
    const hit = self.buttonHover(x, y, w, h);
    const clicked = hit and self.game_ptr.input.isMouseJustPressed(.mouse_left);
    self.drawButton(x, y, w, h, hit, false);
    const txt_w = self.measureText(&self.game_ptr.gctx, label, font_size);
    self.drawText(&self.game_ptr.gctx, x + self.centerX(w, txt_w), y + self.centerX(h, font_size), label, font_size, .{ 1, 1, 1, 1 });
    return clicked;
}

/// 仅检测鼠标是否悬停在矩形区域内
pub fn buttonHover(self: *UiSystem, x: f32, y: f32, width: f32, height: f32) bool {
    const p = self.game_ptr.input.getCursorPos();
    return p.x >= x and p.x <= x + width and p.y >= y and p.y <= y + height;
}

/// 仅绘制按钮背景和边框（不含文字），由 button / save_menu 等调用
pub fn drawButton(self: *UiSystem, x: f32, y: f32, width: f32, height: f32, hovered: bool, active: bool) void {
    const color = if (active) [4]f32{ 0.2, 0.2, 0.8, 1.0 } else if (hovered) [4]f32{ 0.8, 0.8, 0.2, 1.0 } else [4]f32{ 0.5, 0.5, 0.5, 1.0 };
    self.drawRect(x, y, width, height, color);
    const border_color = [4]f32{ 0.1, 0.1, 0.1, 1.0 };
    self.drawRect(x, y, width, 1, border_color);
    self.drawRect(x, y + height - 1, width, 1, border_color);
    self.drawRect(x, y, 1, height, border_color);
    self.drawRect(x + width - 1, y, 1, height, border_color);
}

/// 水平居中偏移量
pub fn centerX(_: *UiSystem, container: f32, element: f32) f32 {
    return (container - element) / 2;
}

// ═══════════════════════════════════════════════
//  游标布局 API（基于现有 textButton / drawText）
// ═══════════════════════════════════════════════

/// 按钮：游标位置绘制 + 自动推进 Y
pub fn button(self: *UiSystem, label: []const u8, w: f32, h: f32, font_size: f32) bool {
    if (!self.next_same_line) {
        self.cursor_y = @max(self.cursor_y, self.row_bottom_y);
        self.row_top_y = self.cursor_y;
        self.cursor_x = self.cursor_col_x;
    } else {
        self.next_same_line = false;
        self.cursor_x += self.same_line_spacing;
        self.cursor_y = self.row_top_y;
    }
    const clicked = self.textButton(self.cursor_x, self.cursor_y, w, h, label, font_size);
    self.row_bottom_y = @max(self.row_bottom_y, self.cursor_y + h);
    self.cursor_x += w;
    return clicked;
}

/// 下一个 widget 保持同行
pub fn sameLine(self: *UiSystem, s: f32) void {
    self.next_same_line = true;
    self.same_line_spacing = s;
}

/// 文字：游标位置绘制 + 自动推进 Y
pub fn drawLabel(self: *UiSystem, str: []const u8, font_size: f32, color: [4]f32) void {
    if (!self.next_same_line) {
        self.cursor_y = @max(self.cursor_y, self.row_bottom_y);
        self.row_top_y = self.cursor_y;
        self.cursor_x = self.cursor_col_x;
    } else {
        self.next_same_line = false;
        self.cursor_x += self.same_line_spacing;
        self.cursor_y = self.row_top_y;
    }
    self.drawText(&self.game_ptr.gctx, self.cursor_x, self.cursor_y, str, font_size, color);
    const w = self.measureText(&self.game_ptr.gctx, str, font_size);
    self.row_bottom_y = @max(self.row_bottom_y, self.cursor_y + font_size);
    self.cursor_x += w;
}

/// 垂直空距
pub fn spacing(self: *UiSystem, h: f32) void {
    self.cursor_y = @max(self.cursor_y, self.row_bottom_y) + h;
    self.cursor_x = self.cursor_col_x;
    self.row_top_y = self.cursor_y;
    self.row_bottom_y = self.cursor_y;
}

/// 标记分层点：累计所有下层（背景）的索引，取最大值确保不被覆盖
pub fn splitLayer(self: *@This()) void {
    self.bg_index_count = @max(self.bg_index_count, self.index_count);
}

// 析构函数
pub fn deinit(self: *@This()) void {
    // 释放 CPU 端内存
    self.allocator.free(self.font_data);
    self.allocator.free(self.frame_vertices);
    self.allocator.free(self.frame_indices);

    _ = ft.FT_Done_Face(self.ft_face);
    _ = ft.FT_Done_FreeType(self.ft_lib);
    Wgpu.wgpuBufferRelease(self.vertex_buffer);
    Wgpu.wgpuBufferRelease(self.index_buffer);
    Wgpu.wgpuBufferRelease(self.uniform_buffer);
    Wgpu.wgpuTextureRelease(self.sdf_texture);
    Wgpu.wgpuTextureViewRelease(self.sdf_texture_view);
    Wgpu.wgpuSamplerRelease(self.sdf_sampler);
}

pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, game: *Game, font_path: []const u8) !UiSystem {
    var self: UiSystem = undefined;

    // === 先加载字体（失败不浪费 GPU 资源）===
    const font_data = try std.fs.cwd().readFileAllocOptions(
        allocator,
        font_path,
        std.math.maxInt(usize),
        null,
        .@"8",
        null,
    );
    errdefer allocator.free(font_data);

    // 初始化 FreeType（用于字形栅格化）
    var ft_lib: ft.FT_Library = undefined;
    if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.FontInitFailed;
    var ft_face: ft.FT_Face = undefined;
    if (ft.FT_New_Memory_Face(ft_lib, font_data.ptr, @as(ft.FT_Long, @intCast(font_data.len)), 0, &ft_face) != 0)
        return error.FontInitFailed;
    _ = ft.FT_Set_Pixel_Sizes(ft_face, 0, @as(u32, @intFromFloat(SCALE_HEIGHT)));

    // stb font_info 保留用于 advance/kerning 计算
    const font_offset = Stb.stbtt_GetFontOffsetForIndex(font_data.ptr, 0);
    if (font_offset < 0) return error.FontInitFailed;
    var font_info: Stb.stbtt_fontinfo = undefined;
    if (Stb.stbtt_InitFont(&font_info, font_data.ptr, font_offset) == 0) return error.FontInitFailed;

    var ascent: c_int = undefined;
    var descent: c_int = undefined;
    var line_gap: c_int = undefined;
    Stb.stbtt_GetFontVMetrics(&font_info, &ascent, &descent, &line_gap);

    const canonical_scale = Stb.stbtt_ScaleForPixelHeight(&font_info, SCALE_HEIGHT);

    // === 创建 GPU 资源 ===
    const max_vertices: usize = 65536;
    const max_indices: usize = 131072;

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

    // 创建 SDF 图集纹理
    const sdf_texture = Wgpu.wgpuDeviceCreateTexture(gctx.device, &.{
        .usage = @as(Wgpu.WGPUTextureUsage, Wgpu.WGPUTextureUsage_CopyDst) | Wgpu.WGPUTextureUsage_TextureBinding,
        .dimension = Wgpu.WGPUTextureDimension_2D,
        .size = .{
            .width = ATLAS_SIZE,
            .height = ATLAS_SIZE,
            .depthOrArrayLayers = 1,
        },
        .format = Wgpu.WGPUTextureFormat_RGBA8Unorm,
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
        .magFilter = Wgpu.WGPUFilterMode_Nearest,
        .minFilter = Wgpu.WGPUFilterMode_Nearest,
        .mipmapFilter = Wgpu.WGPUMipmapFilterMode_Nearest,
        .lodMinClamp = 0.0,
        .lodMaxClamp = 32.0,
        .compare = Wgpu.WGPUCompareFunction_Undefined,
        .maxAnisotropy = 1,
    });

    // === 填充 self ===
    self.allocator = allocator;
    self.game_ptr = game;
    self.vertex_buffer = vertex_buffer;
    self.index_buffer = index_buffer;
    self.device = gctx.device;
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
    self.ft_lib = ft_lib;
    self.ft_face = ft_face;
    self.ascent = ascent;
    self.descent = descent;
    self.line_gap = line_gap;
    self.canonical_scale = canonical_scale;
    self.sdf_texture = sdf_texture;
    self.sdf_texture_view = sdf_texture_view;
    self.sdf_sampler = sdf_sampler;
    self.glyph_slots = .{null} ** GLYPH_SLOTS;
    self.next_slot = 0;
    self.render_pipeline = try UiRenderPipeline.init(gctx, "resources/shaders/ui_render_shader.wgsl", &self);
    return self;
}

// 每帧开始时重置数据
pub fn beginFrame(self: *@This()) void {
    self.vertex_count = 0;
    self.index_count = 0;
    self.cursor_x = 0;
    self.cursor_y = 0;
    self.row_top_y = 0;
    self.row_bottom_y = 0;
    self.cursor_col_x = 0;
    self.next_same_line = false;
    self.bg_index_count = 0;
}

// 每帧结束时更新 GPU 缓冲区（含缩容检测）
pub fn endFrame(self: *@This(), gctx: *Gctx) !void {
    if (self.max_vertices > 1024) {
        if (self.vertex_count < self.max_vertices / 4 and self.index_count < self.max_indices / 4) {
            self.frame_under_counter += 1;
            if (self.frame_under_counter >= 1000) {
                self.ensureCapacity(self.max_vertices / 2, self.max_indices / 2);
                self.frame_under_counter = 0;
            }
        } else {
            self.frame_under_counter = 0;
        }
    }
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

// 动态扩缩容（CPU realloc + GPU recreate），接缝处取 2ⁿ 对齐
fn ensureCapacity(self: *UiSystem, need_v: usize, need_i: usize) void {
    var new_max_v = need_v;
    var new_max_i = need_i;
    if (new_max_v < 1024) new_max_v = 1024;
    if (new_max_i < 2048) new_max_i = 2048;
    new_max_v = std.math.ceilPowerOfTwo(usize, new_max_v) catch @panic("顶点容量过大");
    new_max_i = std.math.ceilPowerOfTwo(usize, new_max_i) catch @panic("索引容量过大");

    if (new_max_v == self.max_vertices and new_max_i == self.max_indices) return;

    self.frame_vertices = self.allocator.realloc(self.frame_vertices, new_max_v) catch @panic("OOM");
    self.frame_indices = self.allocator.realloc(self.frame_indices, new_max_i) catch @panic("OOM");

    const new_vb = Wgpu.wgpuDeviceCreateBuffer(self.device, &.{
        .size = new_max_v * @sizeOf(UiVertex),
        .usage = Wgpu.WGPUBufferUsage_CopyDst | Wgpu.WGPUBufferUsage_Vertex,
    });
    const new_ib = Wgpu.wgpuDeviceCreateBuffer(self.device, &.{
        .size = new_max_i * @sizeOf(u32),
        .usage = Wgpu.WGPUBufferUsage_CopyDst | Wgpu.WGPUBufferUsage_Index,
    });
    Wgpu.wgpuBufferRelease(self.vertex_buffer);
    Wgpu.wgpuBufferRelease(self.index_buffer);

    self.vertex_buffer = new_vb;
    self.index_buffer = new_ib;
    self.max_vertices = new_max_v;
    self.max_indices = new_max_i;
}

// 内核：在缓冲区追加一个四边形（4 顶点 + 6 索引）
fn emitQuad(self: *UiSystem, x: f32, y: f32, w: f32, h: f32, color: [4]f32, uvs: [4][2]f32) void {
    const need_v = self.vertex_count + 4;
    const need_i = self.index_count + 6;
    if (need_v > self.max_vertices or need_i > self.max_indices)
        self.ensureCapacity(need_v, need_i);

    const base = @as(u32, @intCast(self.vertex_count));
    self.frame_vertices[base + 0] = .{ .pos = [3]f32{ x, y, 0 }, .color = color, .texcoord = uvs[0] };
    self.frame_vertices[base + 1] = .{ .pos = [3]f32{ x + w, y, 0 }, .color = color, .texcoord = uvs[1] };
    self.frame_vertices[base + 2] = .{ .pos = [3]f32{ x + w, y + h, 0 }, .color = color, .texcoord = uvs[2] };
    self.frame_vertices[base + 3] = .{ .pos = [3]f32{ x, y + h, 0 }, .color = color, .texcoord = uvs[3] };

    self.frame_indices[self.index_count + 0] = base + 0;
    self.frame_indices[self.index_count + 1] = base + 1;
    self.frame_indices[self.index_count + 2] = base + 2;
    self.frame_indices[self.index_count + 3] = base + 0;
    self.frame_indices[self.index_count + 4] = base + 2;
    self.frame_indices[self.index_count + 5] = base + 3;

    self.vertex_count += 4;
    self.index_count += 6;
}

/// 矩形绘制
pub fn drawRect(self: *UiSystem, x: f32, y: f32, width: f32, height: f32, color: [4]f32) void {
    const no_tex = [_][2]f32{.{ -1, -1 }} ** 4;
    self.emitQuad(x, y, width, height, color, no_tex);
}

// 获取或生成字形（font_size < 32 用 2x 生成，否则 1x）
fn getOrCreateGlyph(self: *UiSystem, gctx: *Gctx, codepoint: u21, font_size: f32) ?u32 {
    const mult: f32 = if (font_size < 32) 2 else 1;
    const gen_size = @as(u32, @intFromFloat(font_size * mult));
    for (self.glyph_slots, 0..) |maybe_slot, i| {
        if (maybe_slot) |slot| {
            if (slot.codepoint == codepoint and slot.gen_size == gen_size) return @as(u32, @intCast(i));
        }
    }

    const slot_idx = self.next_slot;
    self.next_slot = (self.next_slot + 1) % GLYPH_SLOTS;

    const gen_scale = Stb.stbtt_ScaleForPixelHeight(&self.font_info, @as(f32, @floatFromInt(gen_size)));

    var bm_w: c_int = undefined;
    var bm_h: c_int = undefined;
    var bm_xoff: c_int = undefined;
    var bm_yoff: c_int = undefined;
    const bm_data = Stb.stbtt_GetCodepointBitmap(
        &self.font_info,
        gen_scale,
        gen_scale,
        @as(c_int, @intCast(codepoint)),
        &bm_w,
        &bm_h,
        &bm_xoff,
        &bm_yoff,
    );
    if (bm_data == null) return null;
    defer Stb.stbtt_FreeBitmap(bm_data, null);

    var adv_font: c_int = undefined;
    var lsb_font: c_int = undefined;
    Stb.stbtt_GetCodepointHMetrics(&self.font_info, @as(c_int, @intCast(codepoint)), &adv_font, &lsb_font);

    const cw = @min(@as(u32, @intCast(bm_w)), GLYPH_SIZE);
    const ch = @min(@as(u32, @intCast(bm_h)), GLYPH_SIZE);

    const bm_ptr: [*]const u8 = @ptrCast(bm_data);
    var slot_buf: [GLYPH_SIZE * GLYPH_SIZE * 4]u8 = .{0} ** (GLYPH_SIZE * GLYPH_SIZE * 4);
    for (0..ch) |row| {
        for (0..cw) |col| {
            const src = bm_ptr[row * @as(u32, @intCast(bm_w)) + col];
            const dst = (row * GLYPH_SIZE + col) * 4;
            @memset(slot_buf[dst .. dst + 4], src);
        }
    }

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
        GLYPH_SIZE * GLYPH_SIZE * 4,
        &Wgpu.WGPUTexelCopyBufferLayout{
            .offset = 0,
            .bytesPerRow = GLYPH_SIZE * 4,
            .rowsPerImage = GLYPH_SIZE,
        },
        &Wgpu.WGPUExtent3D{
            .width = GLYPH_SIZE,
            .height = GLYPH_SIZE,
            .depthOrArrayLayers = 1,
        },
    );

    self.glyph_slots[@as(usize, @intCast(slot_idx))] = GlyphSlot{
        .codepoint = codepoint,
        .gen_size = gen_size,
        .advance = adv_font,
        .lsb = lsb_font,
        .sdf_width = @as(c_int, @intCast(cw)),
        .sdf_height = @as(c_int, @intCast(ch)),
        .sdf_xoff = bm_xoff,
        .sdf_yoff = bm_yoff,
    };

    return slot_idx;
}

// UV（半像素内缩防边界采样溢出）
fn glyphUVs(slot_idx: u32, slot: GlyphSlot) [4][2]f32 {
    const slot_x = @as(f32, @floatFromInt((slot_idx % GLYPHS_PER_ROW) * GLYPH_SIZE));
    const slot_y = @as(f32, @floatFromInt((slot_idx / GLYPHS_PER_ROW) * GLYPH_SIZE));
    const atlas_f = @as(f32, @floatFromInt(ATLAS_SIZE));

    const cw = @as(f32, @floatFromInt(@as(u32, @intCast(slot.sdf_width))));
    const ch = @as(f32, @floatFromInt(@as(u32, @intCast(slot.sdf_height))));

    const u_min = (slot_x + 0.5) / atlas_f;
    const v_min = (slot_y + 0.5) / atlas_f;
    const u_max = (slot_x + cw - 0.5) / atlas_f;
    const v_max = (slot_y + ch - 0.5) / atlas_f;

    return .{
        .{ u_min, v_min },
        .{ u_max, v_min },
        .{ u_max, v_max },
        .{ u_min, v_max },
    };
}

/// 精确计算文字的像素宽度
pub fn measureText(self: *UiSystem, gctx: *Gctx, text: []const u8, font_size: f32) f32 {
    const font_scale = Stb.stbtt_ScaleForPixelHeight(&self.font_info, font_size);
    var pw: f32 = 0;
    var prev: u21 = 0;
    var last_cp: u21 = 0;
    var utf8 = std.unicode.Utf8View.init(text) catch return 0;
    var it = utf8.iterator();
    while (it.nextCodepoint()) |cp| {
        if (prev != 0) {
            pw += @as(f32, @floatFromInt(Stb.stbtt_GetCodepointKernAdvance(
                &self.font_info,
                @intCast(prev),
                @intCast(cp),
            ))) * font_scale;
        }
        var adv: c_int = undefined;
        Stb.stbtt_GetCodepointHMetrics(&self.font_info, @intCast(cp), &adv, null);
        pw += @as(f32, @floatFromInt(adv)) * font_scale;
        prev = cp;
        last_cp = cp;
    }
    if (last_cp == 0) return pw;
    const slot_idx = self.getOrCreateGlyph(gctx, last_cp, font_size) orelse return pw;
    const slot = self.glyph_slots[@as(usize, @intCast(slot_idx))] orelse return pw;
    const mult: f32 = if (font_size < 32) 2 else 1;
    const rs = 1.0 / mult;
    const visual_width = @round(@as(f32, @floatFromInt(slot.sdf_xoff)) * rs + @as(f32, @floatFromInt(slot.sdf_width)) * rs);
    return pw - (@round(@as(f32, @floatFromInt(slot.advance)) * font_scale) - visual_width);
}

// 内核：渲染单个字形 + 返回 advance（null 表示字形生成失败）
fn emitGlyph(self: *UiSystem, gctx: *Gctx, cp: u21, font_size: f32, color: [4]f32, cursor_x: *f32, prev_codepoint: *u21, line_y: f32) ?f32 {
    const slot_idx = self.getOrCreateGlyph(gctx, cp, font_size) orelse return null;
    const slot = self.glyph_slots[@as(usize, @intCast(slot_idx))] orelse unreachable;

    const mult: f32 = if (font_size < 32) 2 else 1;
    const rs = 1.0 / mult;
    const gen_scale = Stb.stbtt_ScaleForPixelHeight(&self.font_info, font_size * mult);

    if (prev_codepoint.* != 0) {
        const kern = Stb.stbtt_GetCodepointKernAdvance(
            &self.font_info,
            @as(c_int, @intCast(prev_codepoint.*)),
            @as(c_int, @intCast(cp)),
        );
        cursor_x.* += @as(f32, @floatFromInt(kern)) * gen_scale * rs;
    }

    cursor_x.* = @round(cursor_x.*);
    const glyph_x = cursor_x.* + @round(@as(f32, @floatFromInt(slot.sdf_xoff)) * rs);
    const glyph_y = line_y + @round(@as(f32, @floatFromInt(slot.sdf_yoff)) * rs);
    const qw = @round(@as(f32, @floatFromInt(slot.sdf_width)) * rs);
    const qh = @round(@as(f32, @floatFromInt(slot.sdf_height)) * rs);

    self.emitQuad(glyph_x, glyph_y, qw, qh, color, glyphUVs(slot_idx, slot));

    prev_codepoint.* = cp;
    return @round(@as(f32, @floatFromInt(slot.advance)) * gen_scale * rs);
}

// 绘制文本
pub fn drawText(self: *UiSystem, gctx: *Gctx, x: f32, y: f32, text: []const u8, font_size: f32, color: [4]f32) void {
    const font_scale = Stb.stbtt_ScaleForPixelHeight(&self.font_info, font_size);
    const baseline_y = @round(y + @as(f32, @floatFromInt(self.ascent)) * font_scale);

    var cursor_x: f32 = @round(x);
    var prev_codepoint: u21 = 0;

    var utf8_view = std.unicode.Utf8View.init(text) catch return;
    var utf8_iter = utf8_view.iterator();

    while (utf8_iter.nextCodepoint()) |cp| {
        if (cp == '\n') {
            cursor_x = @round(x);
            prev_codepoint = 0;
            continue;
        }

        const advance = self.emitGlyph(gctx, cp, font_size, color, &cursor_x, &prev_codepoint, baseline_y) orelse {
            cursor_x += 10;
            prev_codepoint = cp;
            continue;
        };
        cursor_x += advance;
    }
}

// 自动换行文本框
pub fn drawTextBox(self: *UiSystem, gctx: *Gctx, x: f32, y: f32, max_width: f32, text: []const u8, font_size: f32, color: [4]f32) void {
    const font_scale = Stb.stbtt_ScaleForPixelHeight(&self.font_info, font_size);
    const baseline_y = @round(y + @as(f32, @floatFromInt(self.ascent)) * font_scale);
    const line_height = font_size * 1.4;

    var cursor_x: f32 = @round(x);
    var cursor_y: f32 = baseline_y;
    var prev_codepoint: u21 = 0;

    var utf8_view = std.unicode.Utf8View.init(text) catch return;
    var utf8_iter = utf8_view.iterator();

    while (utf8_iter.nextCodepoint()) |cp| {
        if (cp == '\n') {
            cursor_x = @round(x);
            cursor_y += line_height;
            prev_codepoint = 0;
            continue;
        }

        const slot_idx = (self.getOrCreateGlyph(gctx, cp, font_size) orelse {
            cursor_x += 10;
            prev_codepoint = cp;
            continue;
        });
        const slot = self.glyph_slots[@as(usize, @intCast(slot_idx))] orelse unreachable;
        const advance = @round(@as(f32, @floatFromInt(slot.advance)) * font_scale);

        if (cursor_x + advance > x + max_width and cursor_x > x) {
            cursor_x = @round(x);
            cursor_y += line_height;
            prev_codepoint = 0;
        }

        _ = self.emitGlyph(gctx, cp, font_size, color, &cursor_x, &prev_codepoint, cursor_y);
        cursor_x += advance;
        prev_codepoint = cp;
    }
}

/// 全屏半透明遮罩
pub fn drawOverlay(self: *UiSystem, alpha: f32) void {
    const window = self.game_ptr.window;
    self.drawRect(0, 0, window.width, window.height, .{ 0, 0, 0, alpha });
}

/// 槽位背景 + 选中边框（下层 UI）
pub fn drawSlotBg(self: *UiSystem, x: f32, y: f32, size: f32, selected: bool, hovered: bool) void {
    const bg: [4]f32 = if (selected) .{ 0.35, 0.35, 0.35, 0.9 } else if (hovered) .{ 0.4, 0.4, 0.4, 0.9 } else .{ 0.2, 0.2, 0.2, 0.8 };
    self.drawRect(x, y, size, size, bg);
    if (selected) {
        const border: [4]f32 = .{ 1.0, 0.85, 0.2, 1.0 };
        self.drawRect(x, y, size, 2, border);
        self.drawRect(x, y + size - 2, size, 2, border);
        self.drawRect(x, y, 2, size, border);
        self.drawRect(x + size - 2, y, 2, size, border);
    } else {
        const border: [4]f32 = .{ 0.3, 0.3, 0.3, 1.0 };
        self.drawRect(x, y, size, 1, border);
        self.drawRect(x, y + size - 1, size, 1, border);
        self.drawRect(x, y, 1, size, border);
        self.drawRect(x + size - 1, y, 1, size, border);
    }
}

/// 带 1px 黑色软描边的文字（8 方向偏移 + 白色填充）
pub fn drawTextOutlined(self: *UiSystem, gctx: *Gctx, x: f32, y: f32, text: []const u8, font_size: f32) void {
    const black = [4]f32{ 0, 0, 0, 1 };
    self.drawText(gctx, x - 1, y - 1, text, font_size, black);
    self.drawText(gctx, x, y - 1, text, font_size, black);
    self.drawText(gctx, x + 1, y - 1, text, font_size, black);
    self.drawText(gctx, x - 1, y, text, font_size, black);
    self.drawText(gctx, x + 1, y, text, font_size, black);
    self.drawText(gctx, x - 1, y + 1, text, font_size, black);
    self.drawText(gctx, x, y + 1, text, font_size, black);
    self.drawText(gctx, x + 1, y + 1, text, font_size, black);
    self.drawText(gctx, x, y, text, font_size, .{ 1, 1, 1, 1 });
}

/// 槽位图标 + 数量文字（上层 UI）
pub fn drawSlotFg(self: *UiSystem, x: f32, y: f32, size: f32, item: ItemStack, icon_atlas: *IconAtlas) void {
    if (item.item_id != 0) {
        if (icon_atlas.getOrLoad(item.item_id)) |slot_i| {
            icon_atlas.addQuad(IconAtlas.slotUV(slot_i), x + 4, y + 4, size - 8);
        }
        if (item.count > 1) {
            var buf: [16]u8 = undefined;
            const count_str = std.fmt.bufPrint(&buf, "{d}", .{item.count}) catch unreachable;
            self.drawTextOutlined(&self.game_ptr.gctx, x + 4, y + size - 23, count_str, 20);
        }
    }
}

// ═══════════════════════════════════════════════════════════════
//  物品栏渲染
// ═══════════════════════════════════════════════════════════════

/// 绘制底部物品栏背景 + 边框（下层 UI，需先于图标和文字调用）
pub fn drawHotbarBg(self: *UiSystem, hotbar: *const Hotbar) void {
    const window = self.game_ptr.window;
    const slot: f32 = 50;
    const gap: f32 = 4;
    const total = 9 * slot + 8 * gap;
    const start_x = (window.width - total) / 2;
    const y = window.height - 60;
    const mouse = self.game_ptr.input.getCursorPos();

    for (&hotbar.slots, 0..) |_, i| {
        const x = start_x + @as(f32, @floatFromInt(i)) * (slot + gap);
        const hover = mouse.x >= x and mouse.x <= x + slot and mouse.y >= y and mouse.y <= y + slot;
        self.drawSlotBg(x, y, slot, i == hotbar.selected, hover);
    }
}

/// 绘制底部物品栏图标 + 数量文字（上层 UI，需在 splitLayer 后调用）
pub fn drawHotbarFg(self: *UiSystem, hotbar: *const Hotbar, icon_atlas: *IconAtlas) void {
    const window = self.game_ptr.window;
    const slot: f32 = 50;
    const gap: f32 = 4;
    const total = 9 * slot + 8 * gap;
    const start_x = (window.width - total) / 2;
    const y = window.height - 60;

    for (&hotbar.slots, 0..) |*item, i| {
        const x = start_x + @as(f32, @floatFromInt(i)) * (slot + gap);
        self.drawSlotFg(x, y, slot, item.*, icon_atlas);
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

// ═══════════════════════════════════════════════════════════════
//  图标渲染管线（独立于主 UI 管线，纹理采样 RGBA）
// ═══════════════════════════════════════════════════════════════

pub const UiUniform = struct {
    ortho_matrix: Mat4,
    pub fn init(window: Window) @This() {
        return @This(){
            .ortho_matrix = Mat4.orthographic(0, window.width, window.height, 0, -1.0, 1.0),
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
const Hotbar = @import("inventory.zig").Hotbar;
const ItemStack = @import("inventory.zig").ItemStack;
const IconAtlas = @import("icon_atlas.zig").IconAtlas;
const BlockId = @import("block_registry.zig").BlockId;
