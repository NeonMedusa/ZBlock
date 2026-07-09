// inventory_screen.zig — 背包界面（网格 + 与热栏交换）
const std = @import("std");
const Game = @import("../game.zig");
const IconAtlas = @import("../icon_atlas.zig").IconAtlas;
const tr = @import("../i18n.zig").tr;
const ItemStack = @import("../inventory.zig").ItemStack;
const item_infos = @import("../item_registry.zig").item_infos;

const cols: usize = 9;
const rows: usize = 3;
const slot_size: f32 = 50;
const gap: f32 = 4;

fn layoutInfo(game: *Game) struct { f32, f32, f32, f32 } {
    const win_w = game.window.width;
    const win_h = game.window.height;
    const grid_w = @as(f32, @floatFromInt(cols)) * slot_size + @as(f32, @floatFromInt(cols - 1)) * gap;
    const start_x = (win_w - grid_w) / 2;
    const start_y = win_h / 2 - @as(f32, @floatFromInt(rows)) * (slot_size + gap) / 2;
    return .{ win_w, win_h, start_x, start_y };
}

/// ESC/B 键处理
pub fn update(game: *Game) void {
    if (game.keybinds.isJustPressed(&game.input, .pause_menu) or game.keybinds.isJustPressed(&game.input, .toggle_inventory)) {
        game.selected_item = null;
        game.menu_state = .Gameplay;
    }
}

/// 绘制下层：遮罩 + 标题 + 槽位背景 + 边框
pub fn drawBg(game: *Game) void {
    const ui = &game.ui_system;
    const _w, const _h, const start_x, const start_y = layoutInfo(game);
    _ = _w; _ = _h;

    ui.drawOverlay(0.4);
    ui.drawText(&game.gctx, start_x, start_y - 40, tr("ui.inventory"), 24, .{ 1, 1, 1, 1 });

    const mouse = game.input.getCursorPos();
    for (0..rows) |r| {
        for (0..cols) |c| {
            const x = start_x + @as(f32, @floatFromInt(c)) * (slot_size + gap);
            const y = start_y + @as(f32, @floatFromInt(r)) * (slot_size + gap);
            const hover = mouse.x >= x and mouse.x <= x + slot_size and mouse.y >= y and mouse.y <= y + slot_size;
            ui.drawSlotBg(x, y, slot_size, false, hover);
        }
    }
}

/// 绘制上层：图标 + 数量文字 + 处理点击
pub fn drawFg(game: *Game) void {
    const ui = &game.ui_system;
    const win_w, const win_h, const start_x, const start_y = layoutInfo(game);
    const mouse = game.input.getCursorPos();

    for (0..rows) |r| {
        for (0..cols) |c| {
            const idx = r * cols + c;
            const x = start_x + @as(f32, @floatFromInt(c)) * (slot_size + gap);
            const y = start_y + @as(f32, @floatFromInt(r)) * (slot_size + gap);

            ui.drawSlotFg(x, y, slot_size, game.inventory.slots[idx], &game.icon_atlas);

            const hover = mouse.x >= x and mouse.x <= x + slot_size and mouse.y >= y and mouse.y <= y + slot_size;
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

    const target_item = switch (source) {
        .hotbar => &hotbar.slots[slot_idx],
        .inventory => &inv.slots[slot_idx],
    };

    if (sel.* == null) {
        if (target_item.item_id == 0) return;
        sel.* = .{ .source = source, .slot_idx = slot_idx, .item = target_item.* };
    } else {
        const selected = sel.*.?;
        if (selected.source == source and selected.slot_idx == slot_idx) {
            sel.* = null;
            return;
        }

        const src_item = switch (selected.source) {
            .hotbar => &hotbar.slots[selected.slot_idx],
            .inventory => &inv.slots[selected.slot_idx],
        };

        if (target_item.item_id == selected.item.item_id and target_item.item_id != 0) {
            const max = item_infos[@as(usize, @intCast(src_item.item_id))].max_stack;
            const space = max - target_item.count;
            if (space > 0) {
                const move = @min(src_item.count, space);
                target_item.count += move;
                src_item.count -= move;
                if (src_item.count == 0) { src_item.* = .{}; sel.* = null; }
                return;
            }
        }

        const tmp = target_item.*;
        target_item.* = src_item.*;
        src_item.* = tmp;
        sel.* = null;
    }
}