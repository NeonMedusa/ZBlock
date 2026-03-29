// camera3d.zig:
position: Vec3 = Vec3.zero,
front: Vec3 = Vec3.forward,
up: Vec3 = Vec3.up,
world_up: Vec3 = Vec3.up,
yaw: f32 = -90.0,
pitch: f32 = 0.0,
sensitivity: f32 = 0.1,
movement_speed: f32 = 5.0,
game: *Game,
// 初始化
pub fn init(game: *Game) @This() {
    return .{
        .position = Vec3.zero,
        .front = Vec3.forward,
        .up = Vec3.up,
        .world_up = Vec3.up,
        .yaw = -90.0,
        .pitch = 0.0,
        .sensitivity = 0.1,
        .movement_speed = 5.0,
        .game = game,
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

    // 更新视图矩阵
    self.game.ubo.view_matrix = Mat4.lookAt(self.position, self.position.add(self.front), self.up);
}
// 更新相机方向向量
fn updateVectors(self: *@This()) void {
    const yawRad = Algebra.toRadians(self.yaw);
    const pitchRad = Algebra.toRadians(self.pitch);
    self.front = Vec3.new(@cos(yawRad) * @cos(pitchRad), @sin(pitchRad), @sin(yawRad) * @cos(pitchRad)).norm();
    self.up = self.front.cross(self.world_up).norm().cross(self.front).norm();
}

pub fn getScreenRay(self: *@This(), screen_x: f32, screen_y: f32) Raycast.Ray {
    const ndc_x = screen_x * 2.0 - 1.0;
    const ndc_y = (1.0 - screen_y) * 2.0 - 1.0;

    const inv_proj = self.game.ubo.proj_matrix.inverse();
    const inv_view = self.game.ubo.view_matrix.inverse();

    // 计算近平面点
    const clip_near = Vec4.new(ndc_x, ndc_y, -1.0, 1.0);
    var eye_near = inv_proj.mulVec(clip_near);
    eye_near = Vec4.new(eye_near.x / eye_near.w, eye_near.y / eye_near.w, eye_near.z / eye_near.w, 1.0);
    const world_near = inv_view.mulVec(eye_near);
    const near_point = Vec3.new(world_near.x, world_near.y, world_near.z);

    // 计算远平面点
    const clip_far = Vec4.new(ndc_x, ndc_y, 1.0, 1.0);
    var eye_far = inv_proj.mulVec(clip_far);
    eye_far = Vec4.new(eye_far.x / eye_far.w, eye_far.y / eye_far.w, eye_far.z / eye_far.w, 1.0);
    const world_far = inv_view.mulVec(eye_far);
    const far_point = Vec3.new(world_far.x, world_far.y, world_far.z);

    // 射线起点和方向
    const origin = near_point; // 使用近平面点作为起点更精确
    const direction = far_point.sub(origin).norm();

    return .{ .origin = origin, .direction = direction };
}

// 引用
const Imports = @import("imports.zig");
const Algebra = Imports.Algebra;
const Vec3 = Algebra.Vec3;
const Vec4 = Algebra.Vec4;
const Mat4 = Algebra.Mat4;
const Glfw = Imports.Glfw;
const Game = Imports.Game;
const Raycast = @import("raycast.zig");
