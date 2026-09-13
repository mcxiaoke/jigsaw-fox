# 棋盘放大状态下拼合碎片组拖拽受限与自动回中：原因溯源、结论甄别与修复方案

- **日期**：2026-09-13 13:25 (GMT+8)
- **版本**：v1.0（合并稿）
- **模块**：游戏引擎 / 碎片交互与安全限位系统（`lib/game/jigsaw_puzzle_game.dart`）
- **上游文档**：
  - `docs/zoomed-cluster-drag-containment-analysis-20260913.md`（原始分析，本文逐条甄别）
  - `docs/tabletop-drag-containment-and-zoom-pan-fix-plan-20260903.md`（引入本约束的历史方案 §3.1）
- **引入提交**：`a5deb7b` — fix(game): implement viewport containment, tabletop pan bounds and piece drag constraints（2026-09-03，已用 `git log` 核实）

---

## 0. 本文定位

原始分析给出了**正确的主线结论与修复方向**，但存在 3 处推导错误、1 处方案数值不可用、4 处遗漏触发点。本文：

1. 用可复现的实测数据双向核验（不采信任何一方的推演结论）；
2. 给出精确的量化模型（可移动行程公式），把"感觉卡住"变成可计算量；
3. 修正错误表述，补齐遗漏触发点；
4. 输出可直接实施的修复方案、代码改动清单与测试契约升级清单。

**复现脚本**（本地验证用，`temp/` 已被 `.gitignore` 忽略，不入库）：

- `temp/investigate_zoom_drag_test.dart` — 拖拽落点与限位区间实测
- `temp/verify_doc_claims_test.dart` — 边界扫描、文档公式核验、桌面散落域实测

```
flutter test temp/investigate_zoom_drag_test.dart
flutter test temp/verify_doc_claims_test.dart
```

---

## 1. 问题现象

| 编号 | 现象 |
|---|---|
| 现象 1 | 放大状态下抓取拼合好的碎片组向屏幕边缘拖动，碎片组无法移出屏幕，卡在边缘 |
| 现象 2 | 多块集群几乎不跟手，落点被强行固定；玩家感知为"一松手就弹回屏幕中间" |
| 现象 3 | 单块碎片手感正常，只有**多块集群**出现上述问题 |

---

## 2. 精确模型

### 2.1 约束代码位置

| 环节 | 位置 | 说明 |
|---|---|---|
| 拖拽实时限位 | `updateHoldingPiecePosition()` L1153，clamp 块 L1206–1232 | 偏移 L1206–1209、边界 L1218–1225、clamp L1227–1232 |
| 松手二次限位 | `handlePieceDragEnd()` L1891，偏移 L1918–1933、边界 L1935–1940、clamp L1942–1958 | 并把屏幕坐标反算为归一化坐标写回状态 L1966–1981 |

两处使用**完全相同**的边界公式（`handlePieceDragEnd` 只是用 `piece.scale` 代替 `_zoom`，多块集群下二者同值），因此松手那次 clamp 在绝大多数情况下是**空操作**——碎片在拖拽过程中就已经被钳死，不存在"松手瞬间才弹回"的动画过程。

```dart
final safeMinX = _sideMargin - clusterLeftOffset;
final safeMaxX = size.x - _sideMargin - clusterRightOffset;      // 参照系 = 屏幕视口
final safeMinY = _topToolbarHeight - clusterTopOffset;
final safeMaxY = (isTabletop || clusterPieces.isEmpty
        ? size.y - 8.0 : trayPosition.y - 8.0) - clusterBottomOffset;
final targetX = rawTargetX.clamp(min(safeMinX, safeMaxX), max(safeMinX, safeMaxX));
```

**基准错配**：边界参照系是**屏幕物理视口**（`size`），而包围盒偏移（`clusterLeftOffset/RightOffset`…）含 `× currentScale`（多块集群 = `× _zoom`）。放大后二者尺度脱节。

### 2.2 可移动行程公式（核心结论）

设某轴：

- `usableView` = 该轴可用视口长度（X 轴 = `size.x - 2×8`；Y 轴对称托盘模式 = `trayTop - 8 - 8`）
- `clusterProjection` = 集群在该轴的屏幕投影长度 = `k × pieceSize_axis × zoom`

则：

```
travel = max(0, usableView - clusterProjection)
```

| 情形 | 后果 |
|---|---|
| `travel > 0`（区间未退化） | 碎片可移动，但落点被压在**区间端点**（贴边），不是中点 |
| `travel = 0`（区间退化） | 合法区间收缩为**单点**：落点唯一，且该点**恰好**使集群包围盒中心对齐**可用区中心** |

**为什么"必然"退化**：棋盘在 1.0x 时按视口拟合，故限制轴上 `board_axis ≈ usableView_axis`。代入 `clusterProjection = usableView_axis` 解得 `zoom = n / k`（n = 该轴格数，k = 集群在该轴的格数）。

以 4×4 拼图、2×2 集群为例：`zoom = 4/2 = 2`，而**实测各难度 `maxZoom` 恒为 2.0**（`_maxZoom = max(minZoom=2, maxPieceZoomPx=72 / pieceMaxSide)`，仅当碎片边长 < 36px 即约 26×26 以上的密集盘才会 > 2）。也就是说：

> **2.0 是默认缩放，不是极端场景；而 4×4 盘 + 2×2 集群在 2.0x 下正好精确落在锁死临界点上。**

### 2.3 为什么只有"碎片组"出问题

| 类型 | 拖拽期缩放 | 包围盒 | 实测 travel（1200×800，4×4） |
|---|---|---|---|
| 单块碎片（托盘模式） | 平滑过渡至 `_trayPieceScale`（64px） | 小 | X 1120px / Y 720px ✅ 完全够用 |
| 多块集群 | **强制锁定 `_zoom`**（L1169–1170，因集群不可回托盘） | 按 zoom 膨胀 | 2×2 → X 536px / **Y 0px** ❌ |

单块 travel = `usableView - 64 - 边距`，实测 1200×800 下 X 1120 = 1184−64 ✅、392×800 下 X 312 = 376−64 ✅，公式精确吻合。

**结论**：单块碎片因拖拽时缩小到托盘尺寸而始终有充足移动空间；多块集群被锁定棋盘缩放，包围盒按 zoom 膨胀后吃光全部可用空间。这正是"只有碎片组卡死"的根因。

### 2.4 与平移行为的一致性割裂

`_updateBoardTransform()`（L1554）按归一化坐标 `_normalizedToScreen(nx, ny)` 重算位置，且**跳过 `isDragging` 的碎片**。因此：

- **平移画布**时：非拖拽碎片随画布一起移动到屏幕外，不受任何限制；
- **拖拽碎片**时：同一枚碎片却被禁止移出屏幕。

同一枚碎片、同一时刻，"画布能把它移出去、手指却拖不出去"，这是玩家违和感的直接来源，也说明视口铁笼并非必要的物理约束。

---

## 3. 实测证据

环境：托盘模式（默认 `scatterMode`），`zoom = maxZoom = 2.0`。

### 3.1 可移动行程扫描（4×4 拼图）

光标全屏均匀扫描（13×13 采样），记录主片落点跨度：

| 窗口 | 棋盘 | 单块投影 | 2×2 集群投影 | 2×2 travel X/Y | 3×3 集群投影 | 3×3 travel X/Y |
|---|---|---|---|---|---|---|
| 392×800 | 376 | 188 | 376 | **0** / 272 px | 564 | 102 / 84 px |
| 800×600 | 448 | 224 | 448 | 336 / **0** px | 672 | 112 / 120 px |
| 1200×800 | 648 | 324 | 648 | 536 / **0** px | 972 | 212 / 170 px |
| 1920×1080 | 928 | 464 | 928 | 976 / **0** px | 1392 | 512 / 240 px |

- 加粗 `0` = 该轴**完全锁死**（区间退化为单点）；
- 2×2 集群在全部 4 种窗口下至少有一轴锁死：宽度受限窗口（手机竖屏）锁 X，高度受限窗口（宽屏）锁 Y；
- 非退化轴的 travel 与公式 `usableView - clusterProjection` 吻合，最大偏差不超过光标采样步长：1920×1080 下 `1904 − 928 = 976` 精确相等；392×800 下 Y 轴实测 272 vs 理论 280，差值为 66.7px 采样步长所致。

### 3.2 落点横扫细节（3×3 拼图 @1200×800，2×2 集群 864×864）

| 轴 | 合法区间（有序后） | 是否退化 | 落点特征 |
|---|---|---|---|
| X | `[8, 328]`（宽 320） | 否 | 光标 550→1150（12 档中 6 档）落点**恒为 328** |
| Y | `[-208, 8]`（宽 216） | **是** | 光标 250→750（8 档中 6 档）落点**恒为 8** |

集群包围盒中心可达范围：X `[440, 760]`（屏幕中心 600）、Y `[266, 440]`（**可用区中心 332**）。

> 即：集群只能在一个很窄的区间内滑动，其包围盒中心始终跨在可用区中心附近 —— 这就是玩家感知为"弹回中间"的真实机制。

### 3.3 桌面散落模式的真实归一化域（4×4，tabletop）

| 窗口 | 棋盘 | nx 范围 | ny 范围 | 落在 `[-0.2, 1.2]` 之外 |
|---|---|---|---|---|
| 400×800 | 212 | `[-0.41, 1.06]` | `[-1.20, 1.73]` | **12 / 16** |
| 1200×800 | 453 | `[-0.78, 1.43]` | `[-0.30, 0.82]` | **15 / 16** |
| 1920×1080 | 636 | `[-0.96, 1.60]` | `[-0.29, 0.83]` | **16 / 16** |

（散落槽位在 `_getTabletopScatterSlots()` L862 中按**屏幕空间**生成，L878–905 的边界为 `[8, size.x-8]` / `[44, size.y-8]`，反算成归一化后随窗口尺寸大幅波动。）

### 3.4 视口平移的锁死点

1920×1080、3×3、zoom 2、棋盘 928：`content = 1856`，`viewW = 1904`，`viewH = 928`。

`panBy(5000, -5000)` 后 `pan = (-464, -928)`：**X 轴恒为单点 -464**（`contentW < viewW`，退化居中，`_clampPanOffset` L1450–1457），Y 轴正常可漫游。

---

## 4. 对原始分析的甄别结论

### 4.1 成立（可直接采信）

| 论断 | 核验方式 | 结论 |
|---|---|---|
| 提交 `a5deb7b`（2026-09-03）引入该约束 | `git log --format` | ✅ 完全吻合 |
| 根因一：限位基准使用屏幕视口而非棋盘世界空间 | 代码 + 独立实测 | ✅ 成立 |
| 根因二：`safeMin > safeMax` 区间倒置 | 公式复核 + 实测 | ✅ 成立，且**中点公式推导本身正确** |
| 根因三：多块集群尺寸全程锁 `_zoom`、不可回托盘 | 代码 L1164–1170 + 实测 2.3 节 | ✅ 成立，且这是"只有集群出问题"的直接原因 |
| 根因四：画布能平移出屏、拖拽不能，体验割裂 | `_updateBoardTransform` L1554–1577 | ✅ 成立，论证力最强 |
| 方案 2：改为只约束"抓取锚点"而非整个包围盒 | 数学验证（见 5.2） | ✅ 方向正确，可彻底消除退化 |
| 方案 3：多块集群豁免视口拘束 | — | ✅ 与方案 1 同向，可合并 |

### 4.2 需要修正（3 处）

**修正 1：「自动弹回屏幕正中央」的机制描述不准确。**

- 不存在回弹动画；拖拽过程中即被持续硬钳位，松手 clamp 基本是空操作。
- "落在中点"只在**区间退化为单点**时成立（此时 travel = 0，落点唯一且恰好居中）。
- 区间未退化时，落点被压在**区间端点**（贴边），不是中点。实测 3×3 集群 Y 区间 `[-208, 8]` 未退化为点，落点是端点 `8`。

**修正 2：「`clusterLeftOffset + clusterRightOffset ≈ 0`」这一条件写错。**

对称集群下该和等于**一个碎片宽**（`minCol = -a, maxCol = a → L + R = pieceW`），不为 0。正确的判据是：

> 主片位于区间中点 ⇒ 集群包围盒中心 = 屏幕中心（X 轴）。

即"结论对、论据自相矛盾"。实测佐证：3×3 集群 `midX = 168 → 包围盒中心 168 + 432 = 600 = 屏幕中心` ✅。

**修正 3：Y 轴的"正中央"不是屏幕正中。**

- 可用区 Y = `[8, trayTop-8]`，中心 = **332**；屏幕中心 = **400**（相差 68px）。
- X 轴因左右边距对称（`[8, size.x-8]`）才恰好等于屏幕中心。
- 实测 `midY = -100 → 包围盒中心 332`，与可用区中心一致，而非 400。

**附带修正：zoom 范围表述。** 原文"1.5x ~ 3.0x"不准确；实测各难度 `maxZoom` 恒为 2.0，**2.0x 就是默认场景**。

### 4.3 方案数值不可用（1 处）

**方案 1 给出的 `nx, ny ∈ [-0.2, 1.2]` 不能采用。** 该区间系凭空指定，与桌面散落实际域严重不符：实测三种窗口下分别有 12/16、15/16、**16/16** 的散落碎片落在此区间之外（3.3 节）。若按此实现，桌面散落模式会退化为"一拖就被强行拉回"。

**合法域必须按模式从几何反算**（见 5.1），不能使用常数。

### 4.4 遗漏（4 处）

| # | 遗漏点 | 位置 | 影响 |
|---|---|---|---|
| 1 | 窗口尺寸变化路径 | `_syncResizeTransform()` L421，`_setZoom(1)` + `_panOffset.setZero()` L423–424，游离碎片收拢 L470–568 | 窗口尺寸变化会二次弹回，且把用户缩放清成 1.0（丢失缩放状态） |
| 2 | 最后两块的"防丢自检" | `missingPieceCheck()` L2485，搬运目标 L2514–2532 | 剩 ≤2 块时把越界碎片**直接搬到屏幕正中** `(size.x-visualW)/2` —— 这才是字面意义的"弹回中间"，与本次根因独立存在 |
| 3 | 平移可达域的单点锁死 | `_clampPanOffset()` L1450–1457、L1473–1480 | 约束"合法域 ⊆ 平移可达域"的成因；本例中该锁死本身无害（该轴内容全部可见），但它决定了修复方案必须显式校验二者包含关系 |
| 4 | 测试契约未提及 | `test/game_layout_test.dart:1403`、`:873`、`:1033` | 旧断言明确锁定"拖出屏幕必须被拉回"，方案落地必须同步升级，否则改动直接红 |

### 4.5 本文对上一轮口头分析的自我修正

上一轮口头结论称"`minZoom = 2`，所以游戏中看到的永远是局部"——**这是错误的**。`minZoom` 是"`maxZoom` 的最小保证值"（见 L146–154 注释），**不是缩放下限**；实际 `zoom ∈ [1.0, _maxZoom]`。因此原始分析以 `_zoom > 1.0` 作为分级界线是可行的。

---

## 5. 修复方案

### 5.0 设计原则

| 编号 | 原则 |
|---|---|
| P1 | 约束对象从"整簇包围盒"改为"**抓取锚点**"，从数学上根除区间退化 |
| P2 | 保留"防甩丢"的原始意图：抓取点恒在可视区 ⇒ 碎片**永不完全消失**、随时可再次抓取 |
| P3 | 允许集群主体移出视口，满足"腾挪"诉求（本次用户核心痛点） |
| P4 | 任何新增的合法域都必须满足 **合法域 ⊆ 平移可达域**，否则出现"拖出去找不回" |
| P5 | 单块与集群分级：保留单块在 1.0x 桌面模式下的既有防丢件保护 |

### 5.1 主方案 A：抓取锚点约束（推荐，最小改动）

把 clamp 作用对象从"碎片位置"改为"**光标/抓取点屏幕坐标**"，再由光标反算碎片位置：

```dart
// 1. 把抓取点（= 光标）夹进可视安全矩形：该矩形恒为正，永不退化
final safeLeft   = _sideMargin;
final safeRight  = size.x - _sideMargin;
final safeTop    = _topToolbarHeight;
final safeBottom = isTabletop ? size.y - 8.0 : trayPosition.y - 8.0;

final cx = cursorCanvasPos.x.clamp(safeLeft, safeRight);
final cy = cursorCanvasPos.y.clamp(safeTop, safeBottom);

// 2. 由抓取点反算主片位置：碎片跟随光标，集群其余部分允许伸出视口
final targetX = cx - _holdingAnchorX * primary.size.x * currentScale;
final targetY = cy - _holdingAnchorY * primary.size.y * currentScale;
```

**性质**：

- 区间宽度恒为 `safeRight - safeLeft > 0`，`safeMin > safeMax` **不可能发生**（P1）；
- 抓取点在屏内 ⇒ 该碎片至少有可见部分、随时可再次抓取（P2）；
- 集群主体可移出视口 ⇒ 满足腾挪（P3）；
- 无需任何"回中兜底"，`missingPieceCheck` 的搬运逻辑可退化为真正的异常处理（见 5.4）。

`handlePieceDragEnd` 的二次 clamp 采用同一函数（用 `piece.scale` 代入），消除两处公式漂移。

### 5.2 可选增强 B：世界域扩展（仅当产品要求"整簇完全离屏暂存"）

若明确要求允许把整个集群推到连抓取块都看不见的位置，则改用**模式化合法域**，并强制满足 P4：

```dart
/// 与 _clampPanOffset 的归一化域严格同源，保证 P4（合法域 ⊆ 平移可达域）
({double minX, double maxX, double minY, double maxY}) _dragDomain() {
  const viewLeft = _sideMargin;
  final viewRight = size.x - _sideMargin;
  const viewTop = _topToolbarHeight;
  final viewBottom = isTabletop ? size.y - 8.0 : trayPosition.y - 8.0;
  if (isTabletop) {
    // 桌面模式：视口反算域。实测 400x800 → nx[-0.41,1.06] ny[-1.20,1.73]
    return (
      minX: (viewLeft  - boardTopLeft.x) / boardSize.x,
      maxX: (viewRight - boardTopLeft.x) / boardSize.x,
      minY: (viewTop    - boardTopLeft.y) / boardSize.y,
      maxY: (viewBottom - boardTopLeft.y) / boardSize.y,
    );
  }
  // 托盘模式：棋盘域
  return (minX: 0.0, maxX: 1.0, minY: 0.0, maxY: 1.0);
}
```

锚点约束与反算：

```dart
final d = _dragDomain();
final anchorNx = nxRaw + _holdingAnchorX / cols;
final anchorNy = nyRaw + _holdingAnchorY / rows;
final nx = anchorNx.clamp(d.minX, d.maxX) - _holdingAnchorX / cols;
final ny = anchorNy.clamp(d.minY, d.maxY) - _holdingAnchorY / rows;
```

区间宽度 = `d.maxX - d.minX`（托盘模式恒为 1.0）⇒ 永不退化。

> **注意**：不得使用常数域（如 `[-0.2, 1.2]`），必须由几何反算；桌面模式的域随窗口尺寸变化（见 3.3）。

### 5.3 分级策略 C

| 模式 / 类型 | 约束 |
|---|---|
| 托盘模式 · 单块（可回托盘） | 方案 A；保留托盘尺寸过渡与回托盘逻辑 |
| 托盘模式 · 多块集群 | 方案 A（主体可出屏） |
| 桌面模式 · 单块 @ 1.0x | 方案 A；保留既有防丢件保护（首次散落不可离视野） |
| 桌面模式 · 任意 @ zoom > 1.0 | 方案 A（+ 可选增强 B） |

### 5.4 配套改动 D（必修，否则修复不闭环）

| # | 位置 | 改动 |
|---|---|---|
| D1 | `_syncResizeTransform()` L421–568 | 窗口尺寸变化：改为按**世界域**（而非屏幕边界）收拢游离碎片；且 `_setZoom(1)` 应改为"保留 zoom 或收敛到 `max(1.0, 原 zoom)`"，不再无条件清零 |
| D2 | `missingPieceCheck()` L2508–2519 | 越界判据从"超出视口"改为"超出**世界合法域**"；搬运目标改为最近的**域内可见位置**，而非固定屏幕正中 |
| D3 | `_clampPanOffset()` L1450–1480 | 保持不变（数学正确），但新增单元测试断言"合法域 ⊆ 平移可达域"，防止未来域定义漂移 |
| D4 | `handlePieceDragEnd()` L1917–1958 | 与 `updateHoldingPiecePosition` 共用同一约束函数，消除双份公式 |

---

## 6. 代码改动清单

| 文件 | 位置 | 改动要点 |
|---|---|---|
| `lib/game/jigsaw_puzzle_game.dart` | L1206–1232 | 移除包围盒 clamp，改为抓取锚点（光标）clamp + 反算 |
| `lib/game/jigsaw_puzzle_game.dart` | L1918–1958 | 同上，抽为公共方法 `_clampHoldingTarget(...)` |
| `lib/game/jigsaw_puzzle_game.dart` | 新增 | `_dragDomain()`（仅增强 B 需要）与 `_clampHoldingTarget()` |
| `lib/game/jigsaw_puzzle_game.dart` | L421–424、L470–568 | 按 D1 调整 |
| `lib/game/jigsaw_puzzle_game.dart` | L2508–2519 | 按 D2 调整 |

---

## 7. 测试契约升级清单

### 7.1 必须改写（旧断言将直接失败）

> **落地校正（2026-09-13 实施后回填）**：实际实施后只有 `:1403` 需要重写；
> `:873` 与 `:1033` 因为保留了"就近完整可见""仅收拢越过合法域的碎片"的兼容语义而**无需改动**，
> 详见 §11 实施记录。

| 位置 | 旧契约 | 新契约 |
|---|---|---|
| `test/game_layout_test.dart:1403` | 拖到屏幕外（-500,-500 / 1000,1500）后位置必须落在 `[8, size-8]` 内 | 改为：**主片中心**恒在交互安全区内 + 碎片永不整体消失 + 松手不回中 + 集群成员允许越出视口 |
| `test/game_layout_test.dart:873` | `missingPieceCheck` 把离屏碎片搬到屏幕内 | 语义保持（改为就近完整可见位置），断言无需改写 |
| `test/game_layout_test.dart:1033` | 窗口由大变小时游离碎片收拢到**视口**内 | 语义保持（判据升级为合法域，断言兼容），无需改写 |

### 7.2 新增回归测试

| 用例 | 断言 |
|---|---|
| 防退化回归 | 4×4 @ zoom 2，2×2 集群四方向拖拽，落点**至少 3 个不同值**（当前为 1） |
| 行程回归 | 同上，断言 `travelY > 0`（当前 `= 0`） |
| 跨模式域一致性 | 托盘模式：断言 `_dragDomain() == [0,1]²`；桌面模式：断言 `_dragDomain() ⊆ _clampPanOffset` 的归一化域 |
| 可找回性 | 把集群拖至域内最远点并松手，遍历 pan 极值，断言存在 pan 使该碎片包围盒进入视口 |
| 单块行为不回归 | 断言单块 1.0x 桌面模式仍不会落到视野外 |

---

## 8. 验证计划

按项目规约顺序执行（`AGENTS.md`）：

1. `dart format <改动文件>`
2. `flutter analyze`
3. `flutter test`（重点确认 `test/game_layout_test.dart` 全绿）
4. `flutter build windows --debug`
5. `flutter test .\integration_test\app_test.dart -d windows`
6. 手工验证清单：
   - 1200×800 窗口，4×4 难度，放大到 2.0x，抓取 2×2 集群：四方向均可自由移动，且可推到视野外；
   - 手机竖屏 392×800 复测同一场景（该尺寸下 X 轴锁死最严重）；
   - 桌面散落模式：散落碎片拖拽不被突然拉回；
   - 平移画布后仍能找回被推出视野的集群；
   - 缩小回 1.0x、点扫把整理：行为保持现有预期。

---

## 9. 风险与注意事项

| 风险 | 说明与对策 |
|---|---|
| 碎片可停在"部分出屏"位置 | 属预期行为（P3）；需确认 `updatePieceVisibility()` 与 `_checkEdgeCompleteAutoDismiss()` 的判定不受影响 |
| 快照归一化坐标范围扩大 | `nx/ny` 可能落在 `[-1.2, 1.9]`，读档路径 `_normalizedToScreen()` 已能容纳；需确认 `_isNormalizedOnBoard()`（L203，容差 `_boardBoundsTolerance = 0.05`）的语义不因域扩大而失效 |
| 桌面模式扫把整理 | `organizeTray()` L2104 在放大状态下会 `resetZoom()` 回 1.0x 并重排，与本次修复叠加后需复测 |
| 域定义漂移 | 由 7.2 的"跨模式域一致性"测试长期锁定 |
| 范围界定 | 本文仅覆盖拖拽限位链路；`_syncResizeTransform` 的 zoom 清零（D1）虽同文件，但属独立问题，实施时建议单独提交便于回滚 |

---

## 10. 附：实测原始输出

```
# 4x4 托盘模式，zoom = maxZoom = 2.0，光标 13x13 全屏扫描
SWEEP 2x2 screen=392x800   board=376 pieceVisual=188 travelX=0px   travelY=272px
SWEEP 2x2 screen=800x600   board=448 pieceVisual=224 travelX=336px travelY=0px
SWEEP 2x2 screen=1200x800  board=648 pieceVisual=324 travelX=536px travelY=0px
SWEEP 2x2 screen=1920x1080 board=928 pieceVisual=464 travelX=976px travelY=0px
SWEEP 3x3 screen=392x800   travelX=102px travelY=84px
SWEEP 3x3 screen=800x600   travelX=112px travelY=120px
SWEEP 3x3 screen=1200x800  travelX=212px travelY=170px
SWEEP 3x3 screen=1920x1080 travelX=512px travelY=240px

# 3x3 托盘模式 @1200x800，2x2 集群（864x864）
BAND X=[8.0,328.0] Y=[8.0,-208.0] invertedX=false invertedY=true
DOC_CENTER midX=168.0 -> clusterCenterX=600.0 (screen mid=600)
           midY=-100.0 -> clusterCenterY=332.0 (screen mid=400)
SWEEP_X cursor 50..1150 landings=8,8,34,134,234,328,328,328,328,328,328,328
SWEEP_Y cursor 50..750  landings=-166,-66,8,8,8,8,8,8

# 桌面散落模式散落碎片归一化域（4x4 tabletop）
TABLETOP 400x800   board=212 nx=[-0.41,1.06] ny=[-1.20,1.73] outside[-0.2,1.2]=12/16
TABLETOP 1200x800  board=453 nx=[-0.78,1.43] ny=[-0.30,0.82] outside[-0.2,1.2]=15/16
TABLETOP 1920x1080 board=636 nx=[-0.96,1.60] ny=[-0.29,0.83] outside[-0.2,1.2]=16/16

# 视口平移锁死（1920x1080，3x3，zoom 2）
PAN_CHECK boardTopLeft=[496.0,8.0] trayY=944.0 board=928x928
          content=1856x1856 viewW=1904 viewH=928
          panBy(5000,-5000) -> pan=(-464.0,-928.0)   # X 恒为单点
```

---

## 11. 实施记录（2026-09-13 落地回填）

### 11.1 实际落地的改动

| # | 文件 | 内容 |
|---|---|---|
| 1 | `lib/game/jigsaw_puzzle_game.dart` | 新增 `_dragCenterSafeBounds`（交互安全矩形）与 `_clampDragTarget`（**唯一限位入口**） |
| 2 | 同上 | `updateHoldingPiecePosition`：删除整簇包围盒偏移与 `safeMin/safeMax` clamp，改为主片中心单点约束 |
| 3 | 同上 | `handlePieceDragEnd`：删除重复的包围盒 clamp，改为与拖拽期共用 `_clampDragTarget`（由锚点反推光标再夹取），集群整体平移不变 |
| 4 | 同上 | 新增 `_legalDomainScreenRect`；`_syncResizeTransform` 的游离碎片收拢边界由"屏幕视口"改为"合法域屏幕矩形" |
| 5 | 同上 | `missingPieceCheck` 回收目标由"固定屏幕正中"改为"就近落在视口内的完整可见位置" |
| 6 | `test/game_layout_test.dart` | 重写 `:1403` 旧契约；新增 2 条回归用例（极端拖拽中心约束/不回中；放大 2.0x 集群行程与推出视口暂存） |

### 11.2 与本文方案的三处偏差（已按更稳的取舍落地）

| 项 | 方案原文 | 实际落地 | 原因 |
|---|---|---|---|
| 约束对象 | 抓取锚点（与抓取位置相关） | **主片中心**（与抓取位置无关） | 中心的可见性保证更强（抓取点在角上时整片可能只剩一像素可见），且实现与解释更简单；锚点取 0.5 时二者等价 |
| 拖拽合法域 | 方案 B 建议用"世界域"（`_dragDomain()`） | 拖拽期保持"交互安全矩形（视口）"；**世界域只用于窗口缩放的收拢判据** | 中心约束本身已不可能退化；且"中心恒在视口内"天然满足"落点必然可见、可平移找回"，无需引入第二套域定义（少一处漂移风险） |
| 平移可达域校验 | D3 新增"合法域 ⊆ 平移可达域"单测 | 未新增 | 拖拽域退化为"视口"，而视口恒 ⊆ 当前可见世界，包含关系由构造保证；改为在 `:1403` 与新增用例中断言"中心恒在安全区 + 碎片永不整体消失"这一更强的可见性不变量 |

### 11.3 实施后的实测对比（3x3 @1200x800，zoom 2，2x2 集群）

| 光标目标 | 修复前落点 | 修复后落点 |
|---|---|---|
| 屏幕右下 (1700,1300) | (328, 8) | (976, 576) |
| 屏幕中心 (600,400) | (328, 8) | (384, 184) |
| 右上 (1190,400) | (328, 8) | (974, 184) |
| 底部 (600,790) | (328, 8) | (384, 574) |
| 左上 (-500,-500) | (8, −208) | (−208, −208) |

- 修复前：4 个不同方向的光标位置塌缩到同一个落点（且垂直方向完全无法移动）；
- 修复后：落点随光标连续变化，水平行程 1184px、垂直行程 784px（≈整屏）；
- 9 块满盘集群同样从"完全锁死"恢复为可自由移动。

### 11.4 遗留项（未纳入本次范围）

1. `_syncResizeTransform` 仍在窗口尺寸变化时 `_setZoom(1)` 复位缩放并清空平移（丢失用户缩放状态）——独立问题，建议单独提交。
2. 托盘模式下放大后的集群允许覆盖底部托盘区域：原"集群绝不遮挡托盘"与"允许移出视口"在数学上不可兼得，本次按后者（用户核心诉求）优先取舍。
3. `_getTabletopScatterSlots`（L862）的散落槽位仍按屏幕空间生成，因此桌面散落的归一化域随窗口尺寸波动（3.3 节）；若后续要统一域定义，可在此收敛。

### 11.5 验证结果

| 步骤 | 结果 |
|---|---|
| `dart format`（改动文件） | 通过 |
| `flutter analyze` | 改动文件 0 issue（仓库内另有 2 条 `lib/main.dart:94` 的既有 info，与本改动无关，未越界修改） |
| `flutter test` | **360 passed / 8 skipped**（`test/game_layout_test.dart` 52 条全绿） |
| `flutter build windows --debug` | 构建成功 |
| `flutter test integration_test/app_test.dart -d windows` | 通过 |
