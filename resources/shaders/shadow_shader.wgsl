struct LightUniform {
    light_vp: mat4x4f,
};

struct InstanceData {
    transform: mat4x4f,
    entity_idx: u32,
    bone_offset: i32,
    _padding: array<i32, 2>,
};

@group(0) @binding(0) var<uniform> shadow: LightUniform;
@group(0) @binding(1) var<storage, read> ins_data: array<InstanceData>;

struct VertexInput {
    @location(0) position: vec3f,
};

@vertex
fn vs_main(in: VertexInput) -> @builtin(position) vec4f {
    var clip_pos = shadow.light_vp * vec4f(in.position, 1.0);
    let df = length(clip_pos.xy) + 0.1; // 径向畸变：中心纹素更密
    clip_pos.x /= df;
    clip_pos.y /= df;
    return clip_pos;
}

struct ChunkVertexInput {
    @location(0) packed_pos: u32,
};

@vertex
fn vs_chunk(in: ChunkVertexInput, @builtin(instance_index) ins_idx: u32) -> @builtin(position) vec4f {
    let pp = in.packed_pos;
    let bx = f32(pp & 0x1Fu);
    let by = f32((pp >> 5u) & 0xFFu);
    let bz = f32((pp >> 13u) & 0x1Fu);
    let ins = ins_data[ins_idx];
    let world_pos = ins.transform * vec4f(bx, by, bz, 1.0);
    var clip_pos = shadow.light_vp * world_pos;
    let df = length(clip_pos.xy) + 0.1;
    clip_pos.x /= df;
    clip_pos.y /= df;
    return clip_pos;
}