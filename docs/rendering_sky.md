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

硬切圆盘：`step(0.998, moon_dot)` × brightness × 3。
位于太阳正对面（`moon_dir = -sun_dir`），不需要独立位置计算。
未来可用贴图替代。

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
sun_direction = normalize(sin(angle)×0.8, cos(angle)×0.6 + tilt, cos(angle)×0.3)
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

```
if (density ≥ threshold)  color = mix(color1, color2, t)
else                      color = mix(color0, color1, t)
```

密度低→阴影色，密度中→中间色，密度高→高光色。阈值 `cloud_color_mtime` 控制过渡位置。

### 风动

绕 Y 轴旋转方向向量（3D 空间，无接缝）：

```
wind_angle = wind_speed × time × 0.01
wind_dir = vec3f(dir.x×cos - dir.z×sin, dir.y, dir.x×sin + dir.z×cos)
```

### 关键参数

| 字段 | 默认值 | 含义 |
|------|--------|------|
| `cloud_params1.x` | 1.1 | 云量 |
| `cloud_params1.w` | 2.0 | 风速 |
| `cloud_params2.z` | 1.0 | 云图缩放（越小云块越大）|
| `cloud_params2.w` | 0.1 | 光照偏移距 |
| `cloud_color0` | (0.2,0.2,0.2) | 云阴影色 |
| `cloud_color1` | (0.65,0.65,0.65) | 云中间色 |
| `cloud_color2` | (1.0,1.0,1.0) | 云高光色 |
| `back_lit_strength` | 5.0 | 背光强度 |
| `edge_lit_power` | 1.0 | 边缘辉光幂次 |
| `edge_lit_strength` | 1.0 | 边缘辉光强度 |
| `cloud_color_mtime` | 0.5 | 三色调插值阈值 |

### 性能

| 方案 | 帧数（只看天空）|
|------|---------------|
| cubemap（当前） | 800-900 |
| 经纬球 mesh + 2D 纹理 | 600-800 |
| 纯 shader Simplex 噪声（实验）| ~140 |

cubemap 比 mesh 快的原因是省去了每像素 atan2/acos 指令，比纯 shader 快的原因是 CPU 预烘培后 GPU 只需纹理采样。

### 方案演变

曾尝试三种云渲染路径，最终采用 cubemap：

- **ZBlock_CubeMap**（当前）— CPU 烘培 cubemap + 全屏三角，最快，效果稳定
- **ZBlock_全球网格**（保留）— UV 球 mesh + 2D 等矩形噪声纹理，需额外处理接缝/极点
- **ZBlock_纯Shader云**（保留）— 纯 GPU Simplex 噪声，无纹理采样，性能瓶颈在 ALU 密集的 snoise3
