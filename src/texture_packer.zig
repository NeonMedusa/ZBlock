const std = @import("std");
const TextureInfo = @import("shader_types.zig").TextureInfo;

/// 简单的逐行（shelf）纹理打包器
pub fn packTextures(
    allocator: std.mem.Allocator,
    texture_infos: []*TextureInfo,
    atlas_width: i32,
    atlas_height: i32,
) !u32 {
    if (texture_infos.len == 0) return 0;

    // 创建纹理矩形列表
    var texture_rects = std.ArrayList(TextureRect){};
    defer texture_rects.deinit(allocator);

    // 将TextureInfo转换为TextureRect以便排序和打包
    for (texture_infos) |tex_info| {
        // 跳过大小为0的纹理
        if (tex_info.size[0] <= 0 or tex_info.size[1] <= 0) continue;

        try texture_rects.append(allocator, TextureRect{
            .width = tex_info.size[0],
            .height = tex_info.size[1],
            .texture_info = tex_info,
            .x = 0,
            .y = 0,
            .atlas_index = 0,
        });
    }

    if (texture_rects.items.len == 0) return 0;

    // 按高度从大到小排序（减少碎片）
    std.sort.heap(TextureRect, texture_rects.items, {}, struct {
        fn less(_: void, a: TextureRect, b: TextureRect) bool {
            return a.height > b.height;
        }
    }.less);

    var atlas_index: u32 = 0;
    var x: i32 = 0;
    var y: i32 = 0;
    var row_h: i32 = 0;

    for (texture_rects.items) |*r| {
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

        // 放置矩形并更新原始TextureInfo
        r.x = x;
        r.y = y;
        r.atlas_index = atlas_index;

        // 直接更新传入的TextureInfo指针
        r.texture_info.coord = .{ r.x, r.y };
        r.texture_info.index = r.atlas_index;
        r.texture_info.size = .{ r.width, r.height };

        x += w;
        if (h > row_h) row_h = h;
    }

    return atlas_index + 1; // 返回图集数量
}

/// 内部使用的纹理矩形结构
const TextureRect = struct {
    width: f32,
    height: f32,
    texture_info: *TextureInfo, // 指向原始的TextureInfo
    x: i32 = 0,
    y: i32 = 0,
    atlas_index: u32 = 0,
};
