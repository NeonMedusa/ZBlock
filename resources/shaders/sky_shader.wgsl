// sky_shader.wgsl
// 全屏三角 + GPU Simplex 噪声云渲染（Ashima Arts，纯 ALU）

struct SkyUniform {
    inv_view_proj: mat4x4f,
    sun_direction: vec4f,
    sun_color: vec4f,
    horizon_color: vec4f,
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

@group(0) @binding(0) var<uniform> sky: SkyUniform;

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

// ─── GPU 3D Simplex 噪声（Ashima Arts，纯 ALU） ───

fn mod2893(x: vec3f) -> vec3f { return x - floor(x * (1.0 / 289.0)) * 289.0; }

fn mod2894(x: vec4f) -> vec4f { return x - floor(x * (1.0 / 289.0)) * 289.0; }

fn permute(x: vec4f) -> vec4f { return mod2894(((x * 34.0) + 10.0) * x); }

fn taylorInvSqrt(r: vec4f) -> vec4f { return vec4f(1.79284291400159) - vec4f(0.85373472095314) * r; }

fn snoise3(v: vec3f) -> f32 {
    let C = vec2f(1.0 / 6.0, 1.0 / 3.0);
    let D = vec4f(0.0, 0.5, 1.0, 2.0);

    var i = floor(v + dot(v, vec3f(C.y)));
    var x0 = v - i + dot(i, vec3f(C.x));

    let g = step(x0.yzx, x0.xyz);
    let l = 1.0 - g;
    let i1 = min(g.xyz, l.zxy);
    let i2 = max(g.xyz, l.zxy);

    let x1 = x0 - i1 + vec3f(C.x);
    let x2 = x0 - i2 + vec3f(C.y);
    let x3 = x0 - vec3f(D.y);

    i = mod2893(i);
    let p = permute(permute(permute(
        i.z + vec4f(0.0, i1.z, i2.z, 1.0))
        + i.y + vec4f(0.0, i1.y, i2.y, 1.0))
        + i.x + vec4f(0.0, i1.x, i2.x, 1.0));

    let n_ = 0.142857142857;
    let ns = n_ * D.wyz - D.xzx;

    var j = p - 49.0 * floor(p * ns.z * ns.z);
    var x_ = floor(j * ns.z);
    var y_ = floor(j - 7.0 * x_);
    let x = x_ * ns.x + vec4f(ns.y);
    let y = y_ * ns.x + vec4f(ns.y);
    let h = 1.0 - abs(x) - abs(y);

    let b0 = vec4f(x.xy, y.xy);
    let b1 = vec4f(x.zw, y.zw);

    let s0 = floor(b0) * 2.0 + 1.0;
    let s1 = floor(b1) * 2.0 + 1.0;
    let sh = -step(h, vec4f(0.0));

    let a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    let a1 = b1.xzyw + s1.xzyw * sh.zzww;

    let p0 = vec3f(a0.xy, h.x);
    let p1 = vec3f(a0.zw, h.y);
    let p2 = vec3f(a1.xy, h.z);
    let p3 = vec3f(a1.zw, h.w);

    let norm = taylorInvSqrt(vec4f(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));
    let m = max(0.5 - vec4f(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), vec4f(0.0));
    let m2 = m * m;
    return 105.0 * dot(m2 * m2, vec4f(
        dot(p0 * norm.x, x0),
        dot(p1 * norm.y, x1),
        dot(p2 * norm.z, x2),
        dot(p3 * norm.w, x3),
    ));
}

fn fbm3(p: vec3f, octaves: u32) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var pos = p;
    for (var i = 0u; i < octaves; i++) {
        v += a * snoise3(pos);
        pos = pos * 2.0 + vec3f(1.7, 9.2, 4.3);
        a *= 0.5;
    }
    return v * 0.5 + 0.5;
}

// ─── 通用工具 ───

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

fn cloudNoise(p: vec3f) -> f32 {
    return fbm3(p, 4);
}

fn renderClouds(dir: vec3f, sun_halo: f32, time: f32) -> CloudResult {
    let cloudy_rate = sky.cloud_params1.x;
    let wind_speed = sky.cloud_params1.w;
    let cloud_size = sky.cloud_params2.z;
    let offset_dist = sky.cloud_params2.w * 0.2;
    let freq: f32 = 2.5;
    let sun_dir = normalize(sky.sun_direction.xyz);

    // 风动：绕 Y 轴旋转
    let wind_angle = wind_speed * time * 0.01;
    let cos_w = cos(wind_angle);
    let sin_w = sin(wind_angle);
    let wind_dir = vec3f(
        dir.x * cos_w - dir.z * sin_w,
        dir.y,
        dir.x * sin_w + dir.z * cos_w,
    );

    // 纯 shader 噪声（无纹理采样）
    let base = dir * freq;
    let center_val = cloudNoise(base);
    let c1 = cloudNoise(normalize(dir * (cloud_size * 2.0)) * freq);
    let c2 = cloudNoise(normalize(wind_dir * (cloud_size + 0.1)) * freq);
    let center_density = saturate(c1 * c2 * cloudy_rate * 2.5);

    let dir_front = normalize(dir + sun_dir * offset_dist);
    let dir_back = normalize(dir - sun_dir * offset_dist);

    let front_val = cloudNoise(dir_front * freq);
    let front_f1 = cloudNoise(normalize(dir_front * (cloud_size * 2.0)) * freq);
    let front_density = saturate(front_f1 * front_val * cloudy_rate * 2.5);

    let back_val = cloudNoise(dir_back * freq);
    let back_f1 = cloudNoise(normalize(dir_back * (cloud_size * 2.0)) * freq);
    let back_density = saturate(back_f1 * back_val * cloudy_rate * 2.5);

    let edge = saturate(front_density - back_density);
    let edge_glow = pow(1.0 - center_density, sky.edge_lit_power) * sky.edge_lit_strength;
    let cloudy_adj = saturate(cloudy_rate - 0.5) + 0.5;
    let halo_factor = sun_halo * (1.5 - cloudy_adj) + 0.6;
    let cloud_density = saturate(edge + edge_glow * halo_factor);

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
    let t = sky.inv_view_proj * in.dir;
    let d = t.xyz / t.w;
    let dir = normalize(vec3f(d.x, -d.y, d.z));

    let day_factor = smoothstep(-0.15, 0.25, sky.sun_direction.y);
    let sky_gradient = mix(
        vec3f(0.02, 0.02, 0.08),
        mix(sky.horizon_color, sky.zenith_color, max(dir.y, 0.0)).rgb,
        day_factor,
    );

    let sun_dot = max(dot(dir, normalize(sky.sun_direction.xyz)), 0.0);
    let sun_halo_raw = pow(sun_dot, 16.0);
    let sun_halo = saturate(sun_halo_raw);

    let cloud_result = renderClouds(dir, sun_halo, sky.time);
    let cloud_amount = saturate(cloud_result.density);
    let cloud_layer = mix(sky_gradient.rgb, cloud_result.color, cloud_amount) + cloud_result.bright;

    let cloud = cloud_layer * mix(0.3, 1.0, day_factor);

    let sun_glow = pow(sun_dot, 256.0) * sky.sun_intensity * 2.0;
    let sun_disk = pow(sun_dot, 2048.0) * sky.sun_intensity * 4.0;
    let sun = (sun_glow + sun_disk) * sky.sun_color.rgb;

    let moon_dir = normalize(-sky.sun_direction.xyz);
    let moon_dot = max(dot(dir, moon_dir), 0.0);
    let moon_disk = step(0.998, moon_dot);
    let moon = moon_disk * sky.moon_brightness * 3.0 * vec3f(0.9, 0.92, 1.0);

    let star = stars(dir) * (1.0 - day_factor) * 2.0 * (1.0 - moon_disk);

    let final_color = cloud + sun + moon + star;
    return vec4f(final_color, 1.0);
}
