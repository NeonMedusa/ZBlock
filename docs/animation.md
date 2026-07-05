# 骨骼动画系统

## 架构决策记录

### 1. GPU 蒙皮方案：Storage Buffer

**选择**：全局 `var<storage, read> bone_matrices : array<mat4x4f>` + per-instance `bone_offset`

**不选**：
- 纹理数组（RGBA32Float 显存浪费、需预知最大骨骼/关键帧数）
- Per-entity bind group 切换（`SetBindGroup` 开销 ~1µs/次，且增加代码复杂度）

**理由**：
- 零 bind group 切换（bone_offset 在 InstanceData 中）
- 零显存浪费（mat4x4f 直接存储，无编码/解码开销）
- 是现代游戏引擎的共同做法

### 2. 动画更新时机：物理 tick 层

**选择**：固定 30Hz 物理 tick 中更新骨骼矩阵，渲染层做 lerp 插值

```
physics tick (30Hz):
  animation_system.update(time)     → bone_current[]
  bone_prev = bone_current (在下一 tick 开始时)

render (变帧率):
  bone_render = lerp(bone_prev, bone_current, alpha)
  upload bone_render → GPU bone_pool
```

**理由**：
- 和玩家位置插值（`lerp(pos.prev, pos.vec, alpha)`）模式一致，无需引入新的插值机制
- 为将来布娃娃物理预留架构位置——物理 tick 层天然适合物理模拟
- 渲染层动画插值只有 mat4 逐分量 lerp，比重新采样动画轻得多

### 3. 骨骼矩阵存储：double-buffered pool

每帧维护两套矩阵：

```
bone_pool 布局（CPU）:
  [0..N-1]               bone_prev     — 上一 tick 的骨骼矩阵
  [N..2N-1]              bone_current  — 当前 tick 的骨骼矩阵
  N = MAX_BONES × MAX_ANIMATED_ENTITIES
```

GPU bone_pool buffer 每帧接收插值后的 `bone_render`。

### 4. CUBICSPLINE（三次样条插值）

glTF 中每个关键帧对应 3 个 output 值（入切线、值、出切线）：

```
LINEAR:     output = [v0, v1, v2, ...]              (1 值/帧)
CUBICSPLINE: output = [in0, v0, out0, in1, v1, ...]  (3 值/帧)
```

**当前决策**：加载时检测到 `interpolation == .cubic`，只提取每个关键帧的 value 分量（中间那个），作为 LINEAR 处理。以后再补完整 Hermite 插值公式。

### 5. 精简 glTF 包装层（rend_ctx.zig 的 Model/Node 结构）

从 zgltf 解析结果中提取运行时需要的数据，放入自己的结构体，然后释放 zgltf 内存。理由：

- zgltf 数据是"文件格式友好"而非"运行时友好"——accessor 迭代器链不适合每帧采样
- 生命周期管理——启动时加载完毕即可释放原始 glb 数据
- 动画更新需要紧凑的 `[]f32` 数组而不是间接迭代器

---

## 数据结构设计

### Skeleton（骨骼层次）

```zig
pub const Skeleton = struct {
    joint_count: u32,
    inverse_bind_matrices: []Mat4,  // [joint_count]
    parent_indices: []i32,          // [joint_count], -1 = root
};
```

### AnimClip / AnimChannel（动画剪辑）

```zig
pub const AnimClip = struct {
    name: []const u8,            // glTF 动画名（或映射后的逻辑名）
    duration: f32,
    channels: []AnimChannel,
};

pub const AnimChannel = struct {
    joint_index: u32,             // 目标骨骼在 skeleton.parent_indices 中的索引
    interpolation: Interpolation, // linear / step / cubic
    property: TargetProperty,     // translation / rotation / scale
    times: []f32,                 // 关键帧时间戳（input）
    values: []f32,                // 展平的 output 数据
    stride: u32,                  // 每个关键帧的 float 数（3=trans/scale, 4=rot）
};

pub const TargetProperty = enum { translation, rotation, scale };

pub const ClipName = struct {
    pub const idle  = "idle";
    pub const walk  = "walk";
    pub const run   = "run";
    pub const death = "death";
    pub const attack = "attack";
};
```

### bone_pool 布局

```
CPU:
  bone_prev    [MAX_ENTITIES × MAX_BONES]Mat4     — 上一 tick 矩阵
  bone_current [MAX_ENTITIES × MAX_BONES]Mat4     — 当前 tick 矩阵

GPU（每帧上传）:
  bone_render  [MAX_ENTITIES × MAX_BONES]Mat4     — 插值后的渲染矩阵

MAX_BONES = 128（可调）
MAX_ENTITIES = 1000（预分配不改）
bone_pool 显存 ≈ 1000 × 128 × 64B = 8MB
```

### EntityData / InstanceData 的 bone_offset

```zig
pub const EntityData = struct {
    transform: Mat4,
    bone_offset: i32 = -1,     // -1 = 无动画
};

pub const InstanceData = struct {
    transform: Mat4,
    entity_idx: u32,
    bone_offset: i32 = -1,     // ← 渲染实例在 bone_pool 中的偏移
};
```

### Model 扩展

```zig
pub const Model = struct {
    meshes: []Mesh,
    textures_res: []TextureRes,
    materials: []Material,
    nodes: []Node,
    skeleton: ?Skeleton,         // ← 有蒙皮的模型才有
    animations: []AnimClip,      // ← 动画剪辑列表
    anim_mapping: std.StringHashMapUnmanaged([]const u8),  // ← 逻辑名→glTF 动画名映射
    // 不保留 anim_textures — 用 storage buffer 代替纹理化方案
};
```

### 动画命名方案

**决策**：使用字符串名标识动画，不给常用动画名定义枚举。

**理由**：
- 主流游戏引擎的动画状态机均使用字符串名作为 API
- 新增状态（如 `crouch_walk`）不需要改任何定义，直接写字符串即可
- 下载的模型动画命名不统一，需要字符串映射；使用字符串可以统一处理
- 为了代码提示和防写错，为常用动画定义常量别名：

```zig
pub const ClipName = struct {
    pub const idle  = "idle";
    pub const walk  = "walk";
    pub const run   = "run";
    pub const death = "death";
};
```

用法：`state.clip_name = ClipName.walk;` ——有提示、不会写错。

**映射文件**：每个模型可选 `resources/models/{Name}.anim.json`：

```json
{
    "idle":   "Anim_0",
    "walk":  null,
    "death": "Anim_0"
}
```

没有映射文件的模型直接按字符串名匹配 glTF 动画名。自己搓的模型取名 `idle`/`walk` 即可零配置运行。

**查找优先级**（`resolveClip` → `findClipByName`）：
1. `findClipByName` 直接匹配 `clip_name` 与 glTF 动画名
2. 查 `model.anim_mapping`（`.anim.json`）映射到 glTF 名再匹配
3. 回退播 `animations[0]`；若无任何动画则返回 `null`（该实体不播动画）

```zig
fn findClipByName(anims: []AnimClip, name: []const u8) ?*AnimClip {
    for (anims) |*clip| {
        // 注意：ReleaseFast 下用 @memcpy 绕过编译器优化 bug
        if (std.mem.eql(u8, cn, name)) return clip;
    }
    return null;
}
```

---

## GPU 渲染管线

### Shader 新增

```wgsl
// global bind group binding 3
@group(0) @binding(3) var<storage, read> bone_matrices : array<mat4x4f>;

// vs_main 中的蒙皮计算
let is_skinned = ins.bone_offset >= 0;
var skin_pos = in.position;
if (is_skinned) {
    var skin_matrix = mat4x4f(0.0);
    for (var i = 0u; i < 4u; i++) {
        let w = in.joint_weights[i];
        if (w > 0.0) {
            let mat = bone_matrices[ins.bone_offset + i32(in.joint_indices[i])];
            skin_matrix = skin_matrix + mat * w;
        }
    }
    skin_pos = (skin_matrix * vec4f(in.position, 1.0)).xyz;
}
```

normal 同理，用 skin_matrix 的 3x3 部分做变换。

### Pipeline Layout

```
group 0 (global): scene_uniform, entities_data, ins_data, bone_matrices  ← 新增 binding 3
group 1 (material): material_uniform, color_texture, normal_texture
```

无新增 bind group，bone_matrices 挂在全局组中，零切换开销。

---

## 动画更新系统（CPU 侧）

```zig
// animation.zig
const AnimationSystem = struct {
    next_bone_offset: u32,       // 下一个可用骨骼槽位
    max_bone_slot: u32,          // 当前帧活跃骨骼上限（优化用）
    bone_prev: []Mat4,           // 上一 tick 的骨骼矩阵
    bone_current: []Mat4,        // 当前 tick 的骨骼矩阵
    bone_pool_buffer: Wgpu.WGPUBuffer,

    fn allocBoneSlot() ?u32;                     // 分配一个骨骼槽位
    fn swapBuffers() void;                       // bone_prev = bone_current
    fn update(registry, res_manager, dt) void;   // ECS 驱动，更新 bone_current
    fn upload(queue, alpha) void;                // lerp 插值后上传到 GPU
};
```

### 每帧流程

```
game loop:
  input.beginFrame()

  // 物理 tick（30Hz）
  while (accumulator >= TICK_DT)
    produceMoveIntent()
    block_world.updatePhysics()
    updateEntities()
    // 动画更新已移至主线程 pollServerSnapshot（避免与服务端线程竞态）
    accumulator -= TICK_DT

  // 渲染（变帧率）
  alpha = accumulator / TICK_DT
  animation_system.upload(queue, alpha)  // ← lerp + upload

  syncCameraFromPlayer()
  render.draw()
```

---

## evaluateClip 算法

`evaluateClip` 是骨骼动画的核心函数，对每个动画实体执行以下步骤：

### 1. 初始化每骨骼的 TRS 分量

```
joint_trans[i]  = (0, 0, 0)
joint_rot[i]    = 单位四元数
joint_scale[i]  = (1, 1, 1)
```

### 2. 遍历动画通道

每个 `AnimChannel` 按 `property` 分类处理：

| property | stride | 输出 |
|----------|--------|------|
| `.translation` | 3 | 插值后的 Vec3 → `joint_trans[joint]` |
| `.rotation` | 4 | Slerp 后的四元数 → `joint_rot[joint]` |
| `.scale` | 3 | 插值后的 Vec3 → `joint_scale[joint]` |

插值方式支持 `.linear`（线性）、`.step`（步进）、`.cubic`（三次样条，当前 fallback 为线性）。

### 3. TRS 组合 → Local Matrix

```zig
local_mats[i] = T × R × S   // Mat4.mul(trans, Mat4.mul(rot, scale))
```

### 4. 正向运动学（FK）

从根节点向下累乘父节点变换：

```
world = local_mats[i]
for each parent:
    world = parent_local × world
```

### 5. 蒙皮矩阵

```zig
bone_current[bone_offset + i] = world × inverse_bind_matrix[i]
```

---

## 活跃骨骼范围优化

每帧对所有 TOTAL_BONES（128×1000=128000）个矩阵做 lerp + upload 是巨大的浪费。实际同时活跃的动画实体通常只有个位数。

**`max_bone_slot`** 记录当前帧所有动画实体骨骼范围的最大值。`update()` 中计算：

```zig
self.max_bone_slot = 0;
// ... 遍历实体 ...
const end = state.bone_offset + skel.joint_count;
if (end > self.max_bone_slot) self.max_bone_slot = end;
```

`swapBuffers()` 和 `upload()` 只处理 `0..max_bone_slot` 范围：

```zig
pub fn swapBuffers(self) void {
    @memcpy(self.bone_prev[0..self.max_bone_slot], self.bone_current[0..self.max_bone_slot]);
}

pub fn upload(self, queue, alpha) void {
    const count = self.max_bone_slot;
    if (count == 0) return;
    // 只对 count 个矩阵做 lerp + writeBuffer
}
```

对于 3 个僵尸（各 ~20 骨骼），处理量从 128000 矩阵降到约 60 矩阵，约 2000 倍减少。

---

## 未来方向（暂不实现）

### 布娃娃物理（Ragdoll）

每骨骼挂载 collision primitive（胶囊），由物理引擎驱动：

```
正常动画播放时：
  bone_current = 动画采样结果
  碰撞体跟随骨骼矩阵（只读，不参与物理模拟）

死亡/受击时：
  物理引擎驱动骨骼矩阵
  bone_current = 物理模拟结果
  GPU 蒙皮不感知差异——数据来源相同
```

**接口透明**：shader 的 `bone_matrices` 不关心数据来自动画系统还是物理引擎，只需正确的矩阵。

### 物理受击反馈叠加

```
最终骨骼矩阵 = 动画矩阵 × 物理偏移矩阵
```

- 动画矩阵来自 `AnimationSystem`
- 物理偏移来自碰撞响应（受击冲量产生的临时位移）
- 二者在 CPU 侧相乘后传入同一 `bone_pool_buffer`

### 碰撞体类型建议

基于搜索结论，推荐每骨骼 capsule（胶囊体），三个主流引擎均以此为主要方案。

```
capsule: 由两个端点 + 半径定义
碰撞检测: capsule-vs-capsule = 线段间最近点 + 半径和检测 ≈ 30 行代码
约束类型: HingeJoint（肘/膝 1-DOF）、ConeJoint（肩/髋 3-DOF）
```

不推荐：
- ❌ mesh 顶点碰撞（性能灾难）
- ❌ 网格凸分解（复杂度超出 indie 项目需求）

### Compute Shader 动画更新

当动画实体数量级增长时（>100），可将动画采样移到 compute shader，`AnimationSystem` 退化为只负责调度。存储布局不变，只是写入方从 CPU 改为 GPU compute pass。

---

## 恐怖游戏技巧：错乱骨骼动画

动画系统的四元数分量提取顺序错误（w,x,y,z 而非 x,y,z,w）或 TRS 组合顺序错误（R×T 而非 T×R×S）会产生一种独特的恐怖效果——模型肢体扭曲、骨骼错位、关节反向弯折，类似超自然生物或尸体痉挛的视觉表现。

如果作为有意设计而非 bug，可以通过以下方式控制：

| 技巧 | 效果 |
|------|------|
| 交换四元数顺序 | 旋转轴错乱，肢体呈不自然扭曲 |
| 交换 TRS 组合顺序 | 平移/旋转/缩放以错误顺序叠加，模型膨胀或塌缩 |
| 随机化 joint_weights | 顶点随机吸附到错误骨骼，产生抽搐感 |
| 为特定骨骼设置错误 parent_indices | 骨骼层次断裂，肢体脱离躯干 |

这些效果可控性强、性能开销为零（纯数据驱动），适合作为恐怖游戏的"受诅咒实体"、"扭曲怪物"或"精神污染"场景的视觉方案。

---

## 相关技术
- 碰撞方案共识：per-bone primitive（capsule/box/sphere 每骨骼独立碰撞 + 约束链）
- 布娃娃系统：per-bone convex hull + constraint chain + 半隐式 Euler 积分器
- 物理学：半隐式 Euler 积分器、顺序冲量求解器