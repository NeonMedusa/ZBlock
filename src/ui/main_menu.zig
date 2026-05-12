// main_menu.zig — 居中宽按钮主菜单
//
// 游标式 UI API 示例 —— 不需要手动计算每个按钮的精确像素坐标，
// 只需要设定一个"初始位置"，按钮会自动排列下去。
const Game = @import("../game.zig");

pub fn update(_: *@This(), game: *Game) void {
    // ── 1. 拿到 UiSystem 的引用 ──
    // ui 就是渲染 + 输入 + 布局的集合体，所有 UI 功能都通过它调用
    const ui = &game.ui_system;

    // ── 2. 设定两个关键的"锚点" ──
    //
    // cursor_col_x  —— 当前"列"的 X 起点
    //                 每个按钮默认从这一列开始对齐
    //                 这里用 centerX 算出 240px 宽的按钮在窗口中的居中 X
    //
    // cursor_y      —— 下一个 widget 的 Y 坐标
    //                 相当于一个"光标"，每放一个 widget 就会向下移动
    //                 这里从窗口垂直居中偏上 20px 的位置开始
    ui.cursor_col_x = ui.centerX(game.window.width, 240);
    ui.cursor_y = game.window.height / 2 - 56 - 20;

    // ── 3. 放置两个按钮 ──
    //
    // button("文字", 宽, 高, 字号) :
    //   1. 在当前的 (cursor_x, cursor_y) 位置画一个按钮
    //   2. 自动在内部记录 row_bottom_y = cursor_y + 按钮高度
    //   3. 返回 true 表示鼠标正按在这颗按钮上（本帧被点击）
    //
    // 因为是同一个"自然行"里的第一个按钮（没有 sameLine），
    // button 会把 cursor_x 重置到 cursor_col_x 对齐。
    if (ui.button("开始", 240, 56, 22))
        game.menu_state = .SaveSelect; // 点击后进入存档选择

    // ── 4. 在两个按钮之间留出 40px 垂直间距 ──
    //
    // spacing(h):
    //   把 cursor_y 推到 row_bottom_y（第一颗按钮的底部）+ h
    //   相当于"空一行"，下一个 widget 从这里开始
    ui.spacing(40);

    // 第二个按钮：
    //   因为是新的一行（没有 sameLine），cursor_x 再次对齐到 cursor_col_x
    //   cursor_y 已经在 spacing 时被推到 row_bottom_y + 40，
    //   所以第二颗按钮自然地排在下面，间距 40px
    if (ui.button("退出", 240, 56, 22))
        game.window.setWindowShouldClose(); // 关闭窗口
}
