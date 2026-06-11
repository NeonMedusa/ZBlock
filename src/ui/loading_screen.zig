//! loading_screen.zig — 世界加载等待界面
//!
//! 在 initGame() 的同步等待循环中被调用，仅显示黑底 + 加载提示文字。
//! 加载完成后由 initGame() 继续后续流程，此模块不控制状态跳转。
//!
//! 文字内容根据 pendingIOCount 自动切换：
//! - pendingIOCount > 0 → "正在加载世界..."（从存档读取区块）
//! - pendingIOCount = 0 → "正在生成世界..."（新世界生成 mesh）

const Game = @import("../game.zig");

/// 在加载循环中每帧调用，绘制黑底 + 加载提示
pub fn draw(game: *Game) void {
    const ui = &game.ui_system;
    const w = game.window.width;
    const h = game.window.height;
    ui.drawRect(0, 0, w, h, .{ 0, 0, 0, 1 });

    const text: []const u8 = if (game.block_world.pendingIOCount() > 0)
        "正在加载世界..."
    else
        "正在生成世界...";

    const text_w = ui.measureText(&game.gctx, text, 24);
    ui.drawText(&game.gctx, (w - text_w) / 2, h / 2 - 12, text, 24, .{ 1, 1, 1, 1 });
}
