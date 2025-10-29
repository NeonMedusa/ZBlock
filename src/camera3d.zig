position: Vec3 = Vec3.zero(),
front: Vec3 = Vec3.forward(),
up: Vec3 = Vec3.up(),
world_up: Vec3 = Vec3.up(),
yaw: f32 = -90.0,
pitch: f32 = 0.0,
sensitivity: f32 = 0.1,
movement_speed: f32 = 5.0,

pub fn init() @This() {
    return .{
        .position = Vec3.zero(),
        .front = Vec3.forward(),
        .up = Vec3.up(),
        .world_up = Vec3.up(),
        .yaw = -90.0,
        .pitch = 0.0,
        .sensitivity = 0.1,
        .movement_speed = 5.0,
    };
}

pub fn updateFromMouse(self: *@This(), window: Window) void {
    // 获取鼠标位置
    const mousePos = window.getCursorPos();
    // 重置鼠标位置到窗口中心
    const centerX = window.widthF / 2.0;
    const centerY = window.heightF / 2.0;
    window.setCursorPos(centerX, centerY);
    // 更新相机角度
    self.yaw += @as(f32, @floatCast(mousePos.x - centerX)) * self.sensitivity;
    self.pitch -= @as(f32, @floatCast(mousePos.y - centerY)) * self.sensitivity;
    // 限制俯仰角
    if (self.pitch > 89.0) self.pitch = 89.0;
    if (self.pitch < -89.0) self.pitch = -89.0;
    // 更新相机方向向量
    self.updateVectors();
}

// 键盘控制移动
pub fn updateFromKeyboard(self: *@This(), window: Window, delta_time: f32) void {
    const velocity = self.movement_speed * delta_time;
    const input = window.input;
    const right = self.front.cross(self.up).norm();

    if (input.isKeyPressed(.w)) self.position = self.position.add(self.front.scale(velocity));
    if (input.isKeyPressed(.s)) self.position = self.position.sub(self.front.scale(velocity));
    if (input.isKeyPressed(.a)) self.position = self.position.sub(right.scale(velocity));
    if (input.isKeyPressed(.d)) self.position = self.position.add(right.scale(velocity));
    if (input.isKeyPressed(.space)) self.position = self.position.add(self.up.scale(velocity));
    if (input.isKeyPressed(.left_control) or input.isKeyPressed(.right_control)) {
        self.position = self.position.sub(self.up.scale(velocity));
    }
}

fn updateVectors(self: *@This()) void {
    const yawRad = algebra.toRadians(self.yaw);
    const pitchRad = algebra.toRadians(self.pitch);
    self.front = Vec3.new(@cos(yawRad) * @cos(pitchRad), @sin(pitchRad), @sin(yawRad) * @cos(pitchRad)).norm();
    self.up = self.front.cross(self.world_up).norm().cross(self.front).norm();
}

pub fn getViewMatrix(self: @This()) Mat4 {
    return algebra.lookAt(self.position, self.position.add(self.front), self.up);
}

const algebra = @import("zalgebra");
const Vec3 = algebra.Vec3;
const Mat4 = algebra.Mat4;
const Window = @import("window.zig");
const glfw = @import("cimports.zig").glfw;
