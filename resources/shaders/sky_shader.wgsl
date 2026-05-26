// sky_shader.wgsl
// 程序化天空穹顶：全球经纬球 mesh + 2D 噪声纹理云渲染。
// 太阳/月亮/星星/天空渐变/云全部在片元着色器里完成。

struct SkyUniform {
    inv_view_proj: mat4x4f,     // mesh顶点→裁剪空间（proj×view_rot）
    sun_direction: vec4f,       // 太阳朝向
    sun_color: vec4f,           // 太阳光颜色
    horizon_color: vec4f,       // 地平线颜色（黄昏/黎明色）
    zenith_color: vec4f,        // 天顶颜色（正午天空色）
    cloud_params1: vec4f,       // x=云量(越大云越多), y=密度, z=高度, w=风速
    cloud_params2: vec4f,       // x=风向_X, y=风向_Z, z=云图缩放, w=光照偏移距
    cloud_color0: vec4f,        // 云阴影色（暗）
    cloud_color1: vec4f,        // 云中间色（中）
    cloud_color2: vec4f,        // 云高光色（亮）
    time: f32,                  // 游戏时间（秒）
    sun_intensity: f32,         // 太阳光晕和亮盘强度
    moon_phase: f32,            // 月相（0~1）
    moon_brightness: f32,       // 月亮亮度
    star_density: f32,          // 星星密度（越小星越多）
    star_twinkle_speed: f32,    // 星星闪烁速度
    star_color_strength: f32,   // 星星色偏强度（0=全白）
    back_lit_strength: f32,     // 云背光亮度
    edge_lit_power: f32,        // 云边缘辉光幂次
    edge_lit_strength: f32,     // 云边缘辉光强度
    cloud_color_mtime: f32,     // 云三色调插值阈值
};

@group(0) @binding(0) var<uniform> sky: SkyUniform;
@group(0) @binding(1) var noise_tex: texture_2d<f32>;
@group(0) @binding(2) var noise_sampler: sampler;

struct SkyVertex {
    @location(0) position: vec3f,
    @location(1) uv: vec2f,
};

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) dir: vec3f,
};

@vertex
fn vs_main(in: SkyVertex) -> VertexOutput {
    var out: VertexOutput;
    out.position = sky.inv_view_proj * vec4f(in.position, 1.0);
    out.uv = in.uv;
    out.dir = in.position;
    return out;
}

// 3D 噪声哈希
fn hash3d(p: vec3f) -> f32 {
    let h = dot(p, vec3f(12.9898, 78.233, 45.5432));
    return fract(sin(h) * 43758.5453);
}

// 程序化星星
fn stars(dir: vec3f) -> vec3f {
    let ndir = normalize(dir);
    let cell = floor(ndir * 100.0);
    let in_cell = fract(ndir * 100.0);
    let r = hash3d(cell);
    if r > sky.star_density { return vec3f(0.0); }
    let pos_in_cell = vec3f(hash3d(cell + 0.1), hash3d(cell + 0.2), hash3d(cell + 0.3)) - 0.5;
    let dist = length(in_cell - pos_in_cell);
    let brightness = smoothstep(0.3, 0.0, dist);
    let twinkle = 0.5 + 0.5 * sin(sky.star_twinkle_speed * sky.time + hash3d(cell + 0.4) * 6.28);
    let tint_r = hash3d(cell + 0.5);
    let tint_g = hash3d(cell + 0.6);
    let tint_b = hash3d(cell + 0.7);
    let tint = vec3f(tint_r, tint_g, tint_b);
    let strength = sky.star_color_strength * (1.0 - abs(tint_r * 2.0 - 1.0));
    let color = mix(vec3f(1.0), tint, strength);
    return brightness * 1.2 * twinkle * color;
}

struct CloudResult {
    color: vec3f,
    bright: vec3f,
    density: f32,
};

fn dirToUv(d: vec3f) -> vec2f {
    return vec2f(atan2(d.z, d.x) / 6.2832 + 0.5,
                 acos(clamp(d.y, -1, 1)) / 3.1416);
}

// 渲染云层：全部偏移在 3D 方向空间计算，避免 UV 环绕接缝
fn renderClouds(uv: vec2f, sun_halo: f32, time: f32) -> CloudResult {
    let cloudy_rate = sky.cloud_params1.x;
    let wind_speed = sky.cloud_params1.w;
    let cloud_size = sky.cloud_params2.z;
    let offset_dist = sky.cloud_params2.w * 0.2;
    let sun_dir = normalize(sky.sun_direction.xyz);

    // UV → 3D 方向
    let theta = uv.x * 6.2832;
    let phi = uv.y * 3.1416;
    let base_dir = vec3f(sin(phi)*cos(theta), cos(phi), sin(phi)*sin(theta));

    // 风动：绕 Y 轴旋转（3D 空间，无接缝）
    let wind_angle = wind_speed * time * 0.01;
    let cos_w = cos(wind_angle);
    let sin_w = sin(wind_angle);
    let wind_dir = vec3f(
        base_dir.x * cos_w - base_dir.z * sin_w,
        base_dir.y,
        base_dir.x * sin_w + base_dir.z * cos_w,
    );

    // 两层不同频率：乘系数后归一化改变 UV 覆盖范围
    let dir1 = normalize(base_dir * (cloud_size * 2.0));
    let dir2 = normalize(wind_dir * (cloud_size + 0.1));

    // 三方向光照偏移（3D 空间）
    let dir_center = base_dir;
    let dir_front = normalize(base_dir + sun_dir * offset_dist);
    let dir_back = normalize(base_dir - sun_dir * offset_dist);

    let uv_center = dirToUv(dir_center);
    let uv_front = dirToUv(dir_front);
    let uv_back = dirToUv(dir_back);
    let uv1 = dirToUv(dir1);
    let uv2 = dirToUv(dir2);

    // 中心采样（两层）
    let center = textureSample(noise_tex, noise_sampler, uv_center);
    let c1 = textureSample(noise_tex, noise_sampler, uv1).r;
    let c2 = textureSample(noise_tex, noise_sampler, uv2).r;
    let center_density = saturate(c1 * c2 * cloudy_rate * 2.5);

    // front 采样（朝向太阳）
    let f1 = textureSample(noise_tex, noise_sampler, uv_front).r;
    let f2 = textureSample(noise_tex, noise_sampler, uv_front).r;
    let front_density = saturate(f1 * f2 * cloudy_rate * 2.5);

    // back 采样（背光）
    let b1 = textureSample(noise_tex, noise_sampler, uv_back).r;
    let b2 = textureSample(noise_tex, noise_sampler, uv_back).r;
    let back_density = saturate(b1 * b2 * cloudy_rate * 2.5);

    // 差分光照 + 边缘辉光
    let edge = saturate(front_density - back_density);
    let edge_glow = pow(1.0 - center_density, sky.edge_lit_power) * sky.edge_lit_strength;
    let cloudy_adj = saturate(cloudy_rate - 0.5) + 0.5;
    let halo_factor = sun_halo * (1.5 - cloudy_adj) + 0.6;
    let cloud_density = saturate(edge + edge_glow * halo_factor);

    // 三色调云颜色
    let cmt = sky.cloud_color_mtime;
    var cloud_color: vec3f;
    if (cloud_density >= cmt) {
        let t = (cloud_density - cmt) / (1.0 - cmt);
        cloud_color = mix(sky.cloud_color1.rgb, sky.cloud_color2.rgb, t);
    } else {
        let t = cloud_density / cmt;
        cloud_color = mix(sky.cloud_color0.rgb, sky.cloud_color1.rgb, t);
    }

    let bright_add = cloud_density * sun_halo * sky.cloud_color2.rgb * sky.back_lit_strength;

    return CloudResult(cloud_color, bright_add, cloud_density);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    let dir = normalize(in.dir);

    let day_factor = smoothstep(-0.15, 0.25, sky.sun_direction.y);
    let sky_gradient = mix(
        vec3f(0.02, 0.02, 0.08),
        mix(sky.horizon_color, sky.zenith_color, max(dir.y, 0.0)).rgb,
        day_factor,
    );

    // 太阳光晕（用于云层照明）
    let sun_dot = max(dot(dir, normalize(sky.sun_direction.xyz)), 0.0);
    let sun_halo_raw = pow(sun_dot, 16.0);
    let sun_halo = saturate(sun_halo_raw);

    // 云渲染
    let cloud_result = renderClouds(in.uv, sun_halo, sky.time);

    // 云层混合（按密度混合天空渐变，保留蓝天）
    let cloud_layer = mix(sky_gradient.rgb, cloud_result.color, saturate(cloud_result.density * 0.6)) + cloud_result.bright;

    // 夜间变暗
    let cloud = cloud_layer * mix(0.3, 1.0, day_factor);

    // 太阳
    let sun_glow = pow(sun_dot, 256.0) * sky.sun_intensity * 2.0;
    let sun_disk = pow(sun_dot, 2048.0) * sky.sun_intensity * 4.0;
    let sun = (sun_glow + sun_disk) * sky.sun_color.rgb;

    // 月亮
    let moon_dir = normalize(-sky.sun_direction.xyz);
    let moon_dot = max(dot(dir, moon_dir), 0.0);
    let moon_disk = step(0.998, moon_dot);
    let moon = moon_disk * sky.moon_brightness * 3.0 * vec3f(0.9, 0.92, 1.0);

    // 星星
    let star = stars(dir) * (1.0 - day_factor) * 2.0 * (1.0 - moon_disk);

    let final_color = cloud + sun + moon + star;
    return vec4f(final_color, 1.0);
}
