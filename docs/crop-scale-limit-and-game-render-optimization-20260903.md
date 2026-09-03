# 裁切界面缩放物理像素限制与拼图界面视锥剔除渲染优化方案

> **文档状态**：实施定稿  
> **日期**：2026-09-03  
> **责任范围**：自制拼图裁切页面（lib/pages/crop_puzzle_page.dart）、拼图切片渲染组件（lib/game/puzzle_piece_component.dart）  

---

## 1. 业务背景与问题定义

### 1.1 问题一：裁切界面缩放不能超过原始像素（原 900%+ 异常缩放）
* **现状分析**：
  在 CropPuzzlePage 中，原计算公式为 maxAllowedScale = max(1.0, 1.0 / baseScale)。当用户导入高分辨率原图（如 4000x3000 或 6000x4000）时，因视口仅约 400x300，算出的 maxAllowedScale 高达 10.0 ~ 15.0（即 1000% ~ 1500%）。
* **缺陷影响**：
  用户可无限滚轮放大至 900%+，将大图裁剪至只剩指甲盖大小的几百像素微小局部，严重破坏构图并导致导出的拼图块像素模糊，失去游玩价值。
* **解决原则**：
  缩放必须受原图实际物理像素约束。裁切区域物理像素在任何缩放倍率下，均不得低于拼图素材基准及格清晰度（1080px）；原图较小时（短边 <= 1080px），严格锁定最大缩放为 1.0x（禁止数码拉伸）。

### 1.2 问题二：托盘模式下放大后拖动非常卡顿
* **现状分析**：
  默认托盘模式（scatterMode == 'tray'）下，拼图切片单行横向排布。当关卡有 100+ 碎片时，屏幕可视托盘区域仅容纳约 10 块，其余 85%~90% 的碎片横向排列在屏幕右侧外部（X 轴可延伸至数千像素）。
  然而，所有碎片均为 Flame 顶层挂载组件。当棋盘放大后平移拖动时，每一瞬间的鼠标移动均触发全屏每秒 60/120 帧重绘，导致屏幕外数十至数百块碎片每一帧都在强行执行 GPU 高斯模糊（MaskFilter.blur）、复杂二次贝塞尔 clipPath 与亚麻布纹软光混合，GPU 填充率与离屏通道瞬间被打满。
* **解决原则**：
  **不破坏现有任何拼图逻辑、手势事件、触摸拖动和吸附机制**，仅在纯渲染层（ender 方法）实施只读视锥体剔除（Frustum Culling），并将静止接触阴影降级为无需 GPU 模糊的纯色微投影。

---

## 2. 方案详细设计与实施细节

### 2.1 裁切缩放物理像素硬约束（crop_puzzle_page.dart）

根据《拼图素材选图标准》（docs/puzzle-image-selection-standard.md §2.3），拼图素材全档位可用及格线为短边 1080px。

定义基准像素门槛：
`kMinOriginalCropPixels = 1080.0`

真实几何映射推导：
1. 裁切视口与原图的基础缩放比：
   `baseScale = max(viewportSize.width / imgW, viewportSize.height / imgH)`
2. 裁切区域在原图上的实际物理像素尺寸（Natural Crop Dimensions）：
   `realCropW = viewportSize.width / (baseScale * scale)`
   `realCropH = viewportSize.height / (baseScale * scale)`
   实际短边像素为：`min(realCropW, realCropH) = min(boxW, boxH) / (baseScale * scale)`
3. 约束 `min(realCropW, realCropH) >= kMinOriginalCropPixels` 的精确物理上限：
   `physMax = min(viewportSize.width, viewportSize.height) / (baseScale * kMinOriginalCropPixels)`
   `maxScale = max(1.0, physMax)`
4. 为什么不能直接用粗略的 `imgShortSide / 1080`：
   * 粗略公式仅在原图宽高比与所选裁切画幅完全相同时相等；
   * 一旦画幅不同（如 3000x4000 原图选 4:3 裁切框，或 1440x1440 正方形原图选 3:2 裁切框），粗略公式会大幅高估上限，使真实裁切短边跌落至 720~810px；
   * 精确公式 `physMax` 确保在**任意原图尺寸、任意所选画幅比例**下，拉满缩放时的物理短边均严格不低于 1080px；
5. 边界与二次超分衔接：
   * 若原图较小（`physMax <= 1.0`，如 800x600 或 1080x1080），则严格锁定 `maxScale = 1.0`（禁止数码拉伸糊图，仅允许平移选区）；
   * 小图在导出后自动衔接 `ImageUpscaler`（阈值 750/1000）进行二次 AI/插值超分兜底；
   * 彻底杜绝 900% ~ 1500% 的失控缩放。

### 2.2 拼图切片纯渲染层视锥剔除与阴影优化（puzzle_piece_component.dart）

#### A. 只读视锥剔除（Frustum Culling）
在 `PuzzlePieceComponent.render(Canvas canvas)` 最前置位置，检测当前碎片及所属集群的屏幕外包围盒：
```dart
final isHoldingCluster = game.holdingPiece?.clusterId == clusterId;
if (!isDragging &&
    !isHoldingCluster &&
    game.size.x > 0 &&
    game.size.y > 0) {
  final oh = shape.overhang;
  const margin = 4.0; // 容纳接触阴影 0.8px 垂直位移与 2.5px 描边外扩
  final left = position.x - (oh.left * size.x + margin) * scale.x;
  final right = position.x + ((1.0 + oh.right) * size.x + margin) * scale.x;
  final top = position.y - (oh.top * size.y + margin) * scale.y;
  final bottom = position.y + ((1.0 + oh.bottom) * size.y + margin) * scale.y;
  if (right < 0 ||
      left > game.size.x ||
      bottom < 0 ||
      top > game.size.y) {
    return; // 屏幕外静止碎片直接跳过 Canvas 绘制
  }
}
```
* **零侵入保证与细节完善**：
  * **几何闭合**：计入 `PieceShape.overhang`（凸头外扩 35%、凹槽外扩 15%），消除视口边缘切片突兀闪烁与消失；
  * **集群拖拽保护**：`!isHoldingCluster` 保证拖拽大集群时边缘伴随切片不被误剔除；
  * **视口守卫**：防守初始化零尺寸；
  * **Draw Call 削减**：托盘模式下立即消减 85%~90% 的无效 GPU Draw Call。

#### B. 静止接触阴影去模糊
* 静止硬纸板紧贴底托，位移仅垂直 0.8px，保留 Color(0x30000000) 纯色接触阴影，移除 MaskFilter.blur(BlurStyle.normal, 1.0)；
* 仅在手指抓起悬浮（isElevated == true）时保留 7.0px 大范围扩散高斯软阴影；
* 消除托盘内所有静止碎片每帧的离屏高斯模糊卷积 Pass。

---

## 3. 影响范围与验证方案

1. **测试断言**：运行 `flutter test`，验证 `test/crop_puzzle_test.dart` 中缩放断言与全量 233 项单元测试全部通过；
2. **代码规范**：运行 `flutter analyze` 保持 0 警告 0 错误；
3. **平台构建**：运行 `flutter build windows --debug` 确保 Windows 平台无编译异常。
