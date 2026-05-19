// sky_shader.wgsl
// 程序化天空穹顶：用 @builtin(vertex_index) 生成的一个大三角形覆盖屏幕，
// 无需 vertex/index buffer。逐像素从 NDC 还原世界方向，绘制天空。
// 太阳/月亮/星星/天空渐变全部在片元着色器里完成。

struct SkyUniform {
    // 不含平移的视角旋转 × 投影逆矩阵，映射 NDC → 世界方向，数值稳定
    inv_view_proj: mat4x4f,
    sun_direction: vec4f,
    sun_color: vec4f,
    horizon_color: vec4f,
    zenith_color: vec4f,
    sun_intensity: f32,        // 可调：太阳光晕和亮盘的强度乘数
    moon_phase: f32,           // 未来可从季节系统获取
    moon_brightness: f32,      // 可调：月亮亮度乘数
    star_density: f32,         // 可调：星星密度（格内有星的几率）
    star_twinkle_speed: f32,   // 可调：星星闪烁速度
    star_color_strength: f32,  // 可调：0=全白, >0 部分星带随机色偏；未来可从季节/日期系统获取
    time: f32,
};

@group(0) @binding(0) var<uniform> sky: SkyUniform;

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
};

// 覆盖整个 NDC 的大三角形（3 个顶点盖满屏幕，无需 index buffer）
@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VertexOutput {
    let pos = array<vec2f, 3>(
        vec2f(-1.0, -1.0),
        vec2f( 3.0, -1.0),
        vec2f(-1.0,  3.0),
    );
    var out: VertexOutput;
    out.position = vec4f(pos[vi], 1.0, 1.0);
    out.uv = pos[vi] * 0.5 + 0.5;
    return out;
}

// 3D 噪声哈希，用于程序化星星的分布
fn hash3d(p: vec3f) -> f32 {
    let h = dot(p, vec3f(12.9898, 78.233, 45.5432));
    return fract(sin(h) * 43758.5453);
}

// 程序化星星：用 ndir × 100 的 3D 整数格 + hash3d 判定有无星星，
// 每个星星是格内一个随机位置的圆盘。返回亮度 × 颜色（全白或带淡色偏）。
// 可调参数：
//   ndir × 100   → 增大则星星更密更小，减小则更疏更大
//   smoothstep(0.3, 0.0, dist) 的 0.3 为星星半径
//   1.2 为最大亮度
fn stars(dir: vec3f) -> vec3f {
    if dir.y < 0.05 { return vec3f(0.0); }
    let ndir = normalize(dir);
    let cell = floor(ndir * 100.0);
    let in_cell = fract(ndir * 100.0);
    let r = hash3d(cell);
    if r > sky.star_density { return vec3f(0.0); }
    let pos_in_cell = vec3f(hash3d(cell + 0.1), hash3d(cell + 0.2), hash3d(cell + 0.3)) - 0.5;
    let dist = length(in_cell - pos_in_cell);
    // 可调：星星大小（0.3 为最大半径，越大星星越粗）
    let brightness = smoothstep(0.3, 0.0, dist);

    // 闪烁
    let twinkle = 0.5 + 0.5 * sin(sky.star_twinkle_speed * sky.time + hash3d(cell + 0.4) * 6.28);

    // 颜色：star_color_strength=0 时全白；>0 时部分星带随机色偏
    let tint_r = hash3d(cell + 0.5);
    let tint_g = hash3d(cell + 0.6);
    let tint_b = hash3d(cell + 0.7);
    let tint = vec3f(tint_r, tint_g, tint_b);
    let strength = sky.star_color_strength * (1.0 - abs(tint_r * 2.0 - 1.0)); // 多数白、少数偏
    let color = mix(vec3f(1.0), tint, strength);

    return brightness * 1.2 * twinkle * color;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    // NDC → 世界方向
    let ndc = vec4f(in.uv * 2.0 - 1.0, 1.0, 1.0);
    let world = sky.inv_view_proj * ndc;
    let dir = normalize(world.xyz / world.w);

    // 昼夜混合因子：太阳高度低于 -0.15 为夜、高于 0.25 为昼，中间为黄昏/黎明
    let day_factor = smoothstep(-0.15, 0.25, sky.sun_direction.y);
    let sky_gradient = mix(
        vec3f(0.02, 0.02, 0.08),  // 深空夜，可调
        mix(sky.horizon_color, sky.zenith_color, max(dir.y, 0.0)).rgb,
        day_factor,
    );

    // 太阳：两层（外层光晕 + 内层亮盘）
    // 可调：pow( ,64) 和 pow( ,512) 分别控制光晕和亮盘大小，指数越大盘越小
    let sun_dot = max(dot(dir, normalize(sky.sun_direction.xyz)), 0.0);
    let sun_glow = pow(sun_dot, 64.0) * sky.sun_intensity * 2.0;
    let sun_disk = pow(sun_dot, 512.0) * sky.sun_intensity * 4.0;
    let sun = (sun_glow + sun_disk) * sky.sun_color.rgb;

    // 月亮：硬切圆盘（位于太阳的正对面）
    // 可调：step(0.995, ) 的 0.995 为月亮半径，越小月亮越大
    let moon_dir = normalize(-sky.sun_direction.xyz);
    let moon_dot = max(dot(dir, moon_dir), 0.0);
    let moon_disk = step(0.995, moon_dot);
    let moon = moon_disk * sky.moon_brightness * 3.0 * vec3f(0.9, 0.92, 1.0);

    // 星星：夜间亮度翻倍
    let star = stars(dir) * (1.0 - day_factor) * 2.0;

    let final_color = sky_gradient.rgb + sun + moon + star;
    return vec4f(final_color, 1.0);
}
