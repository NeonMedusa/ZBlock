// camera3d.zig:
position: Vec3 = Vec3.zero(),
front: Vec3 = Vec3.forward(),
up: Vec3 = Vec3.up(),
world_up: Vec3 = Vec3.up(),
yaw: f32 = -90.0,
pitch: f32 = 0.0,
sensitivity: f32 = 0.1,
movement_speed: f32 = 5.0,
// 初始化
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
pub fn update(self: *@This(), game: *Game) void {
    const input = game.input;
    const window = game.window;
    //鼠标控制方向
    const mousePos = input.getCursorPos(); // 获取鼠标位置
    input.setCursorToCenter(); // 重置鼠标位置到窗口中心
    self.yaw += @as(f32, @floatCast(mousePos.x - window.center_x)) * self.sensitivity; // 更新相机角度
    self.pitch -= @as(f32, @floatCast(mousePos.y - window.center_y)) * self.sensitivity;
    if (self.pitch > 89.0) self.pitch = 89.0; // 限制俯仰角
    if (self.pitch < -89.0) self.pitch = -89.0;
    self.updateVectors(); // 更新相机方向向量
    // 键盘控制移动
    const velocity = self.movement_speed * window.delta_time;
    const right = self.front.cross(self.up).norm();
    if (input.isKeyPressed(.w)) self.position = self.position.add(self.front.scale(velocity));
    if (input.isKeyPressed(.s)) self.position = self.position.sub(self.front.scale(velocity));
    if (input.isKeyPressed(.a)) self.position = self.position.sub(right.scale(velocity));
    if (input.isKeyPressed(.d)) self.position = self.position.add(right.scale(velocity));
    if (input.isKeyPressed(.space)) self.position = self.position.add(self.up.scale(velocity));
    if (input.isKeyPressed(.left_control) or input.isKeyPressed(.right_control))
        self.position = self.position.sub(self.up.scale(velocity));
}
// 更新相机方向向量
fn updateVectors(self: *@This()) void {
    const yawRad = Algebra.toRadians(self.yaw);
    const pitchRad = Algebra.toRadians(self.pitch);
    self.front = Vec3.new(@cos(yawRad) * @cos(pitchRad), @sin(pitchRad), @sin(yawRad) * @cos(pitchRad)).norm();
    self.up = self.front.cross(self.world_up).norm().cross(self.front).norm();
}
// 获取视图矩阵
pub fn getViewMatrix(self: @This()) Mat4 {
    return Algebra.lookAt(self.position, self.position.add(self.front), self.up);
}
// 引用
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Glfw = @import("cimports.zig").Glfw;
const Game = @import("game.zig");
