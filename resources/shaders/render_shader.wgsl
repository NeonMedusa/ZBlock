// render_shader.wgsl
// group0全局绑定，这些都是每帧更新的
@group(0) @binding(0) var<uniform> scene_uniform : SceneUniform;
@group(0) @binding(1) var<storage, read> entities_data : array<EntitiesData>;
@group(0) @binding(2) var<storage, read> ins_data : array<InstanceData>;
@group(0) @binding(3) var<storage, read> bone_matrices : array<mat4x4f>;

// group1纹理绑定
@group(1) @binding(0) var<uniform> material_uniform : MaterialConstants;
@group(1) @binding(1) var color_texture : texture_2d<f32>;
@group(1) @binding(2) var normal_texture : texture_2d<f32>;

struct SceneUniform {
    proj_matrix: mat4x4f,
    view_matrix: mat4x4f,
    camera_position: vec3f,
    time: f32,
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

struct VertexInput {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
    @location(2) tangent: vec4f,
    @location(3) texcoord: vec2f,
    @location(4) color: vec4f,
    @location(5) joint_indices: vec4u,
    @location(6) joint_weights: vec4f,
};

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) texcoord: vec2f,
    @location(1) world_normal: vec3f,
    @location(2) world_position: vec3f,
    @location(3) color: vec4f,
};

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

const LIGHT_DIRECTION = vec3f(1.0, 2.0, 1.0);
const LIGHT_COLOR = vec3f(1.0, 1.0, 0.95);
const AMBIENT_STRENGTH = 0.3;
const SPECULAR_STRENGTH = 0.5;
const SPECULAR_SHININESS = 32.0;

fn calculateLighting(normal: vec3f, position: vec3f, camera_pos: vec3f, base_color: vec4f) -> vec4f {
    let n = normalize(normal);
    let light_dir = normalize(LIGHT_DIRECTION);
    let ambient = AMBIENT_STRENGTH * base_color.rgb;
    let diffuse_factor = max(dot(n, light_dir), 0.0);
    let diffuse = diffuse_factor * LIGHT_COLOR * base_color.rgb;
    let view_dir = normalize(camera_pos - position);
    let reflect_dir = reflect(-light_dir, n);
    let specular_factor = pow(max(dot(view_dir, reflect_dir), 0.0), SPECULAR_SHININESS);
    let specular = specular_factor * SPECULAR_STRENGTH * LIGHT_COLOR;
    let final_color = ambient + diffuse + specular;
    return vec4f(final_color, base_color.a);
}

@vertex
fn vs_main(in: VertexInput, @builtin(instance_index) ins_idx: u32) -> VertexOutput {
    let ins = ins_data[ins_idx];
    let entity = entities_data[ins.entity_idx];
    let is_skinned = ins.bone_offset >= 0;
    var skinned_pos = in.position;
    var skinned_normal = in.normal;
    if (is_skinned) {
        skinned_pos = skinPosition(in.position, ins.bone_offset, in.joint_indices, in.joint_weights);
        skinned_normal = skinNormal(in.normal, ins.bone_offset, in.joint_indices, in.joint_weights);
    }

    let model_matrix = entity.transform * ins.transform;
    let world_pos = model_matrix * vec4f(skinned_pos, 1.0);
    let out_position = scene_uniform.proj_matrix * scene_uniform.view_matrix * world_pos;
    let world_normal = normalize((model_matrix * vec4f(skinned_normal, 0.0)).xyz);

    var out: VertexOutput;
    out.position = out_position;
    out.texcoord = in.texcoord;
    out.world_normal = world_normal;
    out.world_position = world_pos.xyz;
    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    // 获取基础颜色
    var base_color: vec4f;
    
    if (material_uniform.has_base_color != 0u) {
        // 从纹理采样基础颜色
        let texture_dims = textureDimensions(color_texture);
        let texel_coords = vec2i(
            i32(in.texcoord.x * f32(texture_dims.x)),
            i32(in.texcoord.y * f32(texture_dims.y))
        );
        base_color = textureLoad(color_texture, texel_coords, 0);
    } else {
        // 使用顶点颜色
        base_color = in.color;
    }
    
    // 获取法线（暂时只使用顶点法线）
    let normal = normalize(in.world_normal);
    
    // 应用光照
    let lit_color = calculateLighting(normal, in.world_position, scene_uniform.camera_position, base_color);
    
    // 简单的伽玛校正
    let final_color = pow(lit_color, vec4f(2.2));
    
    return final_color;
}