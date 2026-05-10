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
    // 按钮文字
    game.ui_system.drawText(&game.gctx, 28, 42, "继续", 20, .{ 1, 1, 1, 1 });
    game.ui_system.drawText(&game.gctx, 528, 42, "quit", 20, .{ 1, 1, 1, 1 });
}
const std = @import("std");
const UiSystem = @import("../ui_system.zig");
const Game = @import("../game.zig");
