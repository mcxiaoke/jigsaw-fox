# 桌面散落模式（Tabletop Mode）碎片越界丢件与缩放漫游受限问题剖析及系统修复方案

- **日期**：2026-09-03
- **版本**：v1.1（吸收专业技术评审意见闭环修订版）
- **模块**：游戏引擎 / 碎片交互与视口系统 (`lib/game/jigsaw_puzzle_game.dart`)

---

## 0. 版本修订记录（v1.0 -> v1.1）

响应代码级专业评审意见，v1.1 进行如下关键闭环修订：
1. **【澄清视角重置机制】**：明确 `resetZoom()` 是瞬间将镜头缩放与平移置位为 1.0x（无镜头插值补间），而平滑视觉效果由每个碎片的 `p.animateTo(targetPos, duration: 0.25)` 补间动画提供；
2. **【修正 safeMaxY 笔误】**：草案 4.1 中托盘模式下界修正为 `trayPosition.y - 8.0`，杜绝棋盘散落碎片滑入托盘遮挡区；
3. **【明确 8px vs 44px 顶线设计意图】**：显式阐明视口顶线 `8px`（物理工具栏高度）与散落/拖拽安全顶线 `44px`（避让返回/提示/计时器等操作栏热区）的 36px 缓冲设计约定；
4. **【补充松手落地二次收敛】**：在 `handlePieceDragEnd` 固化归一化坐标前增加防御性二次安全区 clamp，防御系统级手势中断等边缘路径；
5. **【明确测试契约升级清单】**：登记 `test/game_layout_test.dart:1359`（原基于旧常数 `-0.35` 断言）等受影响测试，并在实施中同步升级为动态契约。

---

## 1. 问题背景与现状痛点

在体验拼图游戏的**桌面散落模式（Tabletop Mode，即无底栏托盘、碎片全屏环形散落桌面）**时，存在以下三个严重破坏玩家游戏体验的核心交互缺陷：

### 痛点 1：碎片可被拖到屏幕外丢件（“离屏幽灵”）
- **现象**：在 1.0x（未缩放）初始状态下，全部碎片最初整齐排列在屏幕可见范围内。但玩家拖拽碎片时，可以将碎片一路拖到屏幕可视区域之外并松手放下；
- **后果**：松手后碎片停留在屏幕外的虚空坐标，肉眼彻底看不见，手指也无法点击交互。除非点击右上角扫把（一键整理）打乱重置，否则该碎片永久“失踪”，拼图无法通关。

### 痛点 2：放大后视口漫游范围极窄，初始可见碎片变成不可触达盲区
- **现象**：在桌面模式下双指放大拼图后，玩家单指平移棋盘大桌面的可移动范围极其狭窄（尤其是在较小棋盘场景下，垂直方向 Y 轴甚至被完全锁死无法上下拖动）；
- **后果**：在 1.0x 初始布局下原本清晰可见的四周外围散落碎片，随着画布放大被等比推到了屏幕视野盲区；而因为视口漫游范围严重受限，玩家**无法将视口移动到碎片所在位置**，大量碎片既看不见也够不到。

### 痛点 3：放大后点击扫把（一键整理）失效
- **现象**：在放大状态下，玩家发现碎片找不到了，尝试点击扫把；
- **后果**：扫把执行后，碎片没有出现在当前视野内，反而被重新计算并散落到了距离当前视野更遥远的盲区之外，用户体感“点扫把没有任何效果、甚至碎片全没了”。

---

## 2. 代码级与数学级根因剖析

### 2.1 痛点 1 根因：碎片拖拽与松手完全缺失安全区约束
查看 `lib/game/jigsaw_puzzle_game.dart` 的光标跟随与松手逻辑：

```dart
// updateHoldingPiecePosition (984行)
final targetX = cursorCanvasPos.x - _holdingAnchorX * primary.size.x * currentScale;
final targetY = cursorCanvasPos.y - _holdingAnchorY * primary.size.y * currentScale;
primary.position.setValues(targetX, targetY);

// handlePieceDragEnd (1611行)
final updatedPieces = _boardState.pieces.map((p) {
  final comp = _pieces[p.id];
  _screenToNormalized(comp.position, out); // 直接将屏幕位置转归一化并固化
  return p.copyWith(nx: out[0], ny: out[1]);
});
```

- **问题**：`comp.position` 完全裸露跟随 `cursorCanvasPos`。当用户手指滑动至屏幕边缘以外、或者在屏幕外边缘抬手释放时，`comp.position` 会直接被赋上负数坐标（如 `x = -150`）或超屏坐标（如 `y = 1200`）；
- 托盘模式下有托盘吸附作为兜底（拖到下方会自动 dock 进托盘），而桌面模式下碎片没有任何空间兜底，直接留在屏幕外；
- 引擎自带的 `missingPieceCheck()` 只在 `unsolved.length <= 2`（整幅拼图只剩最后 2 块）时才会将离屏碎片弹回，而在游戏正常游玩期间完全不生效，导致碎片彻底丢失。

---

### 2.2 痛点 2 根因：桌面平移边界硬编码 `[-0.35, 1.35]`，严重脱离竖屏散落实际范围

在 `_getTabletopScatterSlots` 算法中，碎片是**全屏环形散落**的：
- 横向覆盖：$px \in [8.0, \text{size.x} - \text{pieceSize.x} - 8.0]$；
- 纵向覆盖：$py \in [44.0, \text{size.y} - \text{pieceSize.y} - 8.0]$。

在常见竖屏移动设备（如 $392 \times 800$ 或 $412 \times 915$）上，棋盘为保持长宽比通常拟合为正方形（例如 $220 \times 220$），放置在屏幕正中央：
- 棋盘中心：$boardTopLeft.y \approx 298$；
- 顶部外围散落槽位：$py = 44.0 \implies ny = \frac{44.0 - 298}{220} \approx \mathbf{-1.15}$；
- 底部外围散落槽位：$py = 730.0 \implies ny = \frac{730.0 - 298}{220} \approx \mathbf{+1.64 \sim 1.96}$。

**实际的桌面散落范围纵向达到了 $[-1.15, 1.96]$！**

然而，在 `_clampPanOffset()` 中，桌面模式的归一化边界被写死了固定常数：
```dart
final normMinY = isTabletop ? -0.35 : 0.0;
final normMaxY = isTabletop ? 1.35 : 1.0;
```

#### 死锁与漫游受限推导：
1. **小棋盘场景（如 220px 棋盘）**：
   - 代码误以为桌面内容的高度只有：
     $$contentH = (1.35 - (-0.35)) \times boardSize.y \times \_zoom = 1.7 \times 220 \times 2.0 = 748\text{px}$$
   - 实际视口高度为：
     $$viewH = size.y - 16 = 800 - 16 = 784\text{px}$$
   - 因为 $contentH (748) < viewH (784)$，代码判定“内容高度小于视口高度，强制在垂直方向锁定居中”：
     ```dart
     } else {
       final centerY = viewTop + (viewH - contentH) / 2 - ...;
       minPanY = maxPanY = centerY; // 最小平移与最大平移完全相等！
     }
     ```
   - **结果**：在 2.0x 放大下，**垂直 Y 轴平移自由度为 0，完全无法上下拖动**！顶部 $ny \approx -1.15$ 和底部 $ny \approx 1.64$ 的碎片被推入视野盲区且无法触达。
2. **大棋盘场景（如 300px 棋盘）**：
   - $contentH = 1.7 \times 300 \times 2.0 = 1020\text{px} > 784\text{px}$，虽不锁死，但可漫游区间仅 $1020 - 784 = 236\text{px}$，远低于全屏漫游所需的 $784\text{px}$，仍然有大量顶部与底部散落碎片无法触达。

---

### 2.3 痛点 3 根因：放大状态下扫把将碎片散布至 2.0x 空间，拉大了盲区

查看 `organizeTray()` 逻辑：
```dart
final slotPos = slots[slotIdx % slots.length];
final baseNx = (slotPos.x - boardTopLeft.x) / boardSize.x;
final baseNy = (slotPos.y - boardTopLeft.y) / boardSize.y;

p.scale.setAll(_zoom);
final targetPos = _normalizedToScreen(baseNx, baseNy);
p.animateTo(targetPos, duration: 0.25);
```
- `slotPos` 是在 1.0x 全屏视口上计算的绝对槽位；
- 换算成 `(baseNx, baseNy)` 后，调用 `_normalizedToScreen` 时又将其乘以了当前的 `_zoom`（如 2.0x）；
- 结果：扫把直接把碎片散布到了扩大 2 倍的虚空之中（距离屏幕中心 2 倍远）；
- 由于痛点 2 的平移限制，玩家在当前屏幕里根本看不到这些被弹到九霄云外的碎片，体验上等同于“扫把把碎片变没了”。

---

## 3. 系统化治理方案设计

针对以上三个根因，方案从三个相互协同的维度进行系统化重构：

```
+-------------------------------------------------------------------------------+
|  大桌面全景 (Tabletop Full Viewport)                                          |
|                                                                               |
|  [安全顶边缘 y = 44px (避让 AppBar / 返回 / 提示 / 计时)]                     |
|  +-------------------------------------------------------------------------+  |
|  |  散落槽位 A           散落槽位 B           散落槽位 C                   |  |
|  |                                                                         |  |
|  |               +-------------------------------------+                   |  |
|  |  散落槽位 D   |           中央拼图棋盘              |    散落槽位 E     |  |
|  |               +-------------------------------------+                   |  |
|  |                                                                         |  |
|  |  散落槽位 F           散落槽位 G           散落槽位 H                   |  |
|  +-------------------------------------------------------------------------+  |
|  [安全底边缘 y = size.y - 8px]                                                |
|                                                                               |
|  * 方案 1：碎片拖拽与松手无论何时均被限制在此安全框内，严禁出界丢件           |
|  * 方案 2：视口平移范围动态按大桌面 1.0x 全景推导，2x 放大时可纵向漫游整屏   |
|  * 方案 3：放大时点击扫把自动 resetZoom() 回到 1.0x 全景一览无余              |
+-------------------------------------------------------------------------------+
```

---

### 3.1 方案 1：碎片全生命周期视口边界约束（Safe Containment）

**设计原则**：碎片（无论单块碎片、还是已拼接在一起的多块集群）在任何时刻，其**外接包围盒必须 100% 完整保留在屏幕可视安全区内**。

#### A. 拖拽实时安全限位（`updateHoldingPiecePosition`）
当拖拽主碎片 `primary` 时，其携带的集群整体形成一个逻辑包围盒（注：当前游戏未开启旋转机制，`rot == 0`，正交包围盒数学严格成立）：
- 设集群相对于 `primary` 的最小/最大行列相对偏移为：
  - $\Delta col_{min} = \min(p.c - primary.c), \quad \Delta col_{max} = \max(p.c - primary.c)$
  - $\Delta row_{min} = \min(p.r - primary.r), \quad \Delta row_{max} = \max(p.r - primary.r)$
- 集群物理尺寸外延偏移：
  - $leftOffset = \Delta col_{min} \times pieceW \times scale$
  - $rightOffset = (\Delta col_{max} + 1) \times pieceW \times scale$
  - $topOffset = \Delta row_{min} \times pieceH \times scale$
  - $bottomOffset = (\Delta row_{max} + 1) \times pieceH \times scale$
- 对计算出的 `targetX` 和 `targetY` 进行安全钳位：
  - $safeMinX = _sideMargin - leftOffset$
  - $safeMaxX = size.x - _sideMargin - rightOffset$
  - $safeMinY = 44.0 - topOffset$（顶部 $44\text{px}$ 避让返回、提示、计时器等操作栏）
  - $safeMaxY = (isTabletop ? size.y - 8.0 : trayPosition.y - 8.0) - bottomOffset$（**托盘模式严格以托盘顶部为下界，绝不遮挡托盘**）
  - $targetX = targetX.\text{clamp}(\min(safeMinX, safeMaxX), \max(safeMinX, safeMaxX))$
  - $targetY = targetY.\text{clamp}(\min(safeMinY, safeMaxY), \max(safeMinY, safeMaxY))$

**效果**：玩家即便把手指快速划出手机边缘，碎片集群也会丝滑严密贴在屏幕内边缘，绝不跟随光标滑出视野。

#### B. 松手释放安全兜底（`handlePieceDragEnd`）
在松手释放碎片时，防御性校验其位置。若发生极端异常（例如手势被 Android 系统手势强行中断、多点触控抢占），若碎片包围盒超出视口安全区，自动将其位置 clamp 回可视区域内，确保写回 `_boardState` 的归一化坐标绝对在视口有效视野内。

---

### 3.2 方案 2：桌面视口大桌面全景自适应漫游（Dynamic Tabletop Viewport）

**设计原则**：在桌面模式下，视口承载的内容不是“孤立的棋盘”，而是**由棋盘与全部散落槽位组成的“大桌面全景”**。

#### A. 动态归一化边界建模
在 1.0x 状态下，大桌面的自然可视范围恰好由视口 `[viewLeft, viewTop, viewRight, viewBottom]` 决定。因此，桌面的真实归一化边界不是硬编码的 `-0.35`，而是**视口边缘相对棋盘的真实反算值**：

```dart
final normMinX = isTabletop ? (viewLeft - boardTopLeft.x) / boardSize.x : 0.0;
final normMaxX = isTabletop ? (viewRight - boardTopLeft.x) / boardSize.x : 1.0;
final normMinY = isTabletop ? (viewTop - boardTopLeft.y) / boardSize.y : 0.0;
final normMaxY = isTabletop ? (viewBottom - boardTopLeft.y) / boardSize.y : 1.0;
```

> **关于 8px (`viewTop`) 与 44px (`safeMinY`) 的设计约定**：
> 视口计算采用物理顶栏高度 `8.0px`，散落槽位与拖拽限制在 `44.0px` 之下。该 36px 缓冲确保了当 2.0x 漫游到最顶端时，最顶部的碎片不会与顶部操作按钮紧贴，留有充足的呼吸空间与操作防误触间距。

#### B. 数学收敛性与漫游能力验证
1. **在 1.0x 状态下**：
   - $contentW = (normMaxX - normMinX) \times boardSize.x \times 1.0 = viewRight - viewLeft = viewW$；
   - $contentH = (normMaxY - normMinY) \times boardSize.y \times 1.0 = viewBottom - viewTop = viewH$；
   - $minPanX = maxPanX = 0, \quad minPanY = maxPanY = 0$；
   - **结论**：1.0x 下视口平移严格为 0，大桌面完美贴屏，全景尽收眼底，双指缩放回 1.0x 时绝对平滑无弹跳！
2. **在 2.0x 放大状态下**：
   - $contentW = 2.0 \times viewW, \quad contentH = 2.0 \times viewH$；
   - 水平允许漫游区间宽度：$maxPanX - minPanX = contentW - viewW = \mathbf{1.0 \times viewW}$（整整一屏宽！）；
   - 垂直允许漫游区间宽度：$maxPanY - minPanY = contentH - viewH = \mathbf{1.0 \times viewH}$（整整一屏高！）；
   - **结论**：Y 轴垂直平移彻底完全解锁！当漫游到最顶端时，最顶部的散落碎片恰好进入屏幕上沿；漫游到最底端时，最底部的散落碎片恰好进入屏幕下沿。**1.0x 时可见的每一块碎片，在 2.0x 放大后 100% 能够平移触达并操作！**

---

### 3.3 方案 3：扫把（一键整理）在放大状态下的“全景总览回退”

**用户心理诉求**：玩家点击扫把，是为了“一键把所有散乱碎片理整齐，理清全局思路”。如果在 2.0x 放大下直接重排，局部视野里无论如何也放不下几十块碎片，必然只能散到视野外。

**交互规则设计**：
在桌面模式下执行 `organizeTray()` 时：
- 若当前处于放大状态（`_zoom > 1.0`）：
  1. 调用 `resetZoom()` 将镜头缩放与平移瞬间置回 1.0x 全景总览；
  2. 全部散落碎片在接下来的 `0.25s` 内平滑飞回其在全景大桌面中的标准槽位；
- 若当前已处于 1.0x 状态：
  直接平滑归位槽位。

**效果**：点击扫把瞬间，视野瞬时拉回“全局上帝视角”，随后所有碎片在 0.25s 内整齐归位列阵，玩家瞬间重新掌控全局，心智模型极度清晰统一。

---

## 4. 实施代码设计

### 4.1 核心改动 1：`updateHoldingPiecePosition`（碎片拖拽防出界）
位于 `lib/game/jigsaw_puzzle_game.dart`：

```dart
    // 2. 计算集群的外延偏移，确保整体绝不拖出屏幕边界
    var minCol = 0, maxCol = 0, minRow = 0, maxRow = 0;
    final clusterPieces = _pieces.values.where(
      (p) => p.clusterId == primary.clusterId && p != primary,
    );
    for (final p in clusterPieces) {
      final relC = p.c - primary.c;
      final relR = p.r - primary.r;
      if (relC < minCol) minCol = relC;
      if (relC > maxCol) maxCol = relC;
      if (relR < minRow) minRow = relR;
      if (relR > maxRow) maxRow = relR;
    }

    final clusterLeftOffset = minCol * primary.size.x * currentScale;
    final clusterRightOffset = (maxCol + 1) * primary.size.x * currentScale;
    final clusterTopOffset = minRow * primary.size.y * currentScale;
    final clusterBottomOffset = (maxRow + 1) * primary.size.y * currentScale;

    // 安全边界限位：四周预留 8px，顶部预留 44px 避让返回/提示等操作栏；托盘模式严格以托盘顶部为界
    final safeMinX = _sideMargin - clusterLeftOffset;
    final safeMaxX = size.x - _sideMargin - clusterRightOffset;
    final safeMinY = 44.0 - clusterTopOffset;
    final safeMaxY = (isTabletop ? size.y - 8.0 : trayPosition.y - 8.0) - clusterBottomOffset;

    final rawTargetX =
        cursorCanvasPos.x - _holdingAnchorX * primary.size.x * currentScale;
    final rawTargetY =
        cursorCanvasPos.y - _holdingAnchorY * primary.size.y * currentScale;

    final targetX = rawTargetX.clamp(min(safeMinX, safeMaxX), max(safeMinX, safeMaxX));
    final targetY = rawTargetY.clamp(min(safeMinY, safeMaxY), max(safeMinY, safeMaxY));

    primary.clearActiveEffects();
    primary.scale.setAll(currentScale);
    primary.position.setValues(targetX, targetY);
```

### 4.2 核心改动 2：`_clampPanOffset`（大桌面自适应动态漫游）
位于 `lib/game/jigsaw_puzzle_game.dart`：

```dart
    final viewLeft = _sideMargin;
    final viewRight = size.x - _sideMargin;
    final viewTop = _topToolbarHeight;
    final viewBottom = isTabletop ? size.y - 8.0 : trayPosition.y - 8.0;

    // 关键优化：桌面模式下归一化边界基于大桌面全景动态自适应推导，彻底废除硬编码 [-0.35, 1.35]
    final normMinX = isTabletop ? (viewLeft - boardTopLeft.x) / boardSize.x : 0.0;
    final normMaxX = isTabletop ? (viewRight - boardTopLeft.x) / boardSize.x : 1.0;
    final normMinY = isTabletop ? (viewTop - boardTopLeft.y) / boardSize.y : 0.0;
    final normMaxY = isTabletop ? (viewBottom - boardTopLeft.y) / boardSize.y : 1.0;

    final viewW = max(0.0, viewRight - viewLeft);
    final viewH = max(0.0, viewBottom - viewTop);

    final contentW = (normMaxX - normMinX) * boardSize.x * _zoom;
    final contentH = (normMaxY - normMinY) * boardSize.y * _zoom;
```

### 4.3 核心改动 3：`organizeTray`（桌面模式放大状态下一键全景回退）
位于 `lib/game/jigsaw_puzzle_game.dart`：

```dart
    if (isTabletop) {
      if (_zoom > 1.0) {
        resetZoom(); // 放大状态下点击扫把，瞬时复位至 1.0x 全景总览
      }
      final slots = _getTabletopScatterSlots(totalPieces);
      ...
```

---

## 5. 受影响单测清单与升级说明

| 测试用例位置 | 原测试契约 | 升级调整说明 |
|---|---|---|
| `test/game_layout_test.dart:1359` | 断言 `normalizedToScreen(0, -0.35).y == 8.0`（锚定旧常数） | 改为断言大桌面顶沿（对应动态 `normMinY`）在放大平移后精确贴合 `viewTop (8.0)` |
| `test/game_layout_test.dart`（新增） | 无拖拽防出界单测 | 增加：暴力将单片及多片集群拖拽至屏幕四角，断言外接包围盒严格限制在 `[8, size.x-8]` 与 `[44, size.y-8]` |
| `test/game_layout_test.dart`（新增） | 无桌面模式 2x 漫游全覆盖单测 | 增加：2.0x 放大下向四周极值漫游，断言最顶端与最底端槽位均可完整进入屏幕视口 |
| `test/game_layout_test.dart`（新增） | 无桌面模式扫把 resetZoom 单测 | 增加：在 2.0x 放大下调用 `organizeTray()`，断言 `zoom == 1.0` 且所有碎片坐标均在视口安全区内 |
