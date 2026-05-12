// pause_menu.zig — 游戏内暂停菜单
const Game = @import("../game.zig");

pub fn update(_: *@This(), game: *Game) void {
    if (game.keybinds.isJustPressed(&game.input, .pause_menu)) {
        game.menu_state = .Gameplay;
        return;
    }

    const win_w = game.window.width;
    const win_h = game.window.height;

    // 半透明遮罩
    game.ui_system.drawRect(0, 0, win_w, win_h, .{ 0, 0, 0, 0.5 });

    const btn_w: f32 = 240;
    const btn_h: f32 = 56;
    const btn_x = game.ui_system.centerX(win_w, btn_w);
    const btn_y1 = win_h / 2 - btn_h - 10;
    const btn_y2 = win_h / 2 + 10;

    if (game.ui_system.textButton(btn_x, btn_y1, btn_w, btn_h, "继续游戏", 22)) {
        game.menu_state = .Gameplay;
    }

    if (game.ui_system.textButton(btn_x, btn_y2, btn_w, btn_h, "返回主菜单", 22)) {
        game.returnToMenu();
        game.menu_state = .MainMenu;
    }
}
