// water_shader.wgsl — 水面着色器
// WebGPU NDC (Y-flip) + Reversed-Z
// 波浪：旋转UV + 3层噪声 + 有限差分
// 反射：Fresnel + 天空渐变 + SSR（步进+二分搜索）
// 折射：线性深度吸收

@group(0) @binding(0) var<uniform> scene_uniform: SceneUniform;
@group(1) @binding(0) var shadow_tex: texture_depth_2d;
@group(1) @binding(1) var shadow_sampler: sampler_comparison;
@group(2) @binding(0) var ssr_color: texture_2d<f32>;
@group(2) @binding(1) var ssr_sampler: sampler;
@group(2) @binding(2) var depth_tex: texture_depth_2d;
@group(2) @binding(3) var noise_tex: texture_2d<f32>;
@group(2) @binding(4) var noise_sampler: sampler;

// 天空 Uniform（与 sky_shader.wgsl 共用同一个 bind group）
@group(3) @binding(0) var<uniform> sky_data: SkyUniform;
@group(3) @binding(1) var cube_tex: texture_cube<f32>;
@group(3) @binding(2) var cube_sampler: sampler;
@group(3) @binding(3) var moon_tex: texture_2d<f32>;
@group(3) @binding(4) var moon_sampler: sampler;

struct SceneUniform {
    proj_matrix: mat4x4f,
    view_matrix: mat4x4f,
    camera_pos: vec3f,
    time: f32,
    sun_direction: vec3f,
    sun_intensity: f32,
    sun_color: vec3f,
    moon_brightness: f32,
    ambient_ground: vec3f,
    _pad: f32,
    shadow_vp: mat4x4f,
    moon_color: vec3f,
};

struct SkyUniform {
    inv_view_proj: mat4x4f,
    sun_direction: vec4f,
    sun_color: vec4f,
    horizon_color: vec4f,
    mid_color: vec4f,
    zenith_color: vec4f,
    cloud_params1: vec4f,
    cloud_params2: vec4f,
    cloud_color0: vec4f,
    cloud_color1: vec4f,
    cloud_color2: vec4f,
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

struct VertexInput {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
    @location(2) texcoord: vec2f,
    @location(3) color: vec4f,
};

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) world_position: vec3f,
    @location(1) normal: vec3f,
};

const PI: f32 = 3.14159265;
const WATER_COLOR: vec3f = vec3f(0.04, 0.08, 0.10);
const WATER_ABSORPTION: f32 = 0.10;
const WAVE_AMPLITUDE: f32 = 0.65;
const REFLEX_INDEX: f32 = 0.45;

@vertex
fn vs_water(in: VertexInput) -> VertexOutput {
    var world_pos = in.position;
    let wave = vertex_wave(world_pos);
    let waved_pos = vec3f(world_pos.x, world_pos.y + wave, world_pos.z);
    var out: VertexOutput;
    out.position = scene_uniform.proj_matrix * scene_uniform.view_matrix * vec4f(waved_pos, 1.0);
    out.world_position = waved_pos;
    out.normal = in.normal;
    return out;
}

@fragment
fn fs_water(in: VertexOutput) -> @location(0) vec4f {
    let world_pos = in.world_position;
    let flat_normal = normalize(in.normal);
    let view_pos = (scene_uniform.view_matrix * vec4f(world_pos, 1.0)).xyz;

    // 公共量
    let sun_dir_ws = vec3f(-scene_uniform.sun_direction.x, scene_uniform.sun_direction.y, -scene_uniform.sun_direction.z);
    let day = smoothstep(-0.15, 0.25, scene_uniform.sun_direction.y);

    // 波浪法线（旋转UV + 噪声 → 有限差分 → TBN 转视空间）──
    let bump = wave_bump(vec2f(world_pos.x, world_pos.z) - world_pos.y);
    let view_tangent = scene_uniform.view_matrix[0].xyz;
    let view_binormal = scene_uniform.view_matrix[2].xyz;
    let up_vs = scene_uniform.view_matrix[1].xyz;
    let surface_normal_vs = normalize(bump.x * view_tangent + bump.y * view_binormal + bump.z * up_vs);

    // 折射 + 光照
    let n_dot_light = max(dot(flat_normal, sun_dir_ws), 0.0);
    let shadow = sample_shadow(world_pos, flat_normal, sun_dir_ws);
    let lit_water = WATER_COLOR * (scene_uniform.ambient_ground * 0.15 + day * n_dot_light * scene_uniform.sun_color * scene_uniform.sun_intensity * (0.3 + shadow * 0.7));
    let refracted = water_refraction(view_pos, in.position.z, bump.xy * 0.3, in.position.xy);

    // 反射方向 + 天空颜色
    let refl_vs = normalize(reflect(view_pos, surface_normal_vs));
    let elevation = clamp(dot(refl_vs, up_vs), 0.0001, 1.0);
    let sky_reflect = mix(sky_data.horizon_color.rgb, sky_data.zenith_color.rgb, sqrt(elevation));

    // SSR（步进 + 二分搜索）
    let dither = fract(sin(dot(in.position.xy, vec2f(12.9898, 78.233))) * 43758.5453);
    let wave_uv = vec2f(
        sin(world_pos.x * 0.04 + world_pos.z * 0.03 + scene_uniform.time * 0.6) * 0.006,
        cos(world_pos.x * 0.03 - world_pos.z * 0.04 + scene_uniform.time * 0.5) * 0.006);
    let ssr = reflection_calc(refl_vs, view_pos, dither, wave_uv);

    // 竖直水面跳过 SSR（SSR 无法处理透明竖面，回退到天空反射）
    let is_vert = abs(dot(normalize((scene_uniform.view_matrix * vec4f(flat_normal, 0.0)).xyz), up_vs)) < 0.3;
    let ssr_fade = select(ssr.fade, 0.0, is_vert);

    // 统一反射层（天空+SSR 平滑过渡）
    let scene_reflect = mix(sky_reflect, ssr.color, ssr_fade);

    // Fresnel（垂直看透明，斜看反射）
    let n_dot_view = max(dot(surface_normal_vs, normalize(-view_pos)), 0.0);
    let fresnel = 0.02 + 0.98 * pow(1.0 - n_dot_view, 5.0);

    // 最终混合 Fresnel 混合折射+反射层
    let shadow_darken = mix(0.75, 1.0, shadow);
    let color = mix(refracted, lit_water + scene_reflect, fresnel * REFLEX_INDEX) * shadow_darken;

    // 日月高光
    let night = 1.0 - day;
    let sun_vs = normalize((scene_uniform.view_matrix * vec4f(sun_dir_ws, 0.0)).xyz);
    let sun_astro = max(dot(refl_vs, sun_vs), 0.0);
    let moon_vs = normalize((scene_uniform.view_matrix * vec4f(-sun_dir_ws, 0.0)).xyz);
    let moon_astro = max(dot(refl_vs, moon_vs), 0.0);
    let glare = (smoothstep(0.995, 1.0, sun_astro) * day * 1.5 * scene_uniform.sun_color * scene_uniform.sun_intensity
               + smoothstep(0.995, 1.0, moon_astro) * night * 0.6 * scene_uniform.moon_color * scene_uniform.moon_brightness)
               * shadow;

    let final_color = color + glare;
    return vec4f(final_color, 1.0);
}

// 顶点扰动波浪
fn vertex_wave(pos: vec3f) -> f32 {
    let t = scene_uniform.time;
    let wave1 = 0.05 * sin(2.0 * PI * (t * 0.8 + pos.x / 2.5 + pos.z / 5.0));
    let wave2 = 0.05 * sin(2.0 * PI * (t * 0.6 + pos.x / 6.0 + pos.z / 12.0));
    let fy = fract(pos.y + 0.001);
    return clamp(wave1 + wave2, -fy, 1.0 - fy) * WAVE_AMPLITUDE;
}

// PCF 阴影采样（与 render_shader.wgsl 统一）
fn sample_shadow(world_pos: vec3f, normal: vec3f, light_dir: vec3f) -> f32 {
    let n = normalize(normal);
    let n_dot_l = abs(dot(n, light_dir));
    let cam_dist = length(world_pos - scene_uniform.camera_pos);
    let off_amt = (0.06 + cam_dist * 0.01) * (2.0 - n_dot_l);
    let biased = world_pos + n * off_amt;

    let p = scene_uniform.shadow_vp * vec4f(biased, 1.0);
    var ndc = p.xyz / p.w;
    let df = length(ndc.xy) + 0.1; // 径向畸变：中心密、边缘疏
    ndc.x /= df;
    ndc.y /= df;
    let uv = vec2f(ndc.x * 0.5 + 0.5, ndc.y * -0.5 + 0.5); // Y 翻转补偿 framebuffer 坐标系
    let ref_depth = ndc.z;

    // 超出光源视锥体 → 返回 1.0（无阴影）
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ref_depth < 0.0 || ref_depth > 1.0) {
        return 1.0;
    }

    return textureSampleCompare(shadow_tex, shadow_sampler, uv, ref_depth);
}

// 视空间 → 屏幕 UV + 深度
// 用于 SSR 步进：给定视空间位置，返回 (screen_u, screen_v, normalized_depth)
// 投影 → 透视除 → NDC [-1,1] → UV [0,1]（Y-flip 适配 WebGPU）
// Reversed-Z：ndc.z 已在 [0,1] 范围，直接返回
fn view_to_screen_uv(view_pos: vec3f) -> vec3f {
    let clip = scene_uniform.proj_matrix * vec4f(view_pos, 1.0);
    let ndc = clip.xyz / clip.w;
    return vec3f(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5, ndc.z);
}

// 采样 3 层不同尺度的噪声并合成为一个波高值
// 第 0 层：大尺度起伏（1-noise*10，负向贡献，制造宽阔谷底）
// 第 1 层：中尺度波纹（noise*7，正向贡献，叠加中等频率）
// 第 2 层：小尺度细节（sqrt(noise*6.5)*1.33，锐化波峰细节）
// 3 层 UV 已在调用前分别经过旋转/平移/拉伸，互不相同
fn wave_height_at(layer0: vec2f, layer1: vec2f, layer2: vec2f) -> f32 {
    return (1.0 - textureSample(noise_tex, noise_sampler, layer0 * 0.005).r * 10.0)
         + textureSample(noise_tex, noise_sampler, layer1 * 0.010416).r * 7.0
         + sqrt(textureSample(noise_tex, noise_sampler, layer2 * 0.045).r * 6.5) * 1.33;
}

// 波浪：旋转UV + 3层噪声 + 有限差分法线
fn wave_bump(coord: vec2f) -> vec3f {
    let t = scene_uniform.time;
    let mov = vec2f(0.0, -t * 0.31365);
    var c = coord * 0.262144;
    // 两层旋转 + 一层平移，Y 拉伸 2.5x 产生方向性波浪
    let ca = cos(1.2); let sa = sin(1.2);
    var c0 = vec2f(c.x*ca - c.y*sa, c.x*sa + c.y*ca) - mov * 3.5; c0.y *= 2.5;
    let cb = cos(0.35); let sb = sin(0.35);
    var c1 = vec2f(c.x*cb - c.y*sb, c.x*sb + c.y*cb) - mov * 1.8; c1.y *= 2.5;
    var c2 = c + mov * 0.6; c2.y *= 2.5;
    let eps = 0.25;
    let h0 = wave_height_at(c0, c1, c2);
    let h1 = wave_height_at(c0 + vec2f(eps,0), c1 + vec2f(eps,0), c2 + vec2f(eps,0));
    let h2 = wave_height_at(c0 + vec2f(0,eps), c1 + vec2f(0,eps), c2 + vec2f(0,eps));
    return vec3f((h1 - h0) * 0.02, (h2 - h0) * 0.02, 2.0);
}

// SSR 步进：指数步长 + 触及表面时二分搜索
fn ssr_march(dir: vec3f, origin: vec3f, dither: f32) -> vec2f {
    for (var i = 0; i < 10; i++) {
        let t = exp2(f32(i) + dither) - 1.0;
        let vp = origin + dir * t;
        let pos = view_to_screen_uv(vp);
        if (pos.x < 0.0 || pos.y < 0.0 || pos.x > 1.0 || pos.y > 1.0 ||
            pos.z < 0.0 || pos.z > 1.0) {
            return pos.xy;
        }
        let tex_dim = vec2f(textureDimensions(depth_tex));
        let depth = textureLoad(depth_tex, vec2i(pos.xy * tex_dim), 0);
        if (depth > pos.z) {
            var lo = origin + dir * (exp2(f32(i - 1) + dither) - 1.0);
            var hi = vp;
            for (var j = 0; j < 5; j++) {
                let mid = (lo + hi) * 0.5;
                let mp = view_to_screen_uv(mid);
                let md = textureLoad(depth_tex, vec2i(mp.xy * tex_dim), 0);
                if (md > mp.z) { hi = mid; } else { lo = mid; }
            }
            return view_to_screen_uv((lo + hi) * 0.5).xy;
        }
    }
    return vec2f(-1.0);
}

struct SSRResult { color: vec3f, fade: f32, };

fn reflection_calc(dir: vec3f, origin: vec3f, dither: f32, uv_offset: vec2f) -> SSRResult {
    let pos = ssr_march(dir, origin, dither);
    if (pos.x < 0.0) { return SSRResult(vec3f(0.0), 0.0); }
    let uv = pos.xy + uv_offset;
    // 抑制假阳性：SSR UV 离起点太近（<0.005≈5像素）→水面下方→丢弃
    let suppress = select(1.0, 0.0, distance(uv, view_to_screen_uv(origin).xy) < 0.005);
    // 屏幕边缘淡出，乘数10≈10%屏幕宽度的平滑过渡
    var fade_x = clamp((1.0 - abs(uv.x - 0.5) * 2.0) * 10.0, 0.0, 1.0);
    var fade_y = clamp((1.0 - abs(uv.y - 0.5) * 2.0) * 10.0, 0.0, 1.0);
    var fade = min(fade_x, fade_y);
    fade = clamp(fade - pow(uv.y, 10.0), 0.0, 1.0) * suppress;
    // X 轴镜像：SSR 出界时镜像采样，避免边缘拉伸
    var sample_uv = uv;
    sample_uv.x = abs(sample_uv.x);
    if (sample_uv.x > 1.0) { sample_uv.x = 1.0 - (sample_uv.x - 1.0); }
    let reflect_color = textureSample(ssr_color, ssr_sampler, clamp(sample_uv, vec2f(0.001), vec2f(0.999))).rgb;
    return SSRResult(reflect_color, fade);
}

// 折射 + 线性深度吸收（近→透明，远→深色）
fn water_refraction(view_pos: vec3f, water_ndc: f32, wave_xy: vec2f, screen_pos: vec2f) -> vec3f {
    let tex_size = vec2f(textureDimensions(ssr_color));
    var uv = screen_pos / tex_size;
    uv += wave_xy * (0.02 / (1.0 + length(view_pos) * 0.4));
    let underwater = textureSample(ssr_color, ssr_sampler, clamp(uv, vec2f(0.001), vec2f(0.999))).rgb;
    // 从投影矩阵提取 near，线性化深度
    let proj_b = scene_uniform.proj_matrix[3][2]; // m[3][2] = near（无限远）或 far*near/(far-near)（有限）
    let scene_depth = textureLoad(depth_tex, vec2i(clamp(uv * tex_size, vec2f(0.0), tex_size - 1.0)), 0);
    // 无限远反 Z：ndc.z = near / (-view_z) → linear_z = -near / ndc.z
    // 有限反 Z 在 near<<far 时同样适用。scene_depth=0（天空）时用极小值防止除零。
    let water_depth = abs(proj_b / max(water_ndc, 1e-10) - proj_b / max(scene_depth, 1e-10));
    let absorption = (1.0 / -((water_depth * water_depth * WATER_ABSORPTION) + 1.125)) + 1.0;
    return mix(underwater, WATER_COLOR, clamp(absorption, 0.0, 1.0));
}