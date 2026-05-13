// pause_menu.zig — 游戏内暂停菜单
const Game = @import("../game.zig");

pub fn update(_: *@This(), game: *Game) void {
    if (game.keybinds.isJustPressed(&game.input, .pause_menu)) {
        game.menu_state = .Gameplay;
        return;
    }

    const win_w = game.window.width;
    const win_h = game.window.height;
    const ui = &game.ui_system;

    ui.drawOverlay(0.5);

    ui.cursor_col_x = ui.centerX(win_w, 240);
    ui.cursor_y = win_h / 2 - 56 - 10;

    if (ui.button("继续游戏", 240, 56, 22)) {
        game.menu_state = .Gameplay;
    }

    ui.spacing(20);
    if (ui.button("返回主菜单", 240, 56, 22)) {
        game.returnToMenu();
        game.menu_state = .MainMenu;
    }
}
