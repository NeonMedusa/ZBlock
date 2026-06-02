// sky_shader.wgsl
// 全屏三角 + cubemap 噪声纹理云渲染。太阳/月亮/星星/天空渐变/云全部在片元着色器里完成。

struct SkyUniform {
    inv_view_proj: mat4x4f,
    sun_direction: vec4f,
    sun_color: vec4f,
    horizon_color: vec4f,
    mid_color: vec4f,
    zenith_color: vec4f,
    cloud_params1: vec4f,   // x=云量, y=Y轴压缩, z=天空中间色高度, w=风速
    cloud_params2: vec4f,   // x=风向_X, y=风向_Z, z=云图缩放(越大云纹越细), w=光照偏移距
    cloud_color0: vec4f,        // 云阴影色（暗）
    cloud_color1: vec4f,        // 云中间色（中）
    cloud_color2: vec4f,        // 云高光色（亮）
    time: f32,
    sun_intensity: f32,
    moon_phase: f32,
    moon_brightness: f32,
    star_density: f32,
    star_twinkle_speed: f32,
    star_color_strength: f32,
    back_lit_strength: f32,
    edge_lit_power: f32,
    edge_lit_strength: f32,
    cloud_color_mtime: f32,
};

@group(0) @binding(0) var<uniform> sky: SkyUniform;
@group(0) @binding(1) var cube_tex: texture_cube<f32>;
@group(0) @binding(2) var cube_sampler: sampler;

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(1) dir: vec4f,
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput {
    let pos = array<vec2f, 3>(
        vec2f(-1.0, -1.0),
        vec2f(3.0, -1.0),
        vec2f(-1.0, 3.0),
    );
    let p = pos[idx];
    var out: VertexOutput;
    out.position = vec4f(p, 0.0, 1.0);
    out.dir = vec4f(p, -1.0, 1.0);
    return out;
}

fn hash3d(p: vec3f) -> f32 {
    let h = dot(p, vec3f(12.9898, 78.233, 45.5432));
    return fract(sin(h) * 43758.5453);
}

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

fn renderClouds(dir: vec3f, sun_halo: f32, time: f32) -> CloudResult {
    let cloudy_rate = sky.cloud_params1.x;
    let squish = sky.cloud_params1.y;
    let wind_speed = sky.cloud_params1.w;
    let cloud_size = sky.cloud_params2.z;
    let offset_dist = sky.cloud_params2.w * 0.2;
    let sun_dir = normalize(sky.sun_direction.xyz);

    // Y 轴压缩
    let flat_dir = normalize(vec3f(dir.x, dir.y * squish, dir.z));

    // 风动：绕 Y 轴旋转
    let wind_angle = wind_speed * time * 0.01;
    let cos_w = cos(wind_angle);
    let sin_w = sin(wind_angle);
    let wind_dir = vec3f(
        flat_dir.x * cos_w - flat_dir.z * sin_w,
        flat_dir.y,
        flat_dir.x * sin_w + flat_dir.z * cos_w,
    );

    // 两层不同频率
    let dir1 = normalize(flat_dir * (cloud_size * 2.0));
    let dir2 = normalize(wind_dir * (cloud_size + 0.1));

    // 三方向光照偏移
    let dir_front = normalize(flat_dir + sun_dir * offset_dist);
    let dir_back = normalize(flat_dir - sun_dir * offset_dist);

    // cubemap 采样
    let c1 = textureSample(cube_tex, cube_sampler, dir1).r;
    let c2 = textureSample(cube_tex, cube_sampler, dir2).r;
    let center_density = saturate(c1 * c2 * cloudy_rate * 2.5);

    let front_s = textureSample(cube_tex, cube_sampler, dir_front);
    let front_f1 = textureSample(cube_tex, cube_sampler, normalize(dir_front * (cloud_size * 2.0)));
    let front_density = saturate(front_f1.r * front_s.r * cloudy_rate * 2.5);

    let back_s = textureSample(cube_tex, cube_sampler, dir_back);
    let back_f1 = textureSample(cube_tex, cube_sampler, normalize(dir_back * (cloud_size * 2.0)));
    let back_density = saturate(back_f1.r * back_s.r * cloudy_rate * 2.5);

    let edge = saturate(front_density - back_density);
    let edge_glow = pow(1.0 - center_density, sky.edge_lit_power) * sky.edge_lit_strength;
    let cloudy_adj = saturate(cloudy_rate - 0.5) + 0.5;
    let halo_factor = sun_halo * (1.5 - cloudy_adj) + 0.6;
    let cloud_density = saturate(edge + edge_glow * halo_factor);

    // 三层偏移采样：阴影向背日侧、高光向日侧、常色在中间
    let off = offset_dist;
    let shadow_noise = textureSample(cube_tex, cube_sampler, normalize(flat_dir - sun_dir * off)).r;
    let mid_noise    = textureSample(cube_tex, cube_sampler, normalize(flat_dir + sun_dir * off * 0.3)).r;
    let highlight_noise = textureSample(cube_tex, cube_sampler, normalize(flat_dir + sun_dir * off * 1.5)).r;

    // 用三层偏移噪声取代单一的 cloud_density 做三色调混合
    var cloud_color = mix(sky.cloud_color0.rgb, sky.cloud_color1.rgb, mid_noise);
    cloud_color = mix(cloud_color, sky.cloud_color2.rgb, smoothstep(0.0, 0.5, highlight_noise));
    cloud_color = mix(cloud_color, sky.cloud_color0.rgb * 0.5, smoothstep(0.5, 0.0, shadow_noise));

    let bright_add = cloud_density * sun_halo * sky.cloud_color2.rgb * sky.back_lit_strength;
    return CloudResult(cloud_color, bright_add, cloud_density);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    // NDC → 世界方向
    let t = sky.inv_view_proj * in.dir;
    let d = t.xyz / t.w;
    let dir = normalize(vec3f(d.x, -d.y, d.z));

    let day_factor = smoothstep(-0.15, 0.25, sky.sun_direction.y);

    // 三色天空渐变（地平线→中间→天顶）
    let h = max(dir.y, 0.0);
    let mid_h = sky.cloud_params1.z;
    let lower = mix(sky.horizon_color.rgb, sky.mid_color.rgb, smoothstep(0.0, 1.0, h / mid_h));
    let upper = mix(sky.mid_color.rgb, sky.zenith_color.rgb, smoothstep(0.0, 1.0, (h - mid_h) / (1.0 - mid_h)));
    let blend_near = smoothstep(max(mid_h - 0.1, 0.0), min(mid_h + 0.1, 1.0), h);
    let day_sky = mix(lower, upper, blend_near);
    let sky_gradient = mix(vec3f(0.02, 0.02, 0.08), day_sky, day_factor);

    // 太阳光晕（用于云层照明）
    let sun_dot = max(dot(dir, normalize(sky.sun_direction.xyz)), 0.0);
    let sun_halo_raw = pow(sun_dot, 16.0);
    let sun_halo = saturate(sun_halo_raw);

    // 云渲染
    let cloud_result = renderClouds(dir, sun_halo, sky.time);
    let cloud_amount = saturate(cloud_result.density);
    let cloud_layer = mix(sky_gradient.rgb, cloud_result.color, cloud_amount) + cloud_result.bright;

    // 夜间变暗
    let cloud = cloud_layer * mix(0.3, 1.0, day_factor);

    // 太阳
    let sun_glow = pow(sun_dot, 512.0) * sky.sun_intensity * 2.0;
    let sun_disk = pow(sun_dot, 4096.0) * sky.sun_intensity * 4.0;
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
