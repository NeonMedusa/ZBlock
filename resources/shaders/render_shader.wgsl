// render_shader.wgsl
// 主渲染管线：两个 vertex entry point (vs_static/vs_skinned) 共享同一个 fs_main 片段着色器。
// 所有模型/方块共用这一个 shader module，两条 pipeline 仅 vertex attribute layout 不同。

// --- 全局绑定 (group 0, 每帧更新) ---
@group(0) @binding(0) var<uniform> scene_uniform : SceneUniform;
@group(0) @binding(1) var<storage, read> entities_data : array<EntitiesData>;
@group(0) @binding(2) var<storage, read> ins_data : array<InstanceData>;
@group(0) @binding(3) var<storage, read> bone_matrices : array<mat4x4f>;

// --- 材质绑定 (group 1, 纹理) ---
@group(1) @binding(0) var<uniform> material_uniform : MaterialConstants;
@group(1) @binding(1) var color_texture : texture_2d<f32>;
@group(1) @binding(2) var normal_texture : texture_2d<f32>;

struct SceneUniform {
    proj_matrix: mat4x4f,
    view_matrix: mat4x4f,
    camera_pos: vec4f,        // xyz = pos, w = time
    sun_direction: vec4f,     // xyz = dir, w = intensity
    sun_color: vec4f,         // xyz = color, w = moon_brightness
    horizon_color: vec4f,     // xyz = horizon, w = unused
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

// --- 骨骼蒙皮 (CPU 计算变换矩阵后写入 storage buffer, GPU 按 bone_offset 索引) ---
fn skinPosition(input_position: vec3f, bone_offset: i32, joint_indices: vec4u, joint_weights: vec4f) -> vec3f {
    var skin_matrix: mat4x4f;
    for (var i = 0u; i < 4u; i++) {
        let w = joint_weights[i];
        if (w > 0.0) {
            let mat = bone_matrices[bone_offset + i32(joint_indices[i])];
            if (i == 0u) { skin_matrix = mat * w; } else { skin_matrix = skin_matrix + mat * w; }
        }
    }
    return (skin_matrix * vec4f(input_position, 1.0)).xyz;
}

fn skinNormal(input_normal: vec3f, bone_offset: i32, joint_indices: vec4u, joint_weights: vec4f) -> vec3f {
    var skin_matrix: mat4x4f;
    for (var i = 0u; i < 4u; i++) {
        let w = joint_weights[i];
        if (w > 0.0) {
            let mat = bone_matrices[bone_offset + i32(joint_indices[i])];
            if (i == 0u) { skin_matrix = mat * w; } else { skin_matrix = skin_matrix + mat * w; }
        }
    }
    return (skin_matrix * vec4f(input_normal, 0.0)).xyz;
}

// --- 光照参数 ---
const AMBIENT_STRENGTH = 0.3;
const SPECULAR_STRENGTH = 0.5;
const SPECULAR_SHININESS = 32.0;

fn calculateLighting(normal: vec3f, position: vec3f, base_color: vec4f) -> vec4f {
    let n = normalize(normal);

    // 太阳光
    let sun_dir = normalize(scene_uniform.sun_direction.xyz);
    let sun_intensity = scene_uniform.sun_direction.w;
    let sun_col = scene_uniform.sun_color.xyz * sun_intensity;

    // 月光（方向相反、偏蓝、更弱）
    let moon_dir = -sun_dir;
    let moon_intensity = scene_uniform.sun_color.w;
    let moon_col = vec3f(0.5, 0.55, 0.8) * moon_intensity * 2.0;

    // 昼夜因子（与天空盒一致）
    let day = smoothstep(-0.15, 0.25, scene_uniform.sun_direction.y);
    let night = 1.0 - day;

    // 环境光：白天用地平线色，夜晚深空
    let ambient_color = mix(vec3f(0.02, 0.02, 0.08), scene_uniform.horizon_color.xyz, day);
    let ambient = ambient_color * AMBIENT_STRENGTH * base_color.rgb;

    // 漫反射
    let sun_diffuse = day * max(dot(n, sun_dir), 0.0) * sun_col * base_color.rgb;
    let moon_diffuse = night * max(dot(n, moon_dir), 0.0) * moon_col * base_color.rgb;
    let diffuse = sun_diffuse + moon_diffuse;

    // 高光（仅太阳）
    let camera_pos = scene_uniform.camera_pos.xyz;
    let view_dir = normalize(camera_pos - position);
    let reflect_dir = reflect(-sun_dir, n);
    let specular = day * pow(max(dot(view_dir, reflect_dir), 0.0), SPECULAR_SHININESS) * SPECULAR_STRENGTH * sun_col;

    let final_color = ambient + diffuse + specular;
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

// --- 片段着色器 (static/skinned 共用) ---
@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    var base_color: vec4f;
    if (material_uniform.has_base_color != 0u) {
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
