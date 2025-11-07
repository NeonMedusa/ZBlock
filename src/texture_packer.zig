const std = @import("std");
const TextureInfo = @import("shader_types.zig").TextureInfo;
const ModelInfo = @import("shader_types.zig").ModelInfo;
const ModelName = @import("model.zig").ModelName;

const TextureType = enum { color, anime };

pub const PackResult = struct {
    color_atlas_count: u32,
    anime_atlas_count: u32,
};

const TextureRect = struct {
    width: f32,
    height: f32,
    model_name: ModelName,
    texture_type: TextureType,
    x: i32 = 0,
    y: i32 = 0,
    atlas_index: u32 = 0,
};

pub fn packTextures(
    allocator: std.mem.Allocator,
    models_info: *std.EnumArray(ModelName, ModelInfo),
    atlas_width: i32,
    atlas_height: i32,
) !PackResult {
    var texture_rects = std.ArrayList(TextureRect){};
    defer texture_rects.deinit(allocator);

    // 收集所有纹理
    var model_it = models_info.iterator();
    while (model_it.next()) |model| {
        const color = &model.value.color_texture;
        if (color.size[0] > 0 and color.size[1] > 0) {
            try texture_rects.append(allocator, TextureRect{
                .width = color.size[0],
                .height = color.size[1],
                .model_name = model.key,
                .texture_type = .color,
            });
        }
        const anime = &model.value.anime_texture;
        if (anime.size[0] > 0 and anime.size[1] > 0) {
            try texture_rects.append(allocator, TextureRect{
                .width = anime.size[0],
                .height = anime.size[1],
                .model_name = model.key,
                .texture_type = .anime,
            });
        }
    }

    const color_count = try packType(allocator, models_info, texture_rects.items, atlas_width, atlas_height, .color);
    const anime_count = try packType(allocator, models_info, texture_rects.items, atlas_width, atlas_height, .anime);

    return PackResult{
        .color_atlas_count = color_count,
        .anime_atlas_count = anime_count,
    };
}

/// 简单的逐行（shelf）纹理打包器
fn packType(
    allocator: std.mem.Allocator,
    models_info: *std.EnumArray(ModelName, ModelInfo),
    all_rects: []TextureRect,
    atlas_width: i32,
    atlas_height: i32,
    texture_type: TextureType,
) !u32 {
    // 筛选出当前类型
    var rects = std.ArrayList(TextureRect){};
    defer rects.deinit(allocator);

    for (all_rects) |r|
        if (r.texture_type == texture_type) try rects.append(allocator, r);

    if (rects.items.len == 0) return 0;

    // 按高度从大到小排序（减少碎片）
    std.sort.heap(TextureRect, rects.items, {}, struct {
        fn less(_: void, a: TextureRect, b: TextureRect) bool {
            return a.height > b.height;
        }
    }.less);

    var atlas_index: u32 = 0;
    var x: i32 = 0;
    var y: i32 = 0;
    var row_h: i32 = 0;

    for (rects.items) |*r| {
        const w = @as(i32, @intFromFloat(r.width));
        const h = @as(i32, @intFromFloat(r.height));

        // 检查是否能放进当前行
        if (x + w > atlas_width) {
            // 换行
            x = 0;
            y += row_h;
            row_h = 0;
        }

        // 如果高度超出图集则新建一张 atlas
        if (y + h > atlas_height) {
            atlas_index += 1;
            x = 0;
            y = 0;
            row_h = 0;
        }

        // 放置矩形
        r.x = x;
        r.y = y;
        r.atlas_index = atlas_index;

        updateModelTextureInfo(models_info, r);

        x += w;
        if (h > row_h) row_h = h;
    }

    return atlas_index + 1; // 图集数量
}

fn updateModelTextureInfo(models_info: *std.EnumArray(ModelName, ModelInfo), rect: *const TextureRect) void {
    const model_info = models_info.getPtr(rect.model_name);
    const tex = switch (rect.texture_type) {
        .color => &model_info.color_texture,
        .anime => &model_info.anime_texture,
    };
    tex.coords_offset = .{ rect.x, rect.y };
    tex.index = rect.atlas_index;
    tex.size = .{ rect.width, rect.height };
}
