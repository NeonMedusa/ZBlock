// save_menu.zig — 存档管理界面（列表 + 翻页 + 新游戏/删除）
const std = @import("std");
const Game = @import("../game.zig");
const UiSystem = @import("../ui_system.zig");
const SaveManager = @import("../save_manager.zig").SaveManager;
const SaveEntry = @import("../save_manager.zig").SaveEntry;

visible: bool = false,
scroll: u32 = 0,
entries: []SaveEntry = &.{},

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    for (self.entries) |e| { allocator.free(e.name); allocator.free(e.last_played); }
    allocator.free(self.entries);
}

pub fn refresh(self: *@This(), allocator: std.mem.Allocator) void {
    for (self.entries) |e| { allocator.free(e.name); allocator.free(e.last_played); }
    allocator.free(self.entries);
    self.entries = SaveManager.listSaves(allocator) catch &.{};
    self.scroll = 0;
}

pub fn update(self: *@This(), game: *Game) void {
    if (!self.visible) return;

    const win_w = game.window.width;
    const win_h = game.window.height;
    const col_w: f32 = 400;
    const col_x = game.ui_system.centerX(win_w, col_w);
    const row_h: f32 = 64;
    const rows_shown: u32 = 5;
    const list_top: f32 = 100;

    if (game.keybinds.isJustPressed(&game.input, .pause_menu)) {
        game.return_to_main_menu = true;
        self.visible = false;
        return;
    }

    const prev = game.input.isKeyJustPressed(.up);
    const next = game.input.isKeyJustPressed(.down);
    if (prev and self.scroll > 0) self.scroll -= 1;
    if (next and self.scroll + rows_shown < self.entries.len) self.scroll += 1;

    game.ui_system.drawText(&game.gctx, col_x, 30, "选择存档", 30, .{ 1, 1, 1, 1 });

    for (0..rows_shown) |r| {
        const idx = self.scroll + r;
        if (idx >= self.entries.len) break;
        const entry = self.entries[idx];
        const y = list_top + @as(f32, @floatFromInt(r)) * (row_h + 6);

        const hover = game.ui_system.buttonHover(col_x, y, col_w, row_h);
        const clicked = hover and game.input.isMouseJustPressed(.mouse_left);
        game.ui_system.drawButton(col_x, y, col_w, row_h, hover, false);
        game.ui_system.drawText(&game.gctx, col_x + 14, y + 10, entry.name, 20, .{ 1, 1, 1, 1 });
        if (entry.last_played.len > 0) {
            game.ui_system.drawText(&game.gctx, col_x + 14, y + 34, entry.last_played, 15, .{ 0.7, 0.7, 0.7, 1 });
        }

        if (game.ui_system.textButton(col_x + col_w - 80, y + 12, 70, row_h - 24, "删除", 16)) {
            SaveManager.deleteSave(entry.name) catch {};
            self.refresh(game.allocator);
            return;
        }

        if (clicked) {
            game.startSave(entry.name) catch {};
            self.visible = false;
            return;
        }
    }

    const btn_w: f32 = 180;
    const btn_h: f32 = 44;
    const btn_y = win_h - 80;
    const left_btn_x = col_x + 10;
    const right_btn_x = col_x + col_w - btn_w - 10;

    if (game.ui_system.textButton(left_btn_x, btn_y, btn_w, btn_h, "← 返回", 18)) {
        game.return_to_main_menu = true;
        self.visible = false;
        return;
    }

    if (game.ui_system.textButton(right_btn_x, btn_y, btn_w, btn_h, "新游戏", 18)) {
        const name = SaveManager.autoName(game.allocator) catch return;
        defer game.allocator.free(name);
        game.startSave(name) catch {};
        self.visible = false;
    }
}
