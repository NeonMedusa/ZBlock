//window.zig
const Window = @This();
handle: *Glfw.GLFWwindow,
width_u: u32,
height_u: u32,
width: f32,
height: f32,
center_x: f32,
center_y: f32,
time: f32 = 0,
prev_frame_time: f32 = 0,
delta_time: f32 = 0,
pub fn init(game_ptr: *Game, title: [:0]const u8, width: u32, height: u32) !@This() {
    // 如果Glfw初始化失败则返回错误并释放资源
    if (Glfw.glfwInit() == 0) return error.GLFWInitFailed;
    errdefer Glfw.glfwTerminate();
    // 创建窗口（设置NO_API模式以适配WGPU）
    Glfw.glfwWindowHint(Glfw.GLFW_CLIENT_API, Glfw.GLFW_NO_API);
    const glfw_window = Glfw.glfwCreateWindow(
        @intCast(width),
        @intCast(height),
        title,
        null,
        null,
    ) orelse return error.WindowCreateFailed;
    errdefer Glfw.glfwDestroyWindow(glfw_window);
    // 启用原生鼠标输入（如果支持）
    if (Glfw.glfwRawMouseMotionSupported() == Glfw.GLFW_TRUE)
        Glfw.glfwSetInputMode(glfw_window, Glfw.GLFW_RAW_MOUSE_MOTION, Glfw.GLFW_TRUE);
    // 将用户数据设置为Game的引用，在回调时解引用便可传递数据
    Glfw.glfwSetWindowUserPointer(glfw_window, game_ptr);
    // 设置回调
    _ = Glfw.glfwSetKeyCallback(glfw_window, keyCallback);
    _ = Glfw.glfwSetMouseButtonCallback(glfw_window, mouseButtonCallback);
    _ = Glfw.glfwSetCursorPosCallback(glfw_window, cursorPosCallback);
    _ = Glfw.glfwSetScrollCallback(glfw_window, scrollCallback);
    _ = Glfw.glfwSetWindowCloseCallback(glfw_window, windowCloseCallback);
    _ = Glfw.glfwSetWindowSizeCallback(glfw_window, windowSizeCallback);
    // 返回实例
    return .{
        .handle = glfw_window,
        .width_u = width,
        .height_u = height,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
        .center_x = @as(f32, @floatFromInt(@divTrunc(width, 2))),
        .center_y = @as(f32, @floatFromInt(@divTrunc(height, 2))),
    };
}

pub fn deinit(self: *@This()) void {
    // 销毁窗口
    Glfw.glfwDestroyWindow(self.handle);
    // 释放资源
    Glfw.glfwTerminate();
}

// 回调函数
fn keyCallback(glfw_window: ?*Glfw.GLFWwindow, key: i32, scancode: i32, action: i32, mods: i32) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            const game: *Game = @ptrCast(@alignCast(ptr));
            game.input.updateKeyState(key, action);
        }
    }
    _ = scancode;
    _ = mods;
}
fn mouseButtonCallback(glfw_window: ?*Glfw.GLFWwindow, button: i32, action: i32, mods: i32) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        // 解引用得到game的指针
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            const game: *Game = @ptrCast(@alignCast(ptr));
            // 更新game.input的鼠标状态
            game.input.updateMouseButtonState(button, action);
        }
    }
    _ = mods;
}
fn cursorPosCallback(glfw_window: ?*Glfw.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        // 解引用得到game的指针
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            const game: *Game = @ptrCast(@alignCast(ptr));
            // 更新game.input的鼠标状态
            game.input.updateMousePos(xpos, ypos);
        }
    }
}
fn scrollCallback(glfw_window: ?*Glfw.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        // 解引用得到game的指针
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            const game: *Game = @ptrCast(@alignCast(ptr));
            // 更新game.input的鼠标滚轮状态
            game.input.updateScroll(xoffset, yoffset);
        }
    }
}
fn windowSizeCallback(glfw_window: ?*Glfw.GLFWwindow, width: i32, height: i32) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        // 解引用得到game的指针
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            const game: *Game = @ptrCast(@alignCast(ptr));
            // 更新game.window的尺寸
            game.window.width_u = @intCast(width);
            game.window.height_u = @intCast(height);
            game.window.width = @floatFromInt(width);
            game.window.height = @floatFromInt(height);
            game.window.center_x = @as(f32, @floatFromInt(@divTrunc(width, 2)));
            game.window.center_y = @as(f32, @floatFromInt(@divTrunc(height, 2)));
            // 重建game.gctx的交换链
            game.gctx.resizeSwapChain(game.window.width_u, game.window.height_u);
            // 更新SceneUniform
            const aspect_ratio: f32 = game.window.width / game.window.height;
            // game.ubo.proj_matrix = Mat4.perspective(70, aspect_ratio, 0.001, 500);
            game.ubo.proj_matrix = Mat4.perspectiveReversedZ(
                70,
                aspect_ratio,
                0.1,
                500,
            );
            // 更新UiUniform
            game.ui_system.ubo.ortho_matrix = Mat4.orthographic(
                0,
                game.window.width,
                game.window.height,
                0,
                -1.0,
                1.0,
            );
        }
    }
}
fn windowCloseCallback(glfw_window: ?*Glfw.GLFWwindow) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        // 解引用得到game的指针
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            const game: *Game = @ptrCast(@alignCast(ptr));
            // 暂时不做任何事情
            _ = game;
        }
    }
}
// 常用函数
pub fn pollEvents(self: *@This()) void {
    Glfw.glfwPollEvents();
    // 更新时间
    self.time = @floatCast(Glfw.glfwGetTime());
    self.delta_time = self.time - self.prev_frame_time;
    self.prev_frame_time = self.time;
}
pub fn shouldClose(self: @This()) bool {
    return Glfw.glfwWindowShouldClose(self.handle) != 0;
}
pub fn setWindowShouldClose(self: @This()) void {
    Glfw.glfwSetWindowShouldClose(self.handle, 1);
}

const Glfw = @import("imports.zig").Glfw;
const Gctx = @import("gctx.zig");
const Algebra = @import("algebra.zig");
const Mat4 = Algebra.Mat4;
const Vec2_f64 = Algebra.Vec2_f64;
const Input = @import("input.zig");
const std = @import("std");
const Imports = @import("imports.zig");
const Game = Imports.Game;
