const std = @import("std");
const TextureInfo = @import("shader_types.zig").TextureInfo;
const ModelInfo = @import("shader_types.zig").ModelInfo;
const ModelName = @import("model.zig").ModelName;
// 纹理矩形定义
const TextureRect = struct {
    width: f32,
    height: f32,
    model_name: ModelName,
    ispacked: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    atlas_index: u32 = 0,
};
// 用于装箱算法的节点
const PackNode = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    used: bool = false,
    right: ?*PackNode = null,
    down: ?*PackNode = null,
};
pub fn packTextures(
    allocator: std.mem.Allocator,
    models_info: *std.EnumArray(ModelName, ModelInfo),
    atlas_width: i32,
    altas_heigth: i32,
) !u32 {
    // 步骤1: 收集所有需要打包的纹理
    var texture_rects = std.ArrayList(TextureRect){};
    defer texture_rects.deinit(allocator);

    var model_it = models_info.iterator();
    while (model_it.next()) |model| {
        const texture_info = &model.value.color_texture;

        // 只处理有有效尺寸的纹理
        if (texture_info.size[0] > 0 and texture_info.size[1] > 0) {
            try texture_rects.append(allocator, TextureRect{
                .width = texture_info.size[0],
                .height = texture_info.size[1],
                .model_name = model.key,
            });
        }
    }

    // 步骤2: 按面积排序（从大到小），提高装箱效率
    std.sort.heap(TextureRect, texture_rects.items, {}, struct {
        fn compare(_: void, a: TextureRect, b: TextureRect) bool {
            const area_a = a.width * a.height;
            const area_b = b.width * b.height;
            return area_a > area_b;
        }
    }.compare);

    // 步骤3: 执行装箱算法
    var atlas_count: u32 = 0;
    var remaining_textures = texture_rects.items;

    while (remaining_textures.len > 0) {
        // 为当前图集创建根节点
        const root = try allocator.create(PackNode);
        root.* = PackNode{
            .x = 0,
            .y = 0,
            .width = atlas_width,
            .height = altas_heigth,
        };

        // 尝试将纹理打包到当前图集
        var ispacked_count: usize = 0;
        for (remaining_textures) |*rect| {
            if (!rect.ispacked) {
                if (try packTexture(root, rect, allocator)) {
                    rect.atlas_index = atlas_count;
                    rect.ispacked = true;
                    ispacked_count += 1;

                    // 更新模型的纹理信息
                    const model_info = models_info.getPtr(rect.model_name);
                    model_info.color_texture.coords_offset = .{ rect.x, rect.y };
                    model_info.color_texture.index = atlas_count;
                }
            }
        }

        // 清理当前图集的节点内存
        freePackNode(root, allocator);
        allocator.destroy(root);

        // 如果没有纹理能放入当前图集，但还有剩余纹理，说明有纹理太大
        if (ispacked_count == 0 and remaining_textures.len > 0) {
            // 处理过大的纹理：强制放入新图集
            const rect = &remaining_textures[0];
            rect.x = 0;
            rect.y = 0;
            rect.atlas_index = atlas_count;
            rect.ispacked = true;

            const model_info = models_info.getPtr(rect.model_name);
            model_info.color_texture.coords_offset = .{ 0, 0 };
            model_info.color_texture.index = atlas_count;

            ispacked_count = 1;

            std.log.warn("Texture too large for atlas: {}x{}, forcing into atlas {}", .{ rect.width, rect.height, atlas_count });
        }

        // 移动到下一个图集
        atlas_count += 1;

        // 更新剩余纹理列表
        var new_remaining = std.ArrayList(TextureRect){};
        for (remaining_textures) |rect| {
            if (!rect.ispacked) {
                try new_remaining.append(allocator, rect);
            }
        }
        remaining_textures = try new_remaining.toOwnedSlice(allocator);
        new_remaining.deinit(allocator);
    }
    return atlas_count;
}

// 递归打包纹理
fn packTexture(node: *PackNode, rect: *TextureRect, allocator: std.mem.Allocator) !bool {
    // 如果节点已被使用，尝试右子节点或下子节点
    if (node.used) {
        if (node.right) |right| {
            if (try packTexture(right, rect, allocator)) return true;
        }
        if (node.down) |down| {
            if (try packTexture(down, rect, allocator)) return true;
        }
        return false;
    }

    const rect_width = @as(i32, @intFromFloat(rect.width));
    const rect_height = @as(i32, @intFromFloat(rect.height));

    // 检查当前节点是否能容纳纹理
    if (rect_width <= node.width and rect_height <= node.height) {
        // 标记节点为已使用
        node.used = true;

        // 设置纹理坐标
        rect.x = node.x;
        rect.y = node.y;

        // 创建右子节点（剩余的水平空间）
        if (node.width > rect_width) {
            node.right = try allocator.create(PackNode);
            node.right.?.* = PackNode{
                .x = node.x + rect_width,
                .y = node.y,
                .width = node.width - rect_width,
                .height = rect_height,
            };
        }

        // 创建下子节点（剩余的垂直空间）
        if (node.height > rect_height) {
            node.down = try allocator.create(PackNode);
            node.down.?.* = PackNode{
                .x = node.x,
                .y = node.y + rect_height,
                .width = node.width,
                .height = node.height - rect_height,
            };
        }

        return true;
    }

    return false;
}

// 释放打包节点的内存
fn freePackNode(node: *PackNode, allocator: std.mem.Allocator) void {
    if (node.right) |right| {
        freePackNode(right, allocator);
        allocator.destroy(right);
    }
    if (node.down) |down| {
        freePackNode(down, allocator);
        allocator.destroy(down);
    }
}
