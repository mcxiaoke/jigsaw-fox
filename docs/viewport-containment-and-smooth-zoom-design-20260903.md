# 拼图区域视口贴边包裹模型（Viewport Containment）设计与实施方案

- **日期**：2026-09-03
- **版本**：v1.1（吸收 dsf & msf 专家评审意见修订版）
- **模块**：游戏引擎 / 视口与缩放平移系统 (`lib/game/jigsaw_puzzle_game.dart`)

---

## 0. 版本修订记录（v1.0 -> v1.1）

响应独立专家评审报告（`dsf` 与 `msf`）的深度技术审查意见，v1.1 进行如下关键闭环修订：
1. **【P0-1 彻底移除断崖式早退】**：删除 `_clampPanOffset()` 开头的 `if (_zoom <= 1.0) { _panOffset.setZero(); return; }`，消除逻辑自相矛盾，使 1.0x 及以下完全由几何公式自然收敛居中，彻底根治双指捏合缩小至 1.0x 时的未松手弹跳；
2. **【P1-1 视口与布局坐标基准严格对齐】**：统一双模式的视口基准。`viewTop` 统一对齐 `_topToolbarHeight (8.0)`，`viewLeft` 统一对齐 `_sideMargin (8.0)`，`viewRight` 对齐 `size.x - _sideMargin`，彻底解决桌面散落模式（Tabletop）下棋盘放大后钻入顶部 AppBar 后的坐标系漂移问题；
3. **【P0-2 / P2-2 临界单点退化与浮点防御】**：采用 `if (content + eps >= view)` 与单点退化写法 `minPan = maxPan = center`，并用 `min(minPan, maxPan)` / `max(minPan, maxPan)` 包裹，彻底杜绝浮点误差导致 Dart `ArgumentError` 崩溃以及跨越临界时的离散硬切；
4. **【P1-2 补齐双轴非满铺（Letterbox / 竖图）数学证明】**：增加对窄棋盘、竖图或小缩放倍率下小维度“锁定居中”与主维度“贴边漫游”的双轴几何连续性论证；
5. **【P1-3 测试用例显式按长宽比解耦构造】**：测试用例显式声明固定长宽比（横图验证左右贴边，竖图验证垂直贴边与水平居中），避免测试断言误判。

---

## 1. 问题背景与现状诊断

### 1.1 现状痛点
在游戏页面（`GamePage`）中双指操作拼图棋盘区域时，存在两个紧密关联的交互体验缺陷：
1. **棋盘放大后可被拖走很远**：在放大状态下，单指或中键拖动棋盘，棋盘可以被拖到视野之外很远的位置，暴露出大片空白背景底色，甚至出现只剩一个角落留在屏幕上的失控情况。
2. **双指缩小恢复至 100% 时突发弹跳回中**：当用户双指放大拼图后，保持两指贴在屏幕上慢慢向内捏合缩小，在缩放倍率接近并达到 100%（1.0x）的瞬间，**用户尚未松手**，棋盘突然发生剧烈的瞬移/弹跳回到正中央。若两指在 1.0 边缘轻微颤动，还会引发高频抖动跳跃。

### 1.2 根因分析（代码级诊断）
缺陷源自 `lib/game/jigsaw_puzzle_game.dart` 中的 `_clampPanOffset()` 方法：

```dart
void _clampPanOffset() {
  if (_zoom <= 1.0) {
    _panOffset.setZero(); // 根因 2：跌入 <=1.0x 瞬间强行清零
    return;
  }

  ...
  const edgeMargin = 80.0; // 根因 1：过度宽松的边界（只需保留 80px）

  final minPanX =
      edgeMargin - contentW - boardTopLeft.x - normMinX * boardSize.x * _zoom;
  final maxPanX =
      viewportW -
      edgeMargin -
      boardTopLeft.x -
      normMinX * boardSize.x * _zoom;
  ...
  _panOffset.x = _panOffset.x.clamp(minPanX, maxPanX);
}
```

1. **允许过大偏移量（导致可拖走很远）**：
   原逻辑设置了 `edgeMargin = 80.0`，这意味着只要棋盘内容有 80px 还留在屏幕内即可。对于一个 400px 宽的棋盘，在放大时允许平移几百像素，导致 `_panOffset` 累积极大的偏移量。
2. **断崖式截断（导致未松手弹跳）**：
   在捏合缩小的过程中，即便缩小到了 `1.05x`、`1.01x`，由于上述计算出的允许区间 `[minPanX, maxPanX]` 依然宽达数百像素，棋盘依然维持在偏离中心的位置；
   一旦捏合距离使缩放值跌到 `1.0`（被 `clamp(1.0, maxZoom)` 截断到 1.0），代码瞬间触发 `if (_zoom <= 1.0) _panOffset.setZero()`，在单帧内强行将几百像素的偏移清零。这造成了肉眼可见的剧烈突变弹跳。

---

## 2. 业界标准模型：视口贴边包裹模型（Viewport Containment）

主流成熟的拼图游戏（Jigsaw Puzzles）以及移动端系统级相册（Photo Gallery）、地图（Maps）视口缩放平移交互，均采用**视口贴边包裹模型**。

```
+-----------------------------------------------------------+
| 视口有效可视区域 (Viewport)                                |
| (viewLeft, viewTop)                                       |
|                                                           |
|       +-------------------------------------------+       |
|       | 放大状态下的拼图棋盘 (Zoomed Board)        |       |
|       |                                           |       |
|       | 规则 1：棋盘外围四边缘不可向内脱离视口边界|       |
|       |         （不留空隙、不露出空白背景）      |       |
|       |                                           |       |
|       | 规则 2：玩家可在棋盘内容内部 360° 漫游细节|       |
|       +-------------------------------------------+       |
|                                                           |
|                               (viewRight, viewBottom)     |
+-----------------------------------------------------------+
```

### 核心设计原则
1. **边界贴合（No Empty Void）**：
   - 放大状态下，若棋盘宽度大于视口宽度，则棋盘左边不能脱离视口左边界（`boardLeft <= viewLeft`），右边不能脱离视口右边界（`boardRight >= viewRight`）。
   - 若棋盘高度大于视口高度，则棋盘顶边不能脱离视口顶边界（`boardTop <= viewTop`），底边不能脱离视口底边界（`boardBottom >= viewBottom`）。
   - 用户可以自由查看棋盘的每一个角落，但棋盘边缘永远贴在视口边缘，绝不将整个棋盘甩出视口。
2. **小维度自动居中（Sub-viewport Dimension Auto-Centering）**：
   - 当棋盘在某个维度上的尺寸小于视口（例如在宽屏下的竖图拼图，或放大初期尚未填满视口），该维度平滑居中展示。
3. **连续平滑收敛（Continuous Smooth Convergence）**：
   - 当用户从 2.0x 逐渐捏合缩小到 1.0x 时，允许平移的区间 `[minPan, maxPan]` 随缩放倍数 `zoom` 的减小**单调、平滑收缩**。
   - 当 `zoom -> 1.0` 时，`minPan` 与 `maxPan` 自然连续收敛至 `0`。
   - 缩小到 100% 的瞬间，棋盘已经自然而然无缝就位视口中央，**无任何位置突变，彻底消除弹跳感**。

---

## 3. 数学建模与精确几何算法

### 3.1 视口边界界定（Viewport Bounds）
在 `JigsawPuzzleGame` 中，棋盘布局在 `_computeLayout` 时始终以工具栏高度 `_topToolbarHeight (8.0)` 与侧边距 `_sideMargin (8.0)` 为基准。视口矩形 `[viewLeft, viewTop, viewRight, viewBottom]` 必须与布局坐标系严格统一：

| 视口参数 | 托盘模式 (Tray Mode) | 桌面散落模式 (Tabletop Mode) | 说明 |
| :--- | :--- | :--- | :--- |
| `viewLeft` | `_sideMargin` (8.0) | `_sideMargin` (8.0) | 双模式均保留 8px 外边距 |
| `viewRight` | `size.x - _sideMargin` | `size.x - _sideMargin` | 双模式对齐右边界 |
| `viewTop` | `_topToolbarHeight` (8.0) | `_topToolbarHeight` (8.0) | **严格避让顶部工具栏，杜绝钻入 AppBar 后** |
| `viewBottom` | `trayPosition.y - 8.0` | `size.y - 8.0` | 托盘模式贴托盘顶；桌面模式贴屏幕底 |
| 视口有效宽高 | `viewW = viewRight - viewLeft`<br>`viewH = viewBottom - viewTop` | `viewW = viewRight - viewLeft`<br>`viewH = viewBottom - viewTop` | 视口有效承载区域 |

### 3.2 棋盘实际屏幕坐标计算
定义相对归一化边界：
- 托盘模式：`normMinX = 0.0, normMaxX = 1.0; normMinY = 0.0, normMaxY = 1.0;`
- 桌面模式：`normMinX = -0.35, normMaxX = 1.35; normMinY = -0.35, normMaxY = 1.35;`

在当前缩放 `_zoom` 与平移 `_panOffset` 下：
- 内容宽度：$contentW = (normMaxX - normMinX) \times boardSize.x \times \_zoom$
- 内容高度：$contentH = (normMaxY - normMinY) \times boardSize.y \times \_zoom$
- 内容屏幕左上角：$screenLeft = boardTopLeft.x + \_panOffset.x + normMinX \times boardSize.x \times \_zoom$
- 内容屏幕右上角：$screenRight = screenLeft + contentW$
- 内容屏幕顶边缘：$screenTop = boardTopLeft.y + \_panOffset.y + normMinY \times boardSize.y \times \_zoom$
- 内容屏幕底边缘：$screenBottom = screenTop + contentH$

### 3.3 贴边约束公式（Clamping Formula）

#### 水平方向（X 轴）：
1. **若 $contentW + \epsilon \ge viewW$（棋盘宽于或等于视口）：**
   - 左边缘不可移入视口内侧（禁止左侧留白）：
     $$maxPanX = viewLeft - boardTopLeft.x - normMinX \times boardSize.x \times \_zoom$$
   - 右边缘不可移入视口内侧（禁止右侧留白）：
     $$minPanX = viewRight - boardTopLeft.x - normMinX \times boardSize.x \times \_zoom - contentW$$
2. **若 $contentW + \epsilon < viewW$（棋盘窄于视口）：**
   - 维持水平居中（区间退化为单点）：
     $$minPanX = maxPanX = viewLeft + \frac{viewW - contentW}{2} - boardTopLeft.x - normMinX \times boardSize.x \times \_zoom$$
3. **最终平移钳位（防范浮点 ArgumentError 崩溃）：**
   $$\_panOffset.x = \_panOffset.x.\text{clamp}(\min(minPanX, maxPanX), \max(minPanX, maxPanX))$$

#### 垂直方向（Y 轴）：
1. **若 $contentH + \epsilon \ge viewH$（棋盘高于或等于视口）：**
   - 顶边缘不可下移离开视口顶端（禁止顶部留白）：
     $$maxPanY = viewTop - boardTopLeft.y - normMinY \times boardSize.y \times \_zoom$$
   - 底边缘不可上移离开视口底端（禁止底部留白）：
     $$minPanY = viewBottom - boardTopLeft.y - normMinY \times boardSize.y \times \_zoom - contentH$$
2. **若 $contentH + \epsilon < viewH$（棋盘矮于视口）：**
   - 维持垂直居中（区间退化为单点）：
     $$minPanY = maxPanY = viewTop + \frac{viewH - contentH}{2} - boardTopLeft.y - normMinY \times boardSize.y \times \_zoom$$
3. **最终平移钳位：**
   $$\_panOffset.y = \_panOffset.y.\text{clamp}(\min(minPanY, maxPanY), \max(minPanY, maxPanY))$$

---

## 4. 连续性与无弹跳数学证明

### 4.1 满铺维度（Full Dimension）：随 $\_zoom \to 1.0$ 的自然收敛性
以托盘模式横向满铺（$boardSize.x = viewW$）为例：
- 当 $\_zoom = 1.0$ 时，$contentW = viewW$；
- $maxPanX = viewLeft - boardTopLeft.x = 0$；
- $minPanX = viewRight - boardTopLeft.x - viewW = 0$；
- 于是 $minPanX = maxPanX = 0$。

当玩家双指捏合缩小，$\_zoom$ 从 $1.5 \to 1.2 \to 1.05 \to 1.01 \to 1.0$ 渐进变化时：
- $minPanX$ 的变化为：$viewRight - viewLeft - contentW = viewW - boardSize.x \times \_zoom = -boardSize.x \times (\_zoom - 1.0)$；
- 允许平移的区间为 $[-boardSize.x \times (\_zoom - 1.0), 0]$；
- 这是一个随 $\_zoom$ **线性连续单调缩小的闭区间**。在 $1.01x$ 时，允许区间已被压缩到仅几个像素；在 $1.0x$ 时自然收缩为 $[0, 0]$。
- **结论**：缩放到 100% 的整个物理过程中，棋盘平滑自然滑向中心，在 $1.0x$ 触底时已天然处于 $(0, 0)$。**无需任何早退分支，彻底根治弹跳点**。

### 4.2 非满铺维度（Letterbox / 竖图）的双轴连续性
对于非满铺维度（如宽屏上的竖图拼图，初始 $boardSize.x < viewW$）：
1. 在 $\_zoom \le viewW / boardSize.x$（尚未放大到横向满视口）阶段：
   - 该轴走 `contentW < viewW` 单点居中分支；
   - 居中公式：$centerX = viewLeft + \frac{viewW - contentW}{2} - boardTopLeft.x$；
   - 当 $\_zoom = 1.0$ 时，初始布局 $boardTopLeft.x = viewLeft + \frac{viewW - boardSize.x}{2}$，带入得 $centerX = 0$；
   - 当 $\_zoom$ 递增时，$centerX = \frac{boardSize.x \times (1.0 - \_zoom)}{2}$，随 $\_zoom$ 连续平滑向两侧等比外扩，保持居中锁定。
2. 当 $\_zoom = viewW / boardSize.x$（临界阈值点）：
   - $contentW = viewW$；
   - $maxPanX = viewLeft - boardTopLeft.x = \frac{boardSize.x \times (1.0 - \_zoom)}{2} = centerX$；
   - $minPanX = maxPanX = centerX$。
   - **结论**：在临界点处，$minPanX$、$maxPanX$ 与居中点 $centerX$ **三值严格重合，左极限等于右极限，处处连续无跳跃**。跨过临界后自然获得平移自由度。

---

## 5. 核心代码落地设计

### 5.1 待修改文件：`lib/game/jigsaw_puzzle_game.dart`
将现有的 `_clampPanOffset()` 方法彻底重构如下：

```dart
  /// 视口贴边包裹模型 (Viewport Containment - v1.1 终版)：
  /// 1. 彻底移除 setZero() 早退：1.0x 及以下完全由几何约束自动收敛居中，根治未松手弹跳；
  /// 2. 坐标系基准统一：双模式均对齐 _sideMargin 与 _topToolbarHeight，杜绝钻入 AppBar；
  /// 3. 单点退化与浮点防御：content < view 时自然收缩为 min==max==center，并用 min/max 防御 ArgumentError。
  void _clampPanOffset() {
    const eps = 1e-6;

    final normMinX = isTabletop ? -0.35 : 0.0;
    final normMaxX = isTabletop ? 1.35 : 1.0;
    final normMinY = isTabletop ? -0.35 : 0.0;
    final normMaxY = isTabletop ? 1.35 : 1.0;

    // 视口矩形：双模式统一对齐 _computeLayout 基准坐标系
    final viewLeft = _sideMargin;
    final viewRight = size.x - _sideMargin;
    final viewTop = _topToolbarHeight;
    final viewBottom = isTabletop ? size.y - 8.0 : trayPosition.y - 8.0;

    final viewW = max(0.0, viewRight - viewLeft);
    final viewH = max(0.0, viewBottom - viewTop);

    final contentW = (normMaxX - normMinX) * boardSize.x * _zoom;
    final contentH = (normMaxY - normMinY) * boardSize.y * _zoom;

    // 水平维度 (X)：内容超视口则贴边 clamp；内容窄于视口则退化为单点居中
    double minPanX, maxPanX;
    if (contentW + eps >= viewW) {
      maxPanX = viewLeft - boardTopLeft.x - normMinX * boardSize.x * _zoom;
      minPanX =
          viewRight - boardTopLeft.x - normMinX * boardSize.x * _zoom - contentW;
    } else {
      final centerX = viewLeft +
          (viewW - contentW) / 2 -
          boardTopLeft.x -
          normMinX * boardSize.x * _zoom;
      minPanX = maxPanX = centerX;
    }
    _panOffset.x =
        _panOffset.x.clamp(min(minPanX, maxPanX), max(minPanX, maxPanX));

    // 垂直维度 (Y)：内容超视口则贴边 clamp；内容矮于视口则退化为单点居中
    double minPanY, maxPanY;
    if (contentH + eps >= viewH) {
      maxPanY = viewTop - boardTopLeft.y - normMinY * boardSize.y * _zoom;
      minPanY =
          viewBottom - boardTopLeft.y - normMinY * boardSize.y * _zoom - contentH;
    } else {
      final centerY = viewTop +
          (viewH - contentH) / 2 -
          boardTopLeft.y -
          normMinY * boardSize.y * _zoom;
      minPanY = maxPanY = centerY;
    }
    _panOffset.y =
        _panOffset.y.clamp(min(minPanY, maxPanY), max(minPanY, maxPanY));
  }
```

---

## 6. 测试与全方位回归验证方案

### 6.1 单元测试新增（`test/game_layout_test.dart`）
按长宽比解耦构造确定性测试：
1. **横向满铺棋盘贴边与防甩出**：
   - 构造 1:1 棋盘（横向满铺 400x800 视口），放大至 2.0x；
   - 暴力向右平移 1000px，断言棋盘左边 `normalizedToScreen(0,0).x` 严密贴止在 `viewLeft (8.0)`；
   - 暴力向左平移 1000px，断言棋盘右边 `normalizedToScreen(1,0).x` 严密贴止在 `viewRight (392.0)`。
2. **多级缩小平滑渐进收敛（无弹跳验证）**：
   - 在带偏移状态下逐步缩小：`1.5x -> 1.2x -> 1.05x -> 1.01x -> 1.0x`；
   - 断言 `_panOffset` 绝对值单调递减；
   - 在 `1.01x` 时偏移已被压缩至几个像素内，在 `1.0x` 时平滑收缩到 0，绝无突发跳变。
3. **竖图/非满铺维度居中锁定**：
   - 构造竖向长方形拼图，放大初期水平维度窄于屏宽，断言左右外边距严格对称对齐。
4. **全量回归验证**：
   - 运行全量 `flutter test`，确保现有的所有游戏状态、拖拽吸附、撤销快照等核心测试用例 100% 通过。

### 6.2 编译与代码质检
- 格式化：对改动 Dart 文件执行 `dart format`；
- 静态分析：执行 `flutter analyze` 确保 0 警告 0 错误；
- 编译验证：执行 `flutter build windows --debug` 确保桌面端编译无误。
