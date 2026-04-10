//main_menu.zig
visible: bool = true,
pub fn update(self: *@This(), game: *Game) void {
    // ESC键切换主菜单是否可见
    if (game.input.isKeyDown(.escape))
        self.visible = !self.visible;
    // 如果自身为不可见状态，则直接返回不做渲染
    if (!self.visible) return;

    // 继续游戏按钮
    if (game.ui_system.button(0, 300)) {
        self.visible = !self.visible;
        std.debug.print("Game exited cleanly.\n", .{});
    }

    // // 按钮1：缓冲区/数据错误
    // if (game.ui_system.button(0, 20)) {
    //     game.window.setWindowShouldClose();
    //     std.debug.print(
    //         \\[ISSUE REPORT] Data Error: Vertex or index buffer upload failed, or mesh data is malformed.
    //         \\Possible causes: `upload` call on vertex_buffer/index_buffer failed, or CPU-side vertex array length/content is incorrect.
    //         \\Expected: Buffers are valid and correctly bound. Observed: No geometry on screen, or random triangle fragments.
    //         \\
    //     , .{});
    // }

    // // 按钮2：几何剖分错误
    // if (game.ui_system.button(100, 20)) {
    //     game.window.setWindowShouldClose();
    //     std.debug.print(
    //         \\[ISSUE REPORT] Geometry Error: Triangulation or obstacle shape is incorrect.
    //         \\Possible causes: Constrained Delaunay triangulation failed, input polygon self-intersection, or incorrect obstacle vertex order.
    //         \\Observed: Missing triangles, overlapping faces, or deformed obstacles.
    //         \\
    //     , .{});
    // }

    // // 按钮3：寻路错误
    // if (game.ui_system.button(200, 20)) {
    //     game.window.setWindowShouldClose();
    //     std.debug.print(
    //         \\[ISSUE REPORT] Pathfinding Error: Path crosses obstacles or is not the shortest path.
    //         \\Possible causes: Missing graph connections, incorrect heuristic weight, or funnel algorithm failure.
    //         \\Observed: Agent walks through blocked areas or takes an unnecessarily long detour.
    //         \\
    //     , .{});
    // }

    // // 按钮4：死循环 / 程序未响应
    // if (game.ui_system.button(300, 20)) {
    //     game.window.setWindowShouldClose();
    //     std.debug.print(
    //         \\[ISSUE REPORT] Hang / Infinite Loop: Program becomes unresponsive if execution continues.
    //         \\Possible causes: Endless while loop without yield, deadlock in thread synchronization, or blocking I/O on main thread.
    //         \\Observed: Window stops updating, no response to input, or process requires force quit.
    //         \\
    //     , .{});
    // }

    // // 按钮5：其他异常（如内存泄漏）
    // if (game.ui_system.button(400, 20)) {
    //     game.window.setWindowShouldClose();
    //     std.debug.print(
    //         \\[ISSUE REPORT] Other Exception: Memory leak, crash, or undefined behavior.
    //         \\Possible causes: Unfreed allocated memory, use-after-free, double-free, or out-of-bounds access.
    //         \\Observed: Increasing memory usage over time, sudden crash, or inconsistent state.
    //         \\
    //     , .{});
    // }

    // // 按钮6：无异常退出
    // if (game.ui_system.button(500, 20)) {
    //     game.window.setWindowShouldClose();
    //     std.debug.print(
    //         \\[STATUS] Normal exit: No CDT-related issues observed.
    //         \\
    //     , .{});
    // }
}
const std = @import("std");
const UiSystem = @import("../ui_system.zig");
const Game = @import("../game.zig");
