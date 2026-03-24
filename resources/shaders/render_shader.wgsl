// render_shader.wgsl
// group0全局绑定，这些都是每帧更新的
@group(0) @binding(0) var<uniform> scene_uniform : SceneUniform;
@group(0) @binding(1) var<storage, read> entities_data : array<EntitiesData>;
@group(0) @binding(2) var<storage, read> ins_data : array<InstanceData>;

// group1纹理绑定
@group(1) @binding(0) var<uniform> material_uniform : MaterialConstants;
@group(1) @binding(1) var color_texture : texture_2d<f32>;
@group(1) @binding(2) var normal_texture : texture_2d<f32>;

struct SceneUniform {
    proj_matrix: mat4x4f,
    view_matrix: mat4x4f,
    time: f32,
};

struct MaterialConstants {
    has_base_color: u32,
    has_normal: u32,
};

struct EntitiesData {
    transform: mat4x4f,
};

struct InstanceData {
    transform: mat4x4f,
    entity_idx: u32,
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
};

// 硬编码的光照参数（方便调试）
const LIGHT_DIRECTION = vec3f(1.0, 2.0, 1.0);  // 光源方向
const LIGHT_COLOR = vec3f(1.0, 1.0, 0.95);     // 暖白色光
const AMBIENT_STRENGTH = 0.3;                  // 环境光强度
const SPECULAR_STRENGTH = 0.5;                 // 高光强度
const SPECULAR_SHININESS = 32.0;               // 高光光泽度

// 辅助函数：计算世界法线
fn calculateWorldNormal(model_matrix: mat4x4f, local_normal: vec3f) -> vec3f {
    let world_normal = (model_matrix * vec4f(local_normal, 0.0)).xyz;
    return normalize(world_normal);
}

// 简单的光照计算
fn calculateLighting(normal: vec3f, position: vec3f, base_color: vec4f) -> vec4f {
    // 归一化法线
    let n = normalize(normal);
    
    // 光源方向（从表面指向光源）
    let light_dir = normalize(LIGHT_DIRECTION);
    
    // 环境光
    let ambient = AMBIENT_STRENGTH * base_color.rgb;
    
    // 漫反射
    let diffuse_factor = max(dot(n, light_dir), 0.0);
    let diffuse = diffuse_factor * LIGHT_COLOR * base_color.rgb;
    
    // 高光（镜面反射）
    let view_dir = normalize(-position);
    let reflect_dir = reflect(-light_dir, n);
    let specular_factor = pow(max(dot(view_dir, reflect_dir), 0.0), SPECULAR_SHININESS);
    let specular = specular_factor * SPECULAR_STRENGTH * LIGHT_COLOR;
    
    let final_color = ambient + diffuse + specular;
    return vec4f(final_color, base_color.a);
}

@vertex
fn vs_main(in: VertexInput, @builtin(instance_index) ins_idx: u32) -> VertexOutput {
    // 获取实例数据
    let ins = ins_data[ins_idx];
    // 通过entity_idx获取游戏实体数据
    let entity = entities_data[ins.entity_idx];
    
    // 计算完整的模型矩阵：实体变换 * 实例变换
    let model_matrix = entity.transform * ins.transform;
    
    // 计算世界坐标
    let world_pos = model_matrix * vec4f(in.position, 1.0);
    
    // 计算裁剪空间坐标
    let out_position = scene_uniform.proj_matrix * scene_uniform.view_matrix * world_pos;
    
    // 计算世界法线
    let world_normal = calculateWorldNormal(model_matrix, in.normal);
    
    // 输出
    var out: VertexOutput;
    out.position = out_position;
    out.texcoord = in.texcoord;
    out.world_normal = world_normal;
    out.world_position = world_pos.xyz;
    
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
        // 没有纹理时使用白色
        base_color = vec4f(1.0, 1.0, 1.0, 1.0);
    }
    
    // 获取法线（暂时只使用顶点法线）
    let normal = normalize(in.world_normal);
    
    // 应用光照
    let lit_color = calculateLighting(normal, in.world_position, base_color);
    
    // 简单的伽玛校正
    let final_color = pow(lit_color, vec4f(2.2));
    
    return final_color;
}