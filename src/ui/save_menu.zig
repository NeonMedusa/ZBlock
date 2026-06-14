// save_menu.zig — 存档管理界面（列表 + 翻页 + 新游戏/删除）
const std = @import("std");
const Game = @import("../game.zig");
const UiSystem = @import("../ui_system.zig");
const SaveManager = @import("../save_manager.zig").SaveManager;
const SaveEntry = @import("../save_manager.zig").SaveEntry;

scroll: u32 = 0,
entries: []SaveEntry = &.{},

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    for (self.entries) |e| {
        allocator.free(e.name);
        allocator.free(e.last_played);
    }
    allocator.free(self.entries);
}

pub fn refresh(self: *@This(), allocator: std.mem.Allocator) void {
    for (self.entries) |e| {
        allocator.free(e.name);
        allocator.free(e.last_played);
    }
    allocator.free(self.entries);
    self.entries = SaveManager.listSaves(allocator) catch &.{};
    self.scroll = 0;
}

pub fn update(self: *@This(), game: *Game) void {
    const win_w = game.window.width;
    const win_h = game.window.height;
    const col_w: f32 = 400;
    const col_x = game.ui_system.centerX(win_w, col_w);
    const row_h: f32 = 64;
    const rows_shown: u32 = 5;
    const list_top: f32 = 100;

    if (game.keybinds.isJustPressed(&game.input, .pause_menu)) {
        game.menu_state = .MainMenu;
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

        if (game.ui_system.textButton(col_x + col_w - 80, y + 12, 70, row_h - 24, "删除", 18)) {
            SaveManager.deleteSave(entry.name) catch {};
            self.refresh(game.allocator);
            return;
        }

        if (clicked) {
            game.startSave(entry.name) catch {};
            game.menu_state = .Gameplay;
            return;
        }
    }

    game.ui_system.cursor_col_x = col_x + 10;
    game.ui_system.cursor_y = win_h - 80;
    if (game.ui_system.button("← 返回", 180, 44, 18)) {
        game.menu_state = .MainMenu;
        return;
    }
    game.ui_system.sameLine(20);
    if (game.ui_system.button("新游戏", 180, 44, 18)) {
        const name = SaveManager.autoName(game.allocator) catch return;
        defer game.allocator.free(name);
        game.startSave(name) catch {};
        game.menu_state = .Gameplay;
    }

    // 左下角显示当前用户
    var name_buf: [128]u8 = undefined;
    const name_str = std.fmt.bufPrint(&name_buf, "当前用户：{s}", .{game.player_name}) catch "当前用户：?";
    game.ui_system.drawText(&game.gctx, 8, win_h - 24, name_str, 18, .{ 1, 1, 1, 1 });
}
