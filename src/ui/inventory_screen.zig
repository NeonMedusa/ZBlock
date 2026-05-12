// inventory_screen.zig — 背包界面（网格 + 与热栏交换）
const std = @import("std");
const Game = @import("../game.zig");
const IconAtlas = @import("../icon_atlas.zig").IconAtlas;
const ItemStack = @import("../inventory.zig").ItemStack;
const BlockId = @import("../block_registry.zig").BlockId;
const air_id = @intFromEnum(BlockId.fromName("air"));

pub fn update(game: *Game) void {
    const ui = &game.ui_system;
    const win_w = game.window.width;
    const win_h = game.window.height;

    // 半透明遮罩（让背包背景半透明）
    ui.drawRect(0, 0, win_w, win_h, .{ 0, 0, 0, 0.4 });

    // 背包网格布局
    const cols: usize = 9;
    const rows: usize = 3;
    const slot_size: f32 = 50;
    const gap: f32 = 4;
    const grid_w = @as(f32, @floatFromInt(cols)) * slot_size + @as(f32, @floatFromInt(cols - 1)) * gap;
    const start_x = (win_w - grid_w) / 2;
    const start_y = win_h / 2 - @as(f32, @floatFromInt(rows)) * (slot_size + gap) / 2;

    // 绘制标题
    ui.drawText(&game.gctx, start_x, start_y - 40, "背包", 24, .{ 1, 1, 1, 1 });

    // 渲染网格 + 处理点击
    const mouse = game.input.getCursorPos();

    for (0..rows) |r| {
        for (0..cols) |c| {
            const idx = r * cols + c;
            const x = start_x + @as(f32, @floatFromInt(c)) * (slot_size + gap);
            const y = start_y + @as(f32, @floatFromInt(r)) * (slot_size + gap);

            const hover = mouse.x >= x and mouse.x <= x + slot_size and mouse.y >= y and mouse.y <= y + slot_size;
            const bg: [4]f32 = if (hover) .{ 0.4, 0.4, 0.4, 1.0 } else .{ 0.2, 0.2, 0.2, 0.9 };
            ui.drawRect(x, y, slot_size, slot_size, bg);

            // 边框
            const border: [4]f32 = .{ 0.3, 0.3, 0.3, 1.0 };
            ui.drawRect(x, y, slot_size, 1, border);
            ui.drawRect(x, y + slot_size - 1, slot_size, 1, border);
            ui.drawRect(x, y, 1, slot_size, border);
            ui.drawRect(x + slot_size - 1, y, 1, slot_size, border);

            const item = game.inventory.slots[idx];
            if (@intFromEnum(item.block_id) != air_id) {
                if (game.icon_atlas.getOrLoad(@intFromEnum(item.block_id))) |slot_i| {
                    game.icon_atlas.addQuad(IconAtlas.slotUV(slot_i), x + 4, y + 4, slot_size - 8);
                }
                var buf: [16]u8 = undefined;
                if (item.count > 1) {
                    const count_str = std.fmt.bufPrint(&buf, "{d}", .{item.count}) catch unreachable;
                    ui.drawText(&game.gctx, x + slot_size - 20, y + slot_size - 22, count_str, 12, .{ 1, 1, 1, 1 });
                }
            }

            // 点击处理
            if (hover and game.input.isMouseJustPressed(.mouse_left)) {
                handleSlotClick(game, .inventory, idx);
            }
        }
    }

    // 热栏点击处理（背包打开时热栏也可交互）
    const hx = (win_w - (9 * slot_size + 8 * gap)) / 2;
    const hy = win_h - 60;
    for (0..9) |i| {
        const x = hx + @as(f32, @floatFromInt(i)) * (slot_size + gap);
        const y = hy;
        const hover = mouse.x >= x and mouse.x <= x + slot_size and mouse.y >= y and mouse.y <= y + slot_size;
        if (hover and game.input.isMouseJustPressed(.mouse_left)) {
            handleSlotClick(game, .hotbar, i);
        }
    }
}

fn handleSlotClick(game: *Game, source: Game.SlotSource, slot_idx: usize) void {
    const sel = &game.selected_item;
    const hotbar = &game.hotbar;
    const inv = &game.inventory;

    // 根据 source + slot_idx 获取目标物品
    const target_item = switch (source) {
        .hotbar => &hotbar.slots[slot_idx],
        .inventory => &inv.slots[slot_idx],
    };

    if (sel.* == null) {
        // 未选中 → 选中（不能选空气）
        if (@intFromEnum(target_item.block_id) == air_id) return;
        sel.* = .{
            .source = source,
            .slot_idx = slot_idx,
            .item = target_item.*,
        };
    } else {
        // 已选中 → 交换
        const selected = sel.*.?;
        if (selected.source == source and selected.slot_idx == slot_idx) {
            // 点同一个格子 → 取消选中
            sel.* = null;
            return;
        }

        // 获取来源物品
        const src_item = switch (selected.source) {
            .hotbar => &hotbar.slots[selected.slot_idx],
            .inventory => &inv.slots[selected.slot_idx],
        };

        // 交换
        const tmp = target_item.*;
        target_item.* = src_item.*;
        src_item.* = tmp;
        sel.* = null;
    }
}