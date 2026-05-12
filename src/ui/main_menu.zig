//main_menu.zig — 居中宽按钮主菜单
pub fn update(_: *@This(), game: *Game) void {
    const win_w = game.window.width;
    const win_h = game.window.height;

    const btn_w: f32 = 240;
    const btn_h: f32 = 56;
    const btn_x = game.ui_system.centerX(win_w, btn_w);
    const btn_y1 = win_h / 2 - btn_h - 20;
    const btn_y2 = win_h / 2 + 20;
    const font_size: f32 = 22;

    if (game.ui_system.textButton(btn_x, btn_y1, btn_w, btn_h, "开始", font_size))
        game.menu_state = .SaveSelect;

    if (game.ui_system.textButton(btn_x, btn_y2, btn_w, btn_h, "退出", font_size))
        game.window.setWindowShouldClose();
}
const Game = @import("../game.zig");
