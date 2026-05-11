//main_menu.zig — 居中宽按钮主菜单
visible: bool = true,
pub fn update(self: *@This(), game: *Game) void {
    if (game.input.isKeyJustPressed(.escape))
        self.visible = !self.visible;
    if (!self.visible) return;

    const win_w = game.window.width;
    const win_h = game.window.height;

    const btn_w: f32 = 240;
    const btn_h: f32 = 56;
    const btn_x = (win_w - btn_w) / 2;
    const btn_y1 = (win_h - btn_h) / 2 - 36;
    const btn_y2 = (win_h - btn_h) / 2 + 36;
    const font_size: f32 = 22;

    if (game.ui_system.button(btn_x, btn_y1, btn_w, btn_h))
        self.visible = !self.visible;

    if (game.ui_system.button(btn_x, btn_y2, btn_w, btn_h))
        game.window.setWindowShouldClose();

    // 文字居中于按钮
    game.ui_system.drawText(&game.gctx, btn_x + (btn_w - 40) / 2, btn_y1 + 38, "继续", font_size, .{ 1, 1, 1, 1 });
    game.ui_system.drawText(&game.gctx, btn_x + (btn_w - 40) / 2, btn_y2 + 38, "退出", font_size, .{ 1, 1, 1, 1 });
}
const std = @import("std");
const UiSystem = @import("../ui_system.zig");
const Game = @import("../game.zig");
