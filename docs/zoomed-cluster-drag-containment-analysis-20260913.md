# 棋盘放大状态下拼合碎片组无法移出可视区域且自动弹回中央问题分析报告

- **日期**：2026-09-13
- **模块**：游戏引擎 / 碎片交互与安全限位系统 (`lib/game/jigsaw_puzzle_game.dart`)
- **状态**：问题原因排查与架构方案设计

---

## 1. 问题背景与玩家痛点

在拼图界面中，当玩家将棋盘放大（例如 `_zoom >= 1.5x ~ 3.0x`）进行局部精细拼图时，存在以下破坏核心拼图体验的严重问题：

### 1.1 玩家实际游戏习惯与诉求
1. **局部拼合与暂存习惯**：在高难度或多碎片拼图中，玩家往往会在棋盘局部优先吸附拼好若干个碎片组（例如 2~4 块连在一起的局部边缘、标志性图案组）；
2. **空间腾挪诉求**：当棋盘放大后，屏幕可视窗口（Viewport）相对大棋盘而言较小，视野空间局促。玩家需要把暂时用不到、但已经拼好的碎片组推到屏幕可视区域外边（视野边缘或当前视野外的棋盘空白处暂存），以腾出视野中心继续拼接其他区域。

### 1.2 现状缺陷表现
- **现象 1（出界受阻）**：玩家用手指/鼠标抓取拼好的碎片组向屏幕边缘拖动时，碎片组无法移出屏幕外，直接卡在屏幕边缘；
- **现象 2（自动弹回屏幕中心）**：当碎片组包含多块碎片（或放大倍数较高）时，玩家尝试拖动碎片组，碎片组几乎无法跟手移动，且一旦松手放下，整个碎片组会**瞬间自动弹回屏幕正中央**，严重阻碍正常拼图。

---

## 2. 代码级与数学级根因剖析

经深入追踪引擎代码，该问题由 **视口与世界坐标系概念混淆** 以及 **数学边界倒置 BUG** 两大致命缺陷共同引起：

```
+-----------------------------------------------------------------------------------+
|  大棋盘世界空间 (Board World Space, 随 _zoom 放大，可单指平移漫游)                 |
|                                                                                   |
|         +---------------------------------------+                                 |
|         | 屏幕可视窗口 (Screen Viewport)        |                                 |
|         |                                       |                                 |
|         |    [代码错误施加的视口硬 Clamp 框]     |                                 |
|         |    +-----------------------------+    |                                 |
|         |    |                             |    |                                 |
|         |    |   拼合碎片组 (Cluster)      |    |                                 |
|         |    |   [一旦尺寸 > 视口可用宽高] |    |                                 |
|         |    |   [safeMin > safeMax]       |    |                                 |
|         |    |   [被强制锁死并弹回正中央]  |    |                                 |
|         |    |                             |    |                                 |
|         |    +-----------------------------+    |                                 |
|         |                                       |                                 |
|         +---------------------------------------+                                 |
|                                                                                   |
|  * 玩家诉求：将碎片组移出视口，存放到大棋盘的其他区域                             |
|  * 代码缺陷：强行要求所有碎片每一帧、每个像素都必须被塞在当前物理屏幕内           |
+-----------------------------------------------------------------------------------+
```

---

### 2.1 根因一：安全限位基准错配（使用屏幕物理视口，而非棋盘世界空间）

查看核心拖拽与释放方法：
- 拖拽更新：`updateHoldingPiecePosition` (`lib/game/jigsaw_puzzle_game.dart:1218-1233`)
- 松手结算：`handlePieceDragEnd` (`lib/game/jigsaw_puzzle_game.dart:1935-1958`)

```dart
// 1. 计算集群包围盒偏移
final clusterLeftOffset = minCol * piece.size.x * currentScale;
final clusterRightOffset = (maxCol + 1) * piece.size.x * currentScale;
final clusterTopOffset = minRow * piece.size.y * currentScale;
final clusterBottomOffset = (maxRow + 1) * piece.size.y * currentScale;

// 2. 限制在屏幕可视区域内
final safeMinX = _sideMargin - clusterLeftOffset;
final safeMaxX = size.x - _sideMargin - clusterRightOffset;
final safeMinY = _topToolbarHeight - clusterTopOffset;
final safeMaxY = (isTabletop || clusterPieces.isEmpty
        ? size.y - 8.0
        : trayPosition.y - 8.0) - clusterBottomOffset;

final targetX = rawTargetX
    .clamp(min(safeMinX, safeMaxX), max(safeMinX, safeMaxX))
    .toDouble();
final targetY = rawTargetY
    .clamp(min(safeMinY, safeMaxY), max(safeMinY, safeMaxY))
    .toDouble();
```

#### 历史背景与冲突来源：
- 在 2026-09-03 提交的 Commit (`a5deb7b`) 中，为了解决“桌面散落模式下碎片被甩出屏幕导致丢件（离屏幽灵）”的问题，引入了上述视口包围盒安全约束；
- **设计缺陷**：代码直接将 `size.x` 与 `size.y`（屏幕当前物理视口像素）作为唯一合法边界：
  1. 在 `1.0x` 且棋盘较小时，棋盘完全在视口内，“限制在屏幕内”勉强成立；
  2. 但当**棋盘放大（`_zoom > 1.0`）**后，棋盘在世界空间的像素尺寸为 `boardSize * _zoom`，玩家可以通过单指平移（Pan）漫游整个棋盘，**大棋盘的大量合法区域本来就在当前屏幕可视区域外边**；
  3. 代码却仍然要求碎片组必须严格落在当前的 `[8.0, size.x - 8.0]` 物理视口内，从物理机制上彻底剥夺了碎片离开当前小屏幕的可能。

---

### 2.2 根因二：数学边界倒置 BUG（`safeMinX > safeMaxX`）导致“强制弹回中央”

这是导致用户反馈**“无法向外拖，松手直接弹回中间”**的直接数学原因。

#### 数学推导过程：
设屏幕可用宽度为 $W_{\text{view}} = size.x - 2 \times \_sideMargin$（在竖屏手机或小窗口下约 350px~400px）。

对于吸附好的多块碎片组（Cluster）：
- 碎片组的视觉宽度为：
  $$W_{\text{cluster}} = clusterRightOffset - clusterLeftOffset = (\max(col) - \min(col) + 1) \times pieceSize.x \times \_zoom$$
- 代入上界与下界公式做差：
  $$safeMaxX - safeMinX = (size.x - \_sideMargin - clusterRightOffset) - (\_sideMargin - clusterLeftOffset)$$
  $$safeMaxX - safeMinX = (size.x - 2 \times \_sideMargin) - (clusterRightOffset - clusterLeftOffset) = W_{\text{view}} - W_{\text{cluster}}$$

#### 异常反转与弹回机制：
1. **反转触发**：
   当棋盘处于放大状态（例如 `_zoom = 2.0x`）时，单块碎片放大 2 倍。一个由 3~4 块碎片组成的集群，其视觉宽度 $W_{\text{cluster}}$ 极易达到 450px~600px，必然**大于**视口可用宽度 $W_{\text{view}}$；
   此时：
   $$W_{\text{view}} - W_{\text{cluster}} < 0 \implies \mathbf{safeMinX > safeMaxX}$$
   **下界居然大于上界！**
2. **居中锁死**：
   为了防止 `clamp(min, max)` 在 `min > max` 时抛出 Flutter `ArgumentError`，现有代码做了容错反转：
   ```dart
   .clamp(min(safeMinX, safeMaxX), max(safeMinX, safeMaxX))
   ```
   当 `safeMinX > safeMaxX` 时，该合法区间变为 `[safeMaxX, safeMinX]`。
   我们计算该区间的几何中心点：
   $$\text{Center} = \frac{safeMinX + safeMaxX}{2} = \frac{size.x - (clusterLeftOffset + clusterRightOffset)}{2}$$
   当玩家抓取碎片组的中心块或对称块时，`clusterLeftOffset + clusterRightOffset \approx 0`，该中心点**精确等于 $\frac{size.x}{2}$（即当前屏幕正中央）**！
   由于区间极其狭窄，碎片的 $X$ 坐标被死死钳位在屏幕正中央附近；
3. **松手瞬间弹回**：
   松手时，`handlePieceDragEnd` 内部执行一模一样的防御性 Clamp：
   ```dart
   final clampedX = piece.position.x.clamp(min(safeMinX, safeMaxX), max(safeMinX, safeMaxX));
   if (clampedX != piece.position.x || clampedY != piece.position.y) {
     final dx = clampedX - piece.position.x;
     piece.position.setValues(clampedX, clampedY);
     for (final p in clusterPieces) {
       if (p != piece) p.position.add(Vector2(dx, dy));
     }
   }
   ```
   如果碎片之前因微小位移偏离了中心，松手瞬间该逻辑强制计算偏移量并平移，**导致碎片组被无情弹回屏幕正中央**。

---

### 2.3 根因三：多块吸附集群与单块游离碎片的属性差异被忽视

1. **单块游离碎片**：在托盘模式下可放回底栏托盘；桌面散落模式下散落于四周。为了防止新手无意中大甩手将单片甩丢，设置防丢件保护有一定合理性；
2. **多块吸附集群（Cluster）**：
   - 引擎本身早有设计规范：**多块拼合集群严禁放回托盘，其尺寸全程锁定棋盘缩放比例 `_zoom`**；
   - 碎片组本就是拼图过程中的“半成品组件”，它的天然归属就是棋盘世界坐标系；
   - 将针对单块防丢件的视口硬性铁笼强加在放大状态的多块集群上，完全违背了拼图的自由堆叠与组装逻辑。

---

### 2.4 根因四：交互体验割裂（平移画布能出屏，拖拽碎片不能出屏）

- **平移画布时**：当玩家单指在空白处滑动平移画布时，棋盘上的碎片位置由归一化坐标 `_normalizedToScreen(p.nx, p.ny)` 决定，碎片会顺滑地跟随画布平移到屏幕可视区域之外，没有任何阻碍；
- **拖拽碎片时**：一旦玩家抓起碎片试图挪动它，视口硬 Clamp 强行介入，不仅不允许碎片移出屏幕，甚至如果碎片组较大还会直接吸附在屏幕中间。
- 这种“画布能把它移出去，手指却拖不出去”的现象给玩家带来了强烈的违和感与挫败感。

---

## 3. 改进方案建议

为彻底解决该问题，建议从以下三个维度协同修复：

### 方案 1：限位空间升级（从“视口空间”升级为“棋盘/大桌面世界漫游空间”）
- **未缩放（`_zoom <= 1.0`）单片散落**：保留视口边缘保护（防甩出丢件）；
- **放大状态（`_zoom > 1.0`）或多块集群**：
  将限位边界转换为棋盘/桌面的**世界空间边界**（即有效归一化范围 $nx, ny \in [-0.2, 1.2]$），或者基于当前棋盘展开后的世界坐标 `[boardTopLeft + _panOffset, boardTopLeft + _panOffset + boardSize * _zoom]`；
  允许玩家在放大时，将碎片组拖动并停放到当前视口外的有效棋盘/桌面区域，玩家随时可以通过平移画布重新漫游找回。

### 方案 2：彻底消除 `safeMin > safeMax` 边界倒置 BUG
- 针对大尺寸集群（尺寸超出可用空间），废除当前倒置的强制 Clamp 逻辑；
- 改为保证**光标抓取锚点（Grab Point）处于合法操作区**，而不是强制要求庞大的外接包围盒塞入小窗口中，从根源上杜绝“自动弹回正中央”。

### 方案 3：多块集群生命周期豁免视口拘束
- 多块吸附集群（`clusterPieces.length > 1`）脱离视口物理边界的限制，赋予其在整个大棋盘漫游空间中自由摆放的能力。
