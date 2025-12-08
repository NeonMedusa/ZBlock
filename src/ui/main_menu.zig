//main_menu.zig
visible: bool = true,
pub fn update(self: *@This(), game: *Game) void {
    // ESC键切换主菜单是否可见
    if (game.input.isKeyDown(.escape))
        self.visible = !self.visible;
    // 如果自身为不可见状态，则直接返回不做渲染
    if (!self.visible) return;
    // 继续游戏按钮
    if (game.ui_system.button(20, 20))
        self.visible = !self.visible;
    // 退出游戏按钮
    if (game.ui_system.button(500, 20))
        game.window.setWindowShouldClose();
}
const std = @import("std");
const UiSystem = @import("../ui_system.zig");
const Game = @import("../game.zig");
