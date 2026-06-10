// render_shader.wgsl
// 主渲染管线：两个 vertex entry point (vs_static/vs_skinned) 共享同一个 fs_main 片段着色器。
// 所有模型/方块共用这一个 shader module，两条 pipeline 仅 vertex attribute layout 不同。

// --- 全局绑定 (group 0, 每帧更新) ---
@group(0) @binding(0) var<uniform> scene_uniform: SceneUniform;
@group(0) @binding(1) var<storage, read> entities_data: array<EntitiesData>;
@group(0) @binding(2) var<storage, read> ins_data: array<InstanceData>;
@group(0) @binding(3) var<storage, read> bone_matrices: array<mat4x4f>;

// --- 材质绑定 (group 1, 纹理) ---
@group(1) @binding(0) var<uniform> material_uniform: MaterialConstants;
@group(1) @binding(1) var color_texture: texture_2d<f32>;
@group(1) @binding(2) var normal_texture: texture_2d<f32>;

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

struct MaterialConstants {
    has_base_color: u32,
    has_normal: u32,
};

struct EntitiesData {
    transform: mat4x4f,
    bone_offset: i32,
    _padding: array<i32, 3>,
};

struct InstanceData {
    transform: mat4x4f,
    entity_idx: u32,
    bone_offset: i32,
    _padding: array<i32, 2>,
};

// --- 顶点格式 ---
// StaticVertex: chunk + 无骨骼模型，32 字节 (pos 12 + normal 12 + texcoord 8)
struct StaticVertex {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
    @location(2) texcoord: vec2f,
};

// SkinnedVertex: 蒙皮模型用，64 字节；
// 前三个字段与 StaticVertex 一致，static pipeline 读前 32 字节也能正确工作。
struct SkinnedVertex {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
    @location(2) texcoord: vec2f,
    @location(3) joint_indices: vec4u,
    @location(4) joint_weights: vec4f,
};

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) texcoord: vec2f,
    @location(1) world_normal: vec3f,
    @location(2) world_position: vec3f,
    @location(3) color: vec4f,
};

// ChunkVertex: 紧凑区块顶点，4 字节（1 × u32 packed_pos）
struct ChunkVertex {
    @location(0) packed_pos: u32,
};

// 从 ChunkVertex 解码法线（6 方向，索引同 Direction 枚举定义）
// Direction: up=0, down=1, north=2, south=3, west=4, east=5
fn decodeChunkNormal(face_dir: u32) -> vec3f {
    switch (face_dir) {
        case 0u: { return vec3f(0.0, 1.0, 0.0); }   // up
        case 1u: { return vec3f(0.0, -1.0, 0.0); }  // down
        case 2u: { return vec3f(0.0, 0.0, -1.0); }  // north
        case 3u: { return vec3f(0.0, 0.0, 1.0); }   // south
        case 4u: { return vec3f(-1.0, 0.0, 0.0); }  // west
        default: { return vec3f(1.0, 0.0, 0.0); }   // east
    }
}

// 从 face_dir + corner 计算 UV（不存纹理坐标，靠面方向和角索引推导）
// DEFAULT_UVS: (0,1),(1,1),(1,0),(0,0) — up/north/east/west
// down: (0,0),(1,0),(1,1),(0,1)
// south: (1,1),(0,1),(0,0),(1,0)
fn computeChunkUV(face_dir: u32, corner: u32) -> vec2f {
    // 公共分支：up(0), north(2), west(4), east(5) → DEFAULT_UVS
    switch (face_dir) {
        case 0u, 2u, 4u, 5u: {
            switch (corner) {
                case 0u: { return vec2f(0.0, 1.0); }
                case 1u: { return vec2f(1.0, 1.0); }
                case 2u: { return vec2f(1.0, 0.0); }
                default: { return vec2f(0.0, 0.0); }
            }
        }
        case 1u: { // down
            switch (corner) {
                case 0u: { return vec2f(0.0, 0.0); }
                case 1u: { return vec2f(1.0, 0.0); }
                case 2u: { return vec2f(1.0, 1.0); }
                default: { return vec2f(0.0, 1.0); }
            }
        }
        default: { // south=3u
            switch (corner) {
                case 0u: { return vec2f(1.0, 1.0); }
                case 1u: { return vec2f(0.0, 1.0); }
                case 2u: { return vec2f(0.0, 0.0); }
                default: { return vec2f(1.0, 0.0); }
            }
        }
    }
}

// --- 骨骼蒙皮 (CPU 计算变换矩阵后写入 storage buffer, GPU 按 bone_offset 索引) ---
fn skinPosition(input_position: vec3f, bone_offset: i32, joint_indices: vec4u, joint_weights: vec4f) -> vec3f {
    var skin_matrix: mat4x4f;
    for (var i = 0u; i < 4u; i++) {
        let w = joint_weights[i];
        if w > 0.0 {
            let mat = bone_matrices[bone_offset + i32(joint_indices[i])];
            if i == 0u { skin_matrix = mat * w; } else { skin_matrix = skin_matrix + mat * w; }
        }
    }
    return (skin_matrix * vec4f(input_position, 1.0)).xyz;
}

fn skinNormal(input_normal: vec3f, bone_offset: i32, joint_indices: vec4u, joint_weights: vec4f) -> vec3f {
    var skin_matrix: mat4x4f;
    for (var i = 0u; i < 4u; i++) {
        let w = joint_weights[i];
        if w > 0.0 {
            let mat = bone_matrices[bone_offset + i32(joint_indices[i])];
            if i == 0u { skin_matrix = mat * w; } else { skin_matrix = skin_matrix + mat * w; }
        }
    }
    return (skin_matrix * vec4f(input_normal, 0.0)).xyz;
}

// --- 阴影贴图 (group 2) ---
@group(2) @binding(0) var shadow_tex: texture_depth_2d;
@group(2) @binding(1) var shadow_sampler: sampler_comparison;

// --- 光照参数 ---
const AMBIENT_STRENGTH = 0.3;
const SPECULAR_STRENGTH = 0.5;
const SPECULAR_SHININESS = 32.0;

// 阴影采样：法线偏移 + 径向畸变
fn sampleShadow(world_pos: vec3f, normal: vec3f, light_dir: vec3f) -> f32 {
    let n = normalize(normal);
    let n_dot_l = abs(dot(n, light_dir));
    let cam_dist = length(world_pos - scene_uniform.camera_pos);
    let off_amt = min(0.03 + cam_dist * 0.005, 0.5) * (2.0 - n_dot_l); // 法线偏移：近处小远处大，正对光的面更小
    let biased = world_pos + n * off_amt;

    let p = scene_uniform.shadow_vp * vec4f(biased, 1.0);
    var ndc = p.xyz / p.w;
    let df = length(ndc.xy) + 0.1; // 与 shadow_shader.wgsl 一致的径向畸变
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

fn calculateLighting(normal: vec3f, position: vec3f, base_color: vec4f) -> vec4f {
    let n = normalize(normal);

    // 太阳光 场景坐标系的 X/Z 与天空盒相反，绕 Y 轴旋转 180° 补偿
    let sun_dir = normalize(vec3f(-scene_uniform.sun_direction.x, scene_uniform.sun_direction.y, -scene_uniform.sun_direction.z));
    let sun_col = scene_uniform.sun_color * scene_uniform.sun_intensity;

    // 月光（方向相反、偏蓝、更弱）
    let moon_dir = -sun_dir;
    let moon_col = scene_uniform.moon_color * scene_uniform.moon_brightness;

    // 昼夜因子（与天空盒一致）
    let day = smoothstep(-0.15, 0.25, scene_uniform.sun_direction.y);
    let night = 1.0 - day;

    // 环境光：白天用 ambient_ground，夜晚深空
    let ambient_color = scene_uniform.ambient_ground;
    let ambient = ambient_color * AMBIENT_STRENGTH * base_color.rgb;

    // 漫反射
    let sun_diffuse = day * max(dot(n, sun_dir), 0.0) * sun_col * base_color.rgb;
    let moon_diffuse = night * max(dot(n, moon_dir), 0.0) * moon_col * base_color.rgb;
    let diffuse = sun_diffuse + moon_diffuse;

    // 高光（仅太阳）
    let camera_pos = scene_uniform.camera_pos;
    let view_dir = normalize(camera_pos - position);
    let reflect_dir = reflect(-sun_dir, n);
    let specular = day * pow(max(dot(view_dir, reflect_dir), 0.0), SPECULAR_SHININESS) * SPECULAR_STRENGTH * sun_col;

    let shadow = sampleShadow(position, normal, sun_dir);
    let final_color = ambient + (diffuse + specular) * (0.3 + shadow * 0.7);
    return vec4f(final_color, base_color.a);
}

// --- vs_static: 静态物体 (方块/chunk, 无骨骼动画) ---
@vertex
fn vs_static(in: StaticVertex, @builtin(instance_index) ins_idx: u32) -> VertexOutput {
    let ins = ins_data[ins_idx];
    let entity = entities_data[ins.entity_idx];
    let model_matrix = entity.transform * ins.transform;
    let world_pos = model_matrix * vec4f(in.position, 1.0);
    let out_position = scene_uniform.proj_matrix * scene_uniform.view_matrix * world_pos;
    let world_normal = normalize((model_matrix * vec4f(in.normal, 0.0)).xyz);

    var out: VertexOutput;
    out.position = out_position;
    out.texcoord = in.texcoord;
    out.world_normal = world_normal;
    out.world_position = world_pos.xyz;
    out.color = vec4f(1.0, 1.0, 1.0, 1.0);
    return out;
}

// --- vs_skinned: 蒙皮模型 (带骨骼动画的实体) ---
@vertex
fn vs_skinned(in: SkinnedVertex, @builtin(instance_index) ins_idx: u32) -> VertexOutput {
    let ins = ins_data[ins_idx];
    let entity = entities_data[ins.entity_idx];
    let skinned_pos = skinPosition(in.position, ins.bone_offset, in.joint_indices, in.joint_weights);
    let skinned_normal = skinNormal(in.normal, ins.bone_offset, in.joint_indices, in.joint_weights);
    let model_matrix = entity.transform * ins.transform;
    let world_pos = model_matrix * vec4f(skinned_pos, 1.0);
    let out_position = scene_uniform.proj_matrix * scene_uniform.view_matrix * world_pos;
    let world_normal = normalize((model_matrix * vec4f(skinned_normal, 0.0)).xyz);

    var out: VertexOutput;
    out.position = out_position;
    out.texcoord = in.texcoord;
    out.world_normal = world_normal;
    out.world_position = world_pos.xyz;
    out.color = vec4f(1.0, 1.0, 1.0, 1.0);
    return out;
}

// --- vs_chunk: 紧凑区块顶点格式（1×u32，UV 从 corner+face_dir 推导） ---
@vertex
fn vs_chunk(in: ChunkVertex, @builtin(instance_index) ins_idx: u32) -> VertexOutput {
    let pp = in.packed_pos;
    let bx = f32(pp & 0x1Fu);
    let by = f32((pp >> 5u) & 0xFFu);
    let bz = f32((pp >> 13u) & 0x1Fu);
    let face_dir = (pp >> 18u) & 0x7u;
    let world_dir = (pp >> 21u) & 0x7u;
    let corner = (pp >> 24u) & 0x3u;
    let ins = ins_data[ins_idx];
    let world_pos = ins.transform * vec4f(bx, by, bz, 1.0);

    let out_position = scene_uniform.proj_matrix * scene_uniform.view_matrix * world_pos;
    let world_normal = decodeChunkNormal(world_dir);
    let texcoord = computeChunkUV(face_dir, corner);

    var out: VertexOutput;
    out.position = out_position;
    out.texcoord = texcoord;
    out.world_normal = world_normal;
    out.world_position = world_pos.xyz;
    out.color = vec4f(1.0, 1.0, 1.0, 1.0);
    return out;
}

// --- 片段着色器 (static/skinned 共用) ---
@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    var base_color: vec4f;
    if material_uniform.has_base_color != 0u {
        let texture_dims = textureDimensions(color_texture);
        let texel_coords = vec2i(
            i32(in.texcoord.x * f32(texture_dims.x)),
            i32(in.texcoord.y * f32(texture_dims.y))
        );
        base_color = textureLoad(color_texture, texel_coords, 0);
    } else {
        base_color = vec4f(1.0, 1.0, 1.0, 1.0);
    }
    let normal = normalize(in.world_normal);
    let lit_color = calculateLighting(normal, in.world_position, base_color);
    return pow(lit_color, vec4f(2.2));
}
