# 3D 渲染

## 着色器颜色校正

SRGB 硬件自动做 pow(1/2.2)，shader 做 pow(2.2) 抵消，线性颜色正确显示。

---

## 概述

- 使用 wgpu-native + GLFW
- 动态太阳/月光照（方向/强度/颜色由天空系统提供）+ Blinn-Phong 高光
- 半球环境光：白天用地平线色，夜晚用深空色，昼夜平滑过渡
- 支持 glTF/glb 模型
- 区块使用 greedy mesh 合并同材质面

### 视锥体裁剪

`render.zig` 每帧从 view-projection 矩阵提取 6 个视锥平面，在渲染循环中剔除不可见对象：

```
左平面: clip.x + clip.w ≥ 0    右平面:  clip.w - clip.x ≥ 0
底平面: clip.y + clip.w ≥ 0    顶平面:  clip.w - clip.y ≥ 0
近平面: clip.z ≥ 0            远平面:  clip.w - clip.z ≥ 0
```

- **实体**：检查 AABB（碰撞箱 `width`×`height`）与视锥的相交性 `intersectsAABB(min, max)`，不可见则跳过 draw batch
- **区块**：检查 chunk AABB（16×256×16）与视锥的相交性 `intersectsAABB(min, max)`，不相交则跳过 mesh 遍历
- 模型和 mesh 缓存不因剔除而卸载——视角转回时零延迟

实现见 `src/frustum.zig`（约 100 行）。

---

## 动态光照

光照由 `SceneUniform`（`src/rend_ctx.zig`）携带，每帧从天空系统同步：

| 字段 | 来源 | 作用 |
|---|---|---|
| `sun_direction` / `sun_intensity` | `SkyState.sun_direction` / `.sun_intensity` | 太阳光照方向与强度 |
| `sun_color` / `moon_brightness` | `SkyState.sun_color` / `.moon_brightness` | 太阳颜色 / 月亮亮度 |
| `horizon_color` | `SkyState.horizon_color` | 环境光颜色（屋顶层） |

### 光照模型（`render_shader.wgsl:calculateLighting`）

```
环境光 = mix(深空夜, horizon_color, day) × AMBIENT_STRENGTH
阳光   = day × max(dot(n, sun_dir), 0) × sun_color × intensity
月光   = night × max(dot(n, -sun_dir), 0) × moon_color × moon_intensity
高光   = day × Blinn-Phong 高光（仅太阳贡献）
```

- `day = smoothstep(-0.15, 0.25, sun_direction.y)`，与天空盒的昼夜过渡一致
- 太阳在地平线以上时阳光为主、地平线以下时月光为主
- 月光方向永远在太阳正对面（`-sun_dir`），颜色偏蓝

### 渲染流程

1. `sky.zig:updateUniform` 从角度计算 `sun_direction`，写入天空 uniform
2. `render.zig` 将 `sky_pipeline.state` 的以上字段拷贝到 `game.ubo`
3. 计算阴影 VP → 渲染阴影 pass
4. **写 `scene_uniform_buffer` 到 GPU（阴影 pass 之后，确保主 pass 使用同一帧的 shadow_vp）**
5. shader 从 `SceneUniform` 读取光照参数，逐像素计算

---

## 阴影贴图 (Shadow Mapping)

方向光阴影，单张 2048×2048 深度贴图（`Depth32Float`）。

### 整体流程

1. **选光源**：`sun_direction.y > 0` 时用太阳，否则用月亮
2. **Pass 1 — 阴影渲染**：从光源视角将所有区块渲染到深度贴图，经视锥体裁剪（`Frustum.fromViewProj(light_vp)`）跳过无关区块
3. **写入 uniform**：在阴影 pass 之后、主 pass 之前写入 `scene_uniform_buffer`，确保两 pass 使用**同一帧的 shadow_vp**（关键修复：写入过早会导致主 pass 采样到上一帧的 VP，产生帧错位闪现）
4. **Pass 2 — 主渲染**：每像素采样阴影贴图，调制直接光照

### 核心参数

`ShadowPipeline.computeLightVp()` 计算正交投影 VP（WebGPU NDC z ∈ [0,1]），n/f 为负值表示 view 空间中相机前方沿 -Z：

| 参数 | 值 | 说明 |
|------|-----|------|
| `half_size` | 128 | 覆盖 ±128m（256m 宽） |
| `dist` | 256 | 光源距中心 256m |
| `center Y` | 60 | 视锥中心固定在地面高度 |
| `n / f` | -128 / -640 | 近/远平面，深度范围 512m |
| `snap` | 3.0 | 中心每 3m 跳一次，消除 VP 微变导致的边缘拉锯 |

VP 矩阵 = `proj × lookAt(light_pos, center, (0,1,0))`。

### 径向畸变

影子贴图中心纹素更密、边缘更疏，提高近处阴影精度：

```
distort = length(ndc.xy) + 0.1
ndc.xy /= distort
```

- 中心（length≈0）：`distort ≈ 0.1` → 有效精度提升 **10×**
- 边缘（length=1）：`distort ≈ 1.1` → 微压缩至 ~0.9×

### 阴影采样与偏置

`sampleShadow()` 中，法线偏移是唯一的抗自交手段（无管线 depth bias，无固定 shader bias）：

```
off_amt = min(0.03 + cam_dist × 0.005, 0.5) × (2 - |N·L|)
biased  = world_pos + normalize(normal) × off_amt
```

正对光的面（|N·L|≈1）偏移 0.03~0.1m，斜面（|N·L|≈0）自动增大至 ~0.5m，距离越远偏移越大。

```
biased → shadow_vp → 畸变 → UV (Y 翻转) → textureSampleCompare → 0/1
```

UV 范围外返回 1.0（无阴影）。

### 开发经验

1. **ubo 时序**：必须在阴影 pass 后、主 pass 前写入，否则两 pass VP 不同帧 → 闪现
2. **center snap**（3m）从根源上减少 VP 更新频率，比 UV snap 或 PCF 更有效
3. **`depthBiasSlopeScale` 是 Peter Panning 的元凶**：垂直面上产生大偏置导致根部阴影分离，去掉后用**法线偏移**代替
4. **法线偏移参数**：`0.03 + dist×0.005` 让近处小、远处大，`(2-|N·L|)` 让正对光的面自动获得更小偏移
5. **2048² + 畸变**：畸变使有效中心精度 ~20480²，比纯分辨率暴力翻倍更高效

### GPU 资源

| 资源 | 说明 |
|------|------|
| `shadow_depth_texture` | 2048² `Depth32Float`，render attachment + texture binding |
| `shadow_sampler` | `CompareFunction_Less` + `Linear`（硬件 PCF） |
| `shadow_bgl` | 渲染 pipeline group 2：深度贴图 + 比较采样器 |
| `ShadowPipeline.light_vp` | CPU 端缓存 VP，每帧写入 shadow uniform 和 `SceneUniform.shadow_vp` |

### 文件索引

| 文件 | 内容 |
|------|------|
| `src/shadow.zig` | `ShadowPipeline`：init、`computeLightVp`、深度贴图/采样器/管线 |
| `src/render.zig:39-78` | 方向选择、VP 计算、阴影渲染 pass 与视锥裁剪 |
| `src/render.zig:73-87` | ubo 写入（阴影 pass 后，关键顺序） |
| `resources/shaders/shadow_shader.wgsl` | 阴影 pass vertex shader（深度写入 + 畸变） |
| `resources/shaders/render_shader.wgsl:108-130` | `sampleShadow()` + 法线偏移 + 畸变 |
| `src/rend_ctx.zig` | `SceneUniform.shadow_vp` |
| `src/render_pipeline.zig:125-135` | shadow BGL 定义 |
| `src/game.zig:342-360` | 阴影管线 + bind group 初始化 |

---

## 三管线顶点架构

三种 vertex 格式分三条 pipeline 独立渲染，互不干扰。一个 `render_shader.wgsl` module 包含三个 `@vertex` 入口：

| Pipeline | 顶点格式 | 顶点大小 | 用途 |
|----------|---------|---------|------|
| `pipeline_static` | `StaticVertex` | 32B (pos+normal+texcoord) | 无骨骼 glTF 模型 |
| `pipeline_skinned` | `SkinnedVertex` | 64B (以上+joints+weights) | 骨骼动画模型 |
| `pipeline_chunk` | `ChunkVertex` | **4B** (packed struct) | 区块（方块世界） |

### ChunkVertex：极致紧凑的区块顶点

区块顶点使用 `packed struct` 压缩到一个 u32 中，位置/法线/UV 全部靠 shader 推导：

```zig
pub const ChunkVertex = packed struct {
    bx: u5,        // bits 0-4:   chunk 局部 X (0~16)
    by: u8,        // bits 5-12:  垂直 Y (0~255)
    bz: u5,        // bits 13-17: chunk 局部 Z (0~16)
    face_dir: u3,  // bits 18-20: 局部面方向（UV用）
    world_dir: u3, // bits 21-23: 世界面方向（法线用）
    corner: u2,    // bits 24-25: quad 角索引 (0-3)
    _pad: u6 = 0,  // bits 26-31
};
```
```

- **坐标**：通过 per-chunk instance 的 `translate(origin)` 转换为世界坐标
- **法线**：`face_dir` 解码为 `vec3f`
- **UV**：`corner` + `face_dir`，`computeChunkUV()` 直接算出整张纹理的 UV

### 无索引画法

区块使用非索引画法（`Draw()` 代替 `DrawIndexed()`），每 quad 直接写入 6 个顶点：

```python
三角形 1: v0(4B), v2(4B), v1(4B)    # face_data.positions[0,2,1]
三角形 2: v0(4B), v3(4B), v2(4B)    # face_data.positions[0,3,2]
= 6 × 4B = 24B  # 索引画法 4×4B + 6×4B = 40B，无索引节省 40%
```

- 无索引 → 无索引溢出风险、无 index buffer 显存占用
- 顶点从 32B 降至 4B → 每 chunk 顶点显存下降 **87.5%**

### 动静模型的分化

模型加载时通过 `gltf.data.skins.len > 0` 分支决定顶点类型：

- **无骨骼（静态模型）** → `loadPrimitiveVertices(StaticVertex, ...)`，每顶点 32B
- **有骨骼（蒙皮模型）** → `loadPrimitiveVertices(SkinnedVertex, ...)`，每顶点 64B

底层使用泛型函数 `fn loadPrimitiveVertices(comptime V: type, ...)`，
`.joints` / `.weights` 属性用 `if (V != StaticVertex)` 包裹——编译期
消除，零运行时开销。

### 骨骼矩阵 storage buffer

所有实体的骨骼变换矩阵打包进一个 `array<mat4x4f>` storage buffer，每帧上传 CPU 计算的
蒙皮矩阵。每个 instance 携带 `bone_offset`（在 storage buffer 中的起始索引），零 bind
group 切换代价。

## 线框管线

独立于主渲染管线的 `WireframePipeline`，使用 `wireframe_shader.wgsl`：
`LineList` 拓扑、`Cull_None`、禁深度写入。vertex 只读 `position`，不读取纹理/光照。
当前已创建但未接入绘制循环，留待调试选中高亮用。

---

## 程序化天空盒

详见 [rendering_sky.md](rendering_sky.md)

## 程序化云

CPU 预烘培 3D Simplex 噪声到 6×512² cubemap，shader 中采样实现逐像素云渲染。
支持风动、三方向差分光照、太阳高光、边缘辉光。详见 [rendering_sky.md](rendering_sky.md) 的程序化云章节。
