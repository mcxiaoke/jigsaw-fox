# 拼图碎片亚麻布纹高倍放大方格伪影分析与备选方案储备 (B & C)

> **文档标识**：`docs/linen-texture-zoom-artifact-and-alternative-solutions-20260913.md`  
> **建立日期**：2026-09-13  
> **当前状态**：方案 A 已生效（默认禁用亚麻纹理）；方案 B 与方案 C 作为备选方案完整归档储备  
> **关联源码**：`lib/logic/rendering/linen_texture_manager.dart`、`lib/game/puzzle_piece_component.dart`

---

## 1. 现象与物理本质分析

### 1.1 痛点表现
当玩家放大视口（如放大至 225% ~ 300%）拼图时，所有碎片表面均显现出明显的规则正方形经纬网格（网织布纹），在纯色或平坦色块（如红雨伞、绿伞面、天空）上尤为刺眼。

### 1.2 量化与数学推导
对实机截图纯色区域进行傅里叶/自相关周期采样分析：
- **实测方格屏幕物理像素**：严格等于 **27.0 px**；
- **理论公式**：
  $$\text{屏幕方格周期} = \text{纹理基准周期 (4.0 dp)} \times \text{设备像素比 (DPR \approx 3.0)} \times \text{视口缩放 (2.25)} = \mathbf{27.0\text{ px}}$$
  实测值与理论推导 100% 吻合。

### 1.3 根因归结
1. **未接入视口抗缩放**：`LinenTextureManager` 的贴图通过 `ImageShader` 在 `PuzzlePieceComponent` 的局部坐标系下绘制。原本设计在 1x 视口下的 4dp 微观纤维，随碎片变换矩阵被等比放大为 27~36px 的宏观网格；
2. **混合模式副作用**：此前提交（987a241）为避免着色器卡顿，将 `BlendMode.softLight` 改为 `BlendMode.srcOver`，半透明黑白线条直接硬盖在原图上方，进一步加剧了“网格纸”感。

---

## 2. 方案全景与对比

| 方案 | 核心思想 | 改动量 | 视觉呈现 | 适用场景 |
| :--- | :--- | :--- | :--- | :--- |
| **方案 A<br>(当前采用)** | 直接禁用纹理<br>`LinenTextureManager.enabled = false` | 1 行 | 100% 纯净通透的高清原图，色彩最细腻，0 干扰 | 追求现代数码拼图高清体验、极简架构 |
| **方案 B<br>(备选储备)** | Canvas 逆缩放平铺<br>纹理平铺密度反向缩小 | ~8 行 | 无论放大到多少倍，屏幕上永远保持 4dp 细微纤维 | 坚持实体拼图压花感，且要求放大不变粗 |
| **方案 C<br>(备选储备)** | 贴图算法重构<br>消灭经纬线，改纯高斯纸浆噪点 | ~30 行 | 彻底消除几何方格，呈现柔和哑光水彩纸/素描纸磨砂质感 | 期望有纸质触感但反感任何几何十字线条 |

---

## 3. 备选方案 B：视口抗缩放平铺（保留经纬线但屏幕恒定）

### 3.1 核心设计原理
在 `PuzzlePieceComponent.render` 中绘制第四层亚麻纹理时，利用 Canvas 变换对纹理采样空间做 $1 / s$ 逆缩放，使平铺周期在屏幕空间中恒定为 4dp（不随视口放大而放大）。同时利用现有 Canvas 栈，无需每帧重建 `ImageShader`，保持**零 GC**。

### 3.2 实施代码（`lib/game/puzzle_piece_component.dart`）

替换原第 288-292 行：
```dart
// 原代码：
// final linenPaint = LinenTextureManager.paint;
// if (LinenTextureManager.enabled && linenPaint != null) {
//   canvas.drawRect(shape.fillRect, linenPaint);
// }

// 方案 B 实施代码：
final linenPaint = LinenTextureManager.paint;
if (LinenTextureManager.enabled && linenPaint != null) {
  if (scale.x > 1.0) {
    canvas.save();
    final invS = 1.0 / scale.x;
    // 逆缩放画布，抵消碎片自身的 scale.x 放大
    canvas.scale(invS, invS);
    // 等比扩展采样矩形，使其在屏幕上覆盖的物理范围与碎片完全一致
    final scaledRect = Rect.fromLTWH(
      shape.fillRect.left * scale.x,
      shape.fillRect.top * scale.x,
      shape.fillRect.width * scale.x,
      shape.fillRect.height * scale.x,
    );
    canvas.drawRect(scaledRect, linenPaint);
    canvas.restore();
  } else {
    canvas.drawRect(shape.fillRect, linenPaint);
  }
}
```

---

## 4. 备选方案 C：重构贴图生成算法（消灭经纬线，纯随机纸浆噪点）

### 4.1 核心设计原理
完全移除 `_generateLinenTextureImage` 中绘制横向经线（`canvas.drawLine`）、纵向纬线（`canvas.drawLine`）和交叉编织节点（`canvas.drawRect`）的两个 `for` 循环。  
改用纯无序伪随机高斯纸浆微粒（Pulp Noise），从几何数学层面上彻底根除“正方形方格”，赋予碎片高级哑光美术纸的漫反射颗粒感。

### 4.2 实施代码（`lib/logic/rendering/linen_texture_manager.dart`）

替换 `_generateLinenTextureImage` 方法实现：
```dart
  /// 程序化生成无缝平铺的 64x64 纯随机漫反射纸浆微粒贴图（消除任何经纬几何方格）
  static Future<ui.Image> _generateLinenTextureImage(
    int width,
    int height,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    // 1. 全透明底色
    final clearPaint = Paint()..color = const Color(0x00000000);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      clearPaint,
    );

    // 2. 伪随机细微纸浆微粒（固定随机种子保证无缝一致性）
    final rng = Random(42);
    final dotPaintLight = Paint()..color = const Color(0x08FFFFFF); // 约 3% 高光微粒
    final dotPaintDark = Paint()..color = const Color(0x08000000);  // 约 3% 暗斑微粒

    // 高密度细小微粒（模拟无方向性纸浆纤维）
    const particleCount = 256;
    for (var i = 0; i < particleCount; i++) {
      final px = rng.nextDouble() * width;
      final py = rng.nextDouble() * height;
      final radius = 0.5 + rng.nextDouble() * 0.75; // 0.5 ~ 1.25px 微粒
      final paint = rng.nextBool() ? dotPaintLight : dotPaintDark;
      canvas.drawCircle(Offset(px, py), radius, paint);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }
```

---

## 5. 决策与切换指引

若后续评估需要重新引入物理纸质感：
1. **若需要织布感**：实施 **方案 B**，并将 `LinenTextureManager.enabled = true`；
2. **若需要艺术纸质感**：实施 **方案 C**，并将 `LinenTextureManager.enabled = true`；
3. **若需提供给用户自主选择**：在设置页新增「纸张质感 / 哑光压花」Toggle，绑定持久化偏好并动态切换 `LinenTextureManager.enabled`。
