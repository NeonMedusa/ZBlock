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
3. `render.zig` 写 `scene_uniform_buffer` 到 GPU
4. shader 从 `SceneUniform` 读取光照参数，逐像素计算

---

## 双管线顶点架构

管线和 vertex 格式按"是否带骨骼"分拆，核心思路是用一个 vertex buffer 承载两种格式，两
条 pipeline 读各自需要的 attribute。

### Vertex 格式

```
StaticVertex (32B)          SkinnedVertex (64B)
┌────────────────┐          ┌────────────────┐
│ position (12B) │          │ position (12B) │  ← 前三个字段与 Static 完全一致
├────────────────┤          ├────────────────┤
│ normal   (12B) │          │ normal   (12B) │
├────────────────┤          ├────────────────┤
│ texcoord ( 8B) │          │ texcoord ( 8B) │
└────────────────┘          ├────────────────┤
                             │ joint_indices  │  ← [4]u32, 16B
                             ├────────────────┤
                             │ joint_weights  │  ← [4]f32, 16B
                             └────────────────┘
```

两种 vertex 各自上传到独立的 vertex buffer，无空位浪费。static pipeline 读前
32B（stride=32），skinned pipeline 读全部 64B（stride=64）。chunk 和模型各
自的 buffer 内顶点连续排列。

### 动静模型的分化

模型加载时通过 `gltf.data.skins.len > 0` 分支决定顶点类型：

- **无骨骼（静态模型）** → `loadPrimitiveVertices(StaticVertex, ...)`，每顶点 32B，无浪费
- **有骨骼（蒙皮模型）** → `loadPrimitiveVertices(SkinnedVertex, ...)`，每顶点 64B

底层使用泛型函数 `fn loadPrimitiveVertices(comptime V: type, ...)`，
`.joints` / `.weights` 属性用 `if (V != StaticVertex)` 包裹——编译期
消除，零运行时开销。

chunk mesh 与静态模型共享同样的 `StaticVertex` 布局（32B），通过
`chunk_mesh.zig` 独立上传，不走模型加载路径。

### 两个 entry point + 两个 pipeline

一个 `render_shader.wgsl` module 包含两个 `@vertex` 入口：

- `vs_static(in: StaticVertex)` → `pipe_static`（attribute location 0-2，stride=32）
- `vs_skinned(in: SkinnedVertex)` → `pipe_skinned`（attribute location 0-4，stride=64）

共享同一个 `fs_main` 片段着色器。draw batch 通过 `vertex_format` 枚举
（`static_model` / `skinned_model`）路由到对应 pipeline。

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
