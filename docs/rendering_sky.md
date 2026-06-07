# 程序化天空盒

## 架构

全屏三角（`@builtin(vertex_index)`），零 vertex/index buffer。
独立 pipeline（`depthWriteEnabled = 0`，`CompareFunction_Always`），
在主 render pass 的实体绘制前先画天空。

相关文件：

- `src/sky.zig` — SkyPipeline / SkyState / SkyUniform
- `resources/shaders/sky_shader.wgsl`

---

## 方向计算

```
sky_mat = transpose(view_rot) × inv(proj)
dir = normalize(sky_mat × ndc)
```

- `view_rot` 是 view 矩阵去掉平移的纯旋转矩阵
- `cached_inv_proj` = `inv(proj)`，在 `rebuildProjMatrix()` 中计算，窗口缩放时自动更新
- 不含相机平移，因此不需要 `camera_pos` 参与，数值稳定、无抖动

---

## 渲染元素

### 天空渐变

`horizon_color` / `zenith_color` 按世界方向 `dir.y` 从地平线到天顶线性混合。
夜间通过 `day_factor = smoothstep(-0.15, 0.25, sun_direction.y)` 渐变为深蓝色
`(0.02, 0.02, 0.08)`。

### 太阳

两层 pow 函数叠加：

- 外层光晕：`pow(sun_dot, 256)` × intensity × 2
- 内层亮盘：`pow(sun_dot, 2048)` × intensity × 4

### 月亮

加载 `moon.png`（512×512 RGBA8）作为 2D 纹理，像素级 UV 采样。

#### 纹理加载（`sky.zig`）

使用 `zigimg.Image.fromFilePath` + 栈上 8KB 读取缓冲区 + 堆分配像素数组加载 PNG。
纹理格式 `RGBA8Unorm`，采样器 `Nearest`（避免低分辨率纹理被线性插值糊掉）。
绑定到天空 BGL 的 binding 3（纹理）+ binding 4（采样器）。

#### 逐像素 UV 计算（`sky_shader.wgsl`）

```
moon_dot = max(dot(view_dir, moon_dir), 0)
moon_disk = smoothstep(0.75, 0.92, moon_dot)   // 软边缘代替旧的 step(0.998)

// 月亮局部坐标系
moon_right = normalize(cross(moon_dir, (0,1,0)))
moon_up = cross(moon_dir, moon_right)

// 视线在月亮平面上的投影 → UV
moon_proj = view_dir - moon_dir × moon_dot
moon_uv = (dot(moon_proj, moon_right) × 7.0 + 0.5, dot(moon_proj, moon_up) × 7.0 + 0.5)
```

`× 7.0` 控制月亮在天空中的视大小（值越大月亮越小，7.0 约等于太阳的视觉尺寸）。

#### Alpha 混合

```
moon_alpha = moon_disk × moon_tex_color.a
sky_moon = mix(sky_gradient, moon_color, moon_alpha)
```

- `moon_disk` 提供边缘淡出，`moon_tex_color.a` 来自贴图 alpha 通道（暗面=0，完全透明 → 夜空可见；亮面=1 → 显示月亮纹理）
- 暗面正确遮挡星空，消除旧版硬切圆盘的"半透明暗面"问题

#### 关键坑：贴图边缘必须保留 1px 透明间距

**现象**：月亮在天空中呈现十字形拖尾闪烁（四个方向各有一条拉伸线）。

**根本原因**：

```
moon_uv = (dot(moon_proj, right) × 7.0 + 0.5, dot(moon_proj, up) × 7.0 + 0.5)
```

`smoothstep(0.75, 0.92, moon_dot)` 的软边缘范围比月亮贴图的 UV 安全区更宽。
当 `moon_dot ≈ 0.75` 时，视线仍在采样范围内（`moon_disk > 0`），但此时
`moon_proj` 的投影分量可能已超过 `±0.5 / 7.0 ≈ ±0.071`，导致 `moon_uv` 超出 [0, 1]。

采样器使用 `ClampToEdge` 地址模式——越界 UV 被钳制到边界像素。如果贴图边缘
像素有非零 alpha，这四个方向的边界像素被拉伸出去，形成十字形拖尾。

**解决**：贴图中的有效内容与图片四边之间**必须保留至少 1px 的全透明间距**。
这样即使 UV 越界被钳制，采样到的是 alpha=0 的透明像素，视觉上完全不可见。

**通用规则**：任何以 `ClampToEdge` + UV 绕轴投影方式采样的天体贴图
（月亮、太阳、星球等），只要使用软边缘（smoothstep），**有效像素绝对不能
接触图片边缘**。建议保留 2-4px 透明边距以兼容不同的缩放系数和边缘宽度。

### 星星

基于 3D 方向哈希的程序化星空：

- 将 `normalize(dir)` 映射到 `[-100, 100]³` 整数网格
- 每格用 `hash3d` 判定是否有星；格内随机位置产生圆盘
- 半径 `smoothstep(0.3, 0.0, dist)`，夜间亮度翻倍
- 每颗星有独立的 twinkle 相位，由 `time + hash(cell)` 驱动
- `star_color_strength`：0=全白，>0 时部分星带随机色偏（未来可随季节/日期变化）

---

## 昼夜循环

```
angle = (time / day_length) × 2π
sun_direction = normalize((sin×0.8×c25 - cos×0.3×s25), cos×0.6 + tilt, (-sin×0.8×s25 + cos×0.3×c25))
c25=cos(25°), s25=sin(25°)  // XZ 绕 Y 轴旋转 25°，东北升起西南落下
```

- `day_length` = 60 秒（可在 `SkyPipeline` 的 `.day_length` 中调整）
- `seasonal_tilt`：0=春秋分（默认），+0.3=夏至（昼长），-0.3=冬至（昼短）
- `tilt` 未来可从季节系统获取

---

## 渲染流程

在 `render.zig` 中的位置：

1. 写 scene uniform + 更新天空 uniform（encoder 创建后、render pass 开始前）
2. 创建 render pass
3. **绘制天空**（独立 pipeline，slot 0 绑定天空 bind group）
4. 设置全局 bind group（slot 0 切换为主管线全局组）
5. 绘制实体 / chunk / UI

**不写深度**，因此后续的实体绘制会自然遮挡天空。

---

## 程序化云

### 架构

CPU 预烘培 3D Simplex 噪声到 6×512² RGBA8 cubemap 纹理，shader 中采样该纹理做逐像素云渲染。

```
CPU: noise.zig → fbmSnoise3 → 6×512² cubemap (R=低云 G=高薄云)
GPU: sky_shader.wgsl → texture_cube 采样 → 差分光照 → 风动 → 调色
```

**相关文件**：

- `resources/shaders/sky_shader.wgsl` — `renderClouds` / `cloudNoise`
- `src/noise.zig` — CPU 端 3D Simplex noise + Fisher-Yates 排列表
- `src/sky.zig` — `SkyPipeline.init()` 中烘培 cubemap，`updateUniform` 更新云参数

### 噪声 Cubemap 烘培

启动时在 CPU 端执行一次，约 5-8 秒：

```
for (0..6) |face|
    for (0..512) |y|
        for (0..512) |x| {
            dir = cubemap_face_direction(face, u, v)
            cubemap[face][y][x].r = fbmSnoise3(dir × 2.5, 4)  // 低云
            cubemap[face][y][x].g = fbmSnoise3(dir × 2.5×2.3, 3) // 高薄云
        }
```

- 使用 Fisher-Yates 洗牌的 perm 表 + Gustavson 3D Simplex noise
- 各面共享边采样的是同一 3D 方向的噪声值，硬件 trilinear filtering 自动处理面间边界
- 天然无缝，无需等矩形投影的接缝修复

### 云光照

#### 三方向差分

在 3D 方向空间做偏移（非 UV 空间，避免接缝）：

```
dir_front = normalize(dir + sun_dir × offset_dist)
dir_back  = normalize(dir - sun_dir × offset_dist)

front_density = cloudNoise(dir_front) × cloudNoise(dir_front_scaled)
back_density  = cloudNoise(dir_back)  × cloudNoise(dir_back_scaled)
edge = saturate(front_density - back_density)
```

`edge` 反映受光面与背光面的密度差异 → 模拟云的体积感。

#### 两层频率相乘

```
c1 = cloudNoise(normalize(dir × (cloud_size × 2.0)) × freq)  // 高频风动层
c2 = cloudNoise(normalize(wind_dir × (cloud_size + 0.1)) × freq)  // 低频基础层
center_density = saturate(c1 × c2 × cloudy_rate × 2.5)
```

两层相乘打破周期性，产生更自然的云形。

#### 太阳高光

```
sun_halo = saturate(pow(max(dot(view_dir, sun_dir), 0), 16.0))  // ±15° 范围
bright_add = cloud_density × sun_halo × cloud_color2 × back_lit_strength
```

只在太阳附近云层产生高光。未来可补充 NdotL 全局光照（注意：补充而非替换 `sun_halo`）。

#### 边缘辉光

```
edge_glow = pow(1.0 - center_density, edge_lit_power) × edge_lit_strength
cloud_density = saturate(edge + edge_glow × halo_factor)
```

低密度区域额外变亮，模拟光线穿过云层边缘的散射。

#### 三色调颜色插值

旧版基于单一 density 做阈值判断。新版改用三层偏移采样，将方向光照编码进颜色选择：

```
shadow_noise   = cubemap[normalize(dir - sun_dir × offset)]        // 背日侧
mid_noise      = cubemap[normalize(dir + sun_dir × offset × 0.3)]  // 中间
highlight_noise = cubemap[normalize(dir + sun_dir × offset × 1.5)] // 向日侧

color = mix(color0, color1, mid_noise)
color = mix(color,   color2, smoothstep(0, 0.5, highlight_noise))
color = mix(color,   color0 × 0.5, smoothstep(0.5, 0, shadow_noise))
```

阴影、常色、高光三圈随太阳位置自然偏移，不再同心。阴影效果通过混入 `color0 × 0.5` 实现（而非降低原色亮度），避免产生灰黑色斑块。

### 风动

绕 Y 轴旋转方向向量（3D 空间，无接缝）：

```
wind_angle = wind_speed × time × 0.01
wind_dir = vec3f(dir.x×cos - dir.z×sin, dir.y, dir.x×sin + dir.z×cos)
```

### Y 轴压缩

#### 需求

当云层均匀分布在球面上时，云层的曲率与天空球完全一致，视觉上让人觉得"处在一个小星球的中心"。现实中云层是地面之上的一个薄层，站在地面上看，头顶云层近、地平线云层远——云层的视觉曲率远小于天空球本身。

目标：**降低云层的视觉曲率**，让天空看起来更接近"站在地面上看远方云层"的效果。

#### 探索过程

曾尝试多种方案：

1. **Mesh 球心下移（ZBlock_全球网格）**：将 UV 球 mesh 的顶点 Y 全部减去固定偏移量（~0.85），等效于相机位于球体上半部分。效果最接近真实，但 mesh 极点处三角形汇聚的伪影在偏移后更加明显。且需要 SetVB/IB/DrawIndexed 额外 draw call，帧数比全屏三角低 ~200fps。

2. **3D 纹理 + 射线-球壳求交（已弃）**：将 cubemap 替换为 128³→256³→512²×256 的 3D texture，通过射线与偏移球壳的交点获得 3D 采样位置。原理上最正确（位置函数天然垂直分层），但 VRAM 占用从 6MB 膨胀到 256MB，烘培时间随分辨率立方增长，且噪声各向同性导致云纹图案感明显。

3. **Cubemap 烘培时球壳偏移（已弃）**：不改变 GPU 管线，只在 CPU 烘培 cubemap 时做射线-偏移球壳求交（球心下移 ~0.5），将"地面视角"直接编码进 cubemap 纹素。渲染端零改动。但因地球真实比例（R=6371km，云高≈2km）在单位球体上等同于 dome_push ≈ R，大部分射线无法命中球壳，无法用真实比例映射。

4. **Y 轴压缩（选定方案）**：放弃物理正确的球壳偏移，改为在角度空间做 Y 轴压缩——视觉上等效的纯艺术手段。

#### 原理

```
flat_dir = normalize(dir.x, dir.y × squish, dir.z)
```

- `squish = 1.0`：`flat_dir = dir`，球面分布，曲率最大
- `squish > 1.0`：Y 分量放大后归一化，方向向两极靠拢，云噪声采样在地平线附近更密集 → 云层的视觉曲率降低
- `squish = 2.0` 为默认值，效果接近 mesh 球心下移 0.85 的观感

#### 优势

- 在角度空间操作，不扭曲噪声图案（与 cubemap 的方向采样天然兼容）
- 可实时调整（通过 `cloud_params1.y` 传入 Uniform）
- 零额外 GPU 开销（比 mesh 方案快 ~200fps）

### 关键参数

| 字段 | 默认值 | 含义 |
|------|--------|------|
| `cloud_params1.x` | 1.1 | 云量 |
| `cloud_params1.y` | 2.0 | Y 轴压缩率 |
| `cloud_params1.w` | 2.0 | 风速 |
| `cloud_params2.z` | 1.0 | 云图缩放（越小云块越大）|
| `cloud_params2.w` | 0.1 | 光照偏移距 |
| `cloud_color0` | (0.2,0.2,0.2) | 云阴影色 |
| `cloud_color1` | (0.65,0.65,0.65) | 云中间色 |
| `cloud_color2` | (1.0,1.0,1.0) | 云高光色 |
| `back_lit_strength` | 5.0 | 背光强度 |
| `edge_lit_power` | 1.0 | 边缘辉光幂次 |
| `edge_lit_strength` | 1.0 | 边缘辉光强度 |
| `cloud_color_mtime` | 0.5 | 三色调插值阈值（旧版，当前由偏移采样替代）|

### 性能

| 方案 | 帧数（只看天空）|
|------|---------------|
| cubemap（当前） | 800-900 |
| 经纬球 mesh + 2D 纹理 | 600-800 |
| 纯 shader Simplex 噪声（实验）| ~140 |

cubemap 比 mesh 快的原因是省去了每像素 atan2/acos 指令，比纯 shader 快的原因是 CPU 预烘培后 GPU 只需纹理采样。

### 方案演变

最终采用 cubemap + Y 轴压缩：

- **ZBlock_CubeMap（当前）** — CPU 烘培 6×1024² cubemap + 全屏三角，~800fps，效果稳定
- **ZBlock_全球网格（保留）** — UV 球 mesh + 2D 等矩形噪声纹理，可选 fallback
- **ZBlock_纯Shader云（保留）** — 纯 GPU Simplex 噪声，实验分支
