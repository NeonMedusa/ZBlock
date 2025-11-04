const std = @import("std");
const TextureInfo = @import("shader_types.zig").TextureInfo;
const ModelInfo = @import("shader_types.zig").ModelInfo;
const ModelName = @import("model.zig").ModelName;

// 纹理矩形定义
const TextureRect = struct {
    width: f32,
    height: f32,
    model_name: ModelName,
    texture_type: TextureType,
    ispacked: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    atlas_index: u32 = 0,
};

// 纹理类型枚举
const TextureType = enum {
    color,
    anime,
};

// 简化的装箱节点
const PackNode = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    used: bool = false,
    right: ?*PackNode = null,
    down: ?*PackNode = null,
};

// 装箱结果
pub const PackResult = struct {
    color_atlas_count: u32,
    anime_atlas_count: u32,
};

pub fn packTextures(
    allocator: std.mem.Allocator,
    models_info: *std.EnumArray(ModelName, ModelInfo),
    atlas_width: i32,
    atlas_height: i32,
) !PackResult {
    // 收集所有纹理
    var texture_rects = std.ArrayList(TextureRect){};
    defer texture_rects.deinit(allocator);

    var model_it = models_info.iterator();
    while (model_it.next()) |model| {
        // 处理color_texture
        const color_texture_info = &model.value.color_texture;
        if (color_texture_info.size[0] > 0 and color_texture_info.size[1] > 0) {
            try texture_rects.append(allocator, TextureRect{
                .width = color_texture_info.size[0],
                .height = color_texture_info.size[1],
                .model_name = model.key,
                .texture_type = .color,
            });
        }

        // 处理anime_texture
        const anime_texture_info = &model.value.anime_texture;
        if (anime_texture_info.size[0] > 0 and anime_texture_info.size[1] > 0) {
            try texture_rects.append(allocator, TextureRect{
                .width = anime_texture_info.size[0],
                .height = anime_texture_info.size[1],
                .model_name = model.key,
                .texture_type = .anime,
            });
        }
    }

    // 按纹理类型分组并分别打包
    const color_atlas_count = try packTextureGroup(allocator, models_info, texture_rects.items, atlas_width, atlas_height, .color);
    const anime_atlas_count = try packTextureGroup(allocator, models_info, texture_rects.items, atlas_width, atlas_height, .anime);

    return PackResult{
        .color_atlas_count = color_atlas_count,
        .anime_atlas_count = anime_atlas_count,
    };
}

fn packTextureGroup(
    allocator: std.mem.Allocator,
    models_info: *std.EnumArray(ModelName, ModelInfo),
    all_texture_rects: []TextureRect,
    atlas_width: i32,
    atlas_height: i32,
    texture_type: TextureType,
) !u32 {
    // 过滤出指定类型的纹理
    var filtered_rects = std.ArrayList(TextureRect){};
    defer filtered_rects.deinit(allocator);

    for (all_texture_rects) |rect| {
        if (rect.texture_type == texture_type) {
            try filtered_rects.append(allocator, rect);
        }
    }

    if (filtered_rects.items.len == 0) {
        return 0;
    }

    // 按面积从大到小排序
    std.sort.heap(TextureRect, filtered_rects.items, {}, struct {
        fn compare(_: void, a: TextureRect, b: TextureRect) bool {
            return (a.width * a.height) > (b.width * b.height);
        }
    }.compare);

    return try performPacking(allocator, models_info, filtered_rects.items, atlas_width, atlas_height, texture_type);
}

fn performPacking(
    allocator: std.mem.Allocator,
    models_info: *std.EnumArray(ModelName, ModelInfo),
    texture_rects: []TextureRect,
    atlas_width: i32,
    atlas_height: i32,
    texture_type: TextureType,
) !u32 {
    var atlas_count: u32 = 0;
    var remaining_textures = try allocator.dupe(TextureRect, texture_rects);
    defer allocator.free(remaining_textures);

    while (remaining_textures.len > 0) {
        // 创建新的图集
        var nodes = std.ArrayList(*PackNode){};
        defer {
            for (nodes.items) |node| {
                freePackNode(node, allocator);
                allocator.destroy(node);
            }
        }

        const root = try allocator.create(PackNode);
        try nodes.append(allocator, root);
        root.* = PackNode{
            .x = 0,
            .y = 0,
            .width = atlas_width,
            .height = atlas_height,
        };

        var ispacked_count: usize = 0;

        // 尝试打包每个纹理
        for (remaining_textures) |*rect| {
            if (!rect.ispacked and rect.texture_type == texture_type) {
                const rect_width = @as(i32, @intFromFloat(rect.width));
                const rect_height = @as(i32, @intFromFloat(rect.height));

                // 检查纹理是否过大
                if (rect_width > atlas_width or rect_height > atlas_height) {
                    std.log.warn("Texture {}x{} is too large for atlas {}x{}, skipping", .{ rect_width, rect_height, atlas_width, atlas_height });
                    continue;
                }

                // 在所有节点中寻找合适的位置
                var found_node: ?*PackNode = null;
                for (nodes.items) |node| {
                    if (try findNode(node, rect_width, rect_height, allocator)) |target_node| {
                        found_node = target_node;
                        break;
                    }
                }

                if (found_node) |node| {
                    // 放置纹理
                    rect.x = node.x;
                    rect.y = node.y;
                    rect.atlas_index = atlas_count;
                    rect.ispacked = true;
                    ispacked_count += 1;

                    // 分割节点
                    const remaining_width = node.width - rect_width;
                    const remaining_height = node.height - rect_height;

                    if (remaining_height > 0) {
                        const down_node = try allocator.create(PackNode);
                        try nodes.append(allocator, down_node);
                        down_node.* = PackNode{
                            .x = node.x,
                            .y = node.y + rect_height,
                            .width = node.width,
                            .height = remaining_height,
                        };
                    }

                    if (remaining_width > 0) {
                        const right_node = try allocator.create(PackNode);
                        try nodes.append(allocator, right_node);
                        right_node.* = PackNode{
                            .x = node.x + rect_width,
                            .y = node.y,
                            .width = remaining_width,
                            .height = rect_height,
                        };
                    }

                    node.used = true;
                    updateModelTextureInfo(models_info, rect);
                }
            }
        }

        // 如果没有纹理被打包且还有剩余纹理，强制打包最大的一个
        if (ispacked_count == 0 and remaining_textures.len > 0) {
            var largest_index: usize = 0;
            var largest_area: f32 = 0;

            for (remaining_textures, 0..) |rect, i| {
                if (!rect.ispacked and rect.texture_type == texture_type) {
                    const area = rect.width * rect.height;
                    if (area > largest_area) {
                        largest_area = area;
                        largest_index = i;
                    }
                }
            }

            const rect = &remaining_textures[largest_index];
            const rect_width = @as(i32, @intFromFloat(rect.width));
            const rect_height = @as(i32, @intFromFloat(rect.height));

            // 检查是否可以放入
            if (rect_width <= atlas_width and rect_height <= atlas_height) {
                rect.x = 0;
                rect.y = 0;
                rect.atlas_index = atlas_count;
                rect.ispacked = true;
                updateModelTextureInfo(models_info, rect);
                ispacked_count = 1;
                std.log.warn("Forced large texture {}x{} into atlas {}", .{ rect.width, rect.height, atlas_count });
            }
        }

        atlas_count += 1;

        // 更新剩余纹理列表
        var new_remaining = std.ArrayList(TextureRect){};
        defer new_remaining.deinit(allocator);

        for (remaining_textures) |rect| {
            if (!rect.ispacked) {
                try new_remaining.append(allocator, rect);
            }
        }

        allocator.free(remaining_textures);
        remaining_textures = try new_remaining.toOwnedSlice(allocator);
    }

    return atlas_count;
}

fn findNode(node: *PackNode, width: i32, height: i32, allocator: std.mem.Allocator) !?*PackNode {
    if (node.used) {
        if (node.right) |right| {
            if (try findNode(right, width, height, allocator)) |found| {
                return found;
            }
        }
        if (node.down) |down| {
            if (try findNode(down, width, height, allocator)) |found| {
                return found;
            }
        }
        return null;
    }

    // 检查节点是否足够大
    if (width <= node.width and height <= node.height) {
        // 检查边界
        if (node.x + width <= node.width and node.y + height <= node.height) {
            return node;
        }
    }

    return null;
}

fn updateModelTextureInfo(models_info: *std.EnumArray(ModelName, ModelInfo), rect: *const TextureRect) void {
    const model_info = models_info.getPtr(rect.model_name);
    const texture_info = switch (rect.texture_type) {
        .color => &model_info.color_texture,
        .anime => &model_info.anime_texture,
    };

    texture_info.coords_offset = .{ rect.x, rect.y };
    texture_info.index = rect.atlas_index;
}

fn freePackNode(node: *PackNode, allocator: std.mem.Allocator) void {
    if (node.right) |right| {
        freePackNode(right, allocator);
        allocator.destroy(right);
        node.right = null;
    }
    if (node.down) |down| {
        freePackNode(down, allocator);
        allocator.destroy(down);
        node.down = null;
    }
}
