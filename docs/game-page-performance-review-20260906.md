# Game Page 性能瓶颈 Review（只分析，不改代码）

**日期**：2026-09-06
**分析范围**：`lib/pages/game_page.dart`、`lib/game/jigsaw_puzzle_game.dart`、`lib/game/puzzle_piece_component.dart`、`lib/logic/engine/puzzle_engine.dart`、`lib/logic/models/puzzle_state.dart`、`lib/logic/geometry/*`
**方法**：静态代码走查 + 复杂度推算 + Flame 1.38 源码行为核对，**未做动态 profile**，文中的耗时数字均为「操作数量级」而非实测毫秒，需按第 6 节方法复核。
**规模前提**：难度上限为 `PuzzleAspectRatio.square1x1` 的 `multipliers: [..., 24]` → **24×24 = 576 片**（`lib/logic/puzzle_model.dart:60`）。既有性能文档以 24 片为样本，所有 O(n²) 问题在小盘下完全测不出来。

---

## 0. 结论摘要

| 级别 | 瓶颈 | 性质 | 触发时机 |
|---|---|---|---|
| **P0-1** | 已归位/静止碎片每帧全量重绘（clipPath + 6 类绘制指令），`hideBorders` 优化从未启用 | 每帧 | 全程，后期最重 |
| **P0-2** | `PuzzleBoardState.pieceById()` 是 O(n) 线性扫描，被所有热路径调用 → 全链路退化 O(n²) | 松手/整理/读档 | 每次交互 |
| **P0-3** | `resolveSnap` + `_mergeAllAdjacentClusters` + `computePlantedPieceIds` 的 O(n²)~O(n³) 扫描 | 松手瞬间 | 每次松手 |
| **P1-1** | `_updateBoardTransform()` 手动遍历全部碎片更新位置/缩放，未按 Flame Camera 实现 | 每次平移/缩放 | 拖拽平移、滚轮 |
| **P1-2** | `_computeLayout()` 桌面模式二分搜索 + `_syncResizeTransform()` 全量重建 Path | 窗口尺寸每变一次 | Windows 拉伸窗口 |
| **P1-3** | 一次松手分配数千个短命不可变对象（`copyWith`/`map`/`Point`/`Vector2`） | GC 压力 | 每次松手 |
| **P2-1** | `organizeTray()` 内嵌 O(n²) 集群计数 | 点「扫把」 | 手动触发 |
| **P2-2** | `updatePieceVisibility()` 每次 O(n²) 且重复调用 `edgesFor` 建对象 | 松手/筛选/整理 | 每次交互 |
| **P2-3** | GamePage `setState` 粒度过大（整棵 Scaffold + 全屏平铺背景 + AppBar） | UI 线程 | 每次松手/抬手 |
| **P2-4** | `_flushSync()` 快照 encode→decode 空转 + 同步 JSON 写在 lifecycle paused | 掉帧风险 | 切后台/退出 |
| **P3** | 死代码：`hideBorders` 恒 false、`_secondsNotifier` 无监听、`resetCurrentGame()` 无调用点 | 维护债务 | — |

---

## 1. P0-1：每帧渲染 —— 静止碎片全量重绘（最大的一块）

### 1.1 现象
`PuzzlePieceComponent.render()`（`lib/game/puzzle_piece_component.dart:183`）对每个未被过滤的碎片，每帧执行：

```
drawPath(contactShadow)      // 路径填充，无 blur
drawPath(cardboardSide)      // 仅拖拽
clipPath(shape.path)         // ★ 抗锯齿路径裁剪
drawImageRect(原图采样)
drawRect(linen shader)       // ★ 带 ImageShader 的全碎片面积填充
drawPath(highlightPath)
drawPath(shadowPath)
```

按 576 片、全部在屏幕内计算：**约 3500~4000 条绘制指令/帧，其中 576 次 `clipPath`**。

### 1.2 为什么视锥剔除救不了
`render()` 里的视锥剔除（`:190-205`）只能剔掉「滚出托盘左右两侧」的碎片。而已归位碎片全部位于棋盘内，`zoom=1` 时棋盘完整落在屏幕内 → **576 片全部通过剔除，全部绘制**。桌面散落模式（`scatterMode='tabletop'`）更极端：所有碎片都在屏幕内，零剔除。

### 1.3 `hideBorders` 是设计好但没接上的开关
```dart
// puzzle_piece_component.dart:77
bool hideBorders = false;   // 注释：通关后由底板渲染整图，碎片停止绘制
// :184
if (isFilteredOut || hideBorders) return;
```
全仓库 grep：`hideBorders` 唯一的写入点是 `jigsaw_puzzle_game.dart:1480` 的 `comp.hideBorders = false;`（在 `resetCurrentGame()` 里），而 `resetCurrentGame()` 本身**没有任何调用点**。
→ 这条「通关后停止逐片绘制」的通路从未生效，通关后 576 片仍在每帧全量绘制。

### 1.4 组件树开销：render 里 return 只省一半
Flame 1.38 `PositionComponent.renderTree` = `decorator.applyChain(...)`，默认 decorator 为 `Transform2DDecorator(transform)`（`position_component.dart:86`）。即使 `render()` 第一行 return，每个碎片仍要付出一次 `canvas.save() + transform + restore()`。要真正省掉，必须 `removeFromParent()`，而不是在 render 里早退。

### 1.5 优化方向（按收益排序）
1. **已归位碎片烘焙**：`isLocked == true` 后，把该碎片从组件树移除，改由棋盘层一次性绘制（按「已完成矩形并集」`drawImageRect` 原图，或用 `drawAtlas` 批量）。后期 90% 碎片零逐片成本 —— 这也是 `hideBorders` 的原本意图。
2. **静止碎片 Cache-as-Picture / Cache-as-Image**：用 `PictureRecorder` 把「clip + 采样 + 亚麻 + 描边 + 接触阴影」录成 `ui.Picture`（必要时 `toImage()` 成位图），静止时只 `drawPicture`。失效条件：`scale` 档位变化、拖拽开始、高亮、旋转。注意拖拽时缩放渐变（托盘↔棋盘 60px 过渡带）需按离散档缓存，否则缓存命中率归零。
3. **亚麻层上移**：`drawRect(fillRect, linenPaint)` 是每片一次的非整数对齐浮点填充（overdraw ≈ 1.7×1.7 倍格子面积）。可改为整层一次绘制（棋盘/托盘各一层），或烘焙进碎片缓存图（`LinenTextureManager` 的 `srcOver` 混合已在既有方案中落地，此处是「每片一次」的频次问题，不是混合模式问题）。
4. **接触阴影合并进缓存**：静止时 `_contactShadowPaint` 的 `drawPath` 是纯路径填充，完全可以和本体一起烘焙。

---

## 2. P0-2：`pieceById` 是 O(n) 线性扫描（全链路复杂度放大器）

```dart
// lib/logic/models/puzzle_state.dart:192
PieceState pieceById(int id) {
  for (final p in pieces) { if (p.id == id) return p; }
  throw StateError(...);
}
```

调用点（均在 n 级循环内部或高频路径）：

- `updatePieceVisibility()`：`jigsaw_puzzle_game.dart:1806`、`:1813` → **循环内 O(n) ⇒ O(n²)**
- `updatePiecesStateAndPriorities()`：`:1516` 遍历 pieces 时按 id 取组件（走 Map，OK），但 `computePlantedPieceIds` 内部 BFS 每步 `state.pieceById(id)`（`puzzle_engine.dart:115`）⇒ **BFS O(n) 节点 × O(n) = O(n²)**
- `organizeTray()` / `_applyBoardState()`：循环内 `pieceById` ⇒ **O(n²)**
- `exportSnapshotJson()`、`missingPieceCheck()`：单次 O(n)，可接受

`pieces` 在 `createInitialState` 中按 `id = r*cols+c` 顺序生成，快照导出也保持 `newState.pieces` 原序，因此 `pieces[id]` 索引在几乎所有路径成立。

**建议**：在 `PuzzleBoardState` 内维护 `Map<int, PieceState>` 索引（构造/`copyWith(pieces:)`/`fromJson` 三处同步），或至少在 `JigsawPuzzleGame` 侧缓存 `Map<int, PieceState> _stateById`，每次 `_boardState` 变更时重建一次。这一项能把下面所有 O(n²) 直接降为 O(n)，是**投入产出比最高的单点改动**。

---

## 3. P0-3：松手瞬间（dragEnd）的计算峰值

一次 `handlePieceDragEnd()`（`jigsaw_puzzle_game.dart:1629`）触发的调用链与实际量级（n=576）：

| 步骤 | 位置 | 复杂度 | 操作数 |
|---|---|---|---|
| 全量 `copyWith` 重建 pieces | `:1702` | O(n) 分配 | 576 个新对象 |
| `PuzzleEngine.resolveSnap` | `puzzle_engine.dart:161` | — | — |
| └ `canSnapCluster` → `computePlantedPieceIds` | `:137` / `:98` | **O(n²)**（BFS 内 `pieceById`） | ≈3.3×10⁵ |
| └ 阶段二邻居合并双循环 | `:255-349` | **O(n²)**（内层还有 `where().length` ⇒ 合并时 O(n)） | ≈3.3×10⁵ |
| └ `_mergeAllAdjacentClusters` | `:393` | **O(n²)/轮 × 轮数**，每轮合并还有 O(n) 重映射 | 可达 10⁶ |
| `updatePieceVisibility` | `:1800` | **O(n²)**（`pieceById` + `edgesFor`） | ≈3.3×10⁵ |
| `updatePiecesStateAndPriorities` | `:1509` | `computePlantedPieceIds` **O(n²)** + 2n 个 `Point` 对象 | ≈3.3×10⁵ |
| `solvedCount` / `isSolved` | `:216` / `puzzle_state.dart:217` | O(n)，被调用多次 | — |

**合计：一次松手约 10⁶ 量级基本操作 + 数千次对象分配**。中低端设备/桌面端会有明显的一次性卡顿 —— 而且这恰恰发生在「每放下一块碎片」这个玩家最敏感的时刻。

**建议**：
1. 先做第 2 节的 `pieceById` O(1) 化，上表 O(n²) 全降为 O(n)，成本最低。
2. `resolveSnap` 阶段二与 `_mergeAllAdjacentClusters` 无需全量两两比较：按 `(r, c)` 建 `Map<String,int>` 网格索引（或 `rows*cols` 定长数组），只查 4 个正交邻居 ⇒ O(n)。
3. `computePlantedPieceIds` 的 BFS 用 id→PieceState 索引 + 预建 `(r,c)→id` 表；并把结果缓存到「boardState 未变更」期间（同一次 dragEnd 内被调 2 次：`canSnapCluster` 一次、`updatePiecesStateAndPriorities` 一次）。
4. 减少临时对象：`Point(...).distanceTo(...)` 改平方距离比较（`:209`、`:277`、`jigsaw_puzzle_game.dart:1527`），`_normalizedToScreen` 返回复用的 Vector2 或写入 out 参数。

---

## 4. P1：交互与布局重算

### 4.1 缩放/平移：手动遍历 vs Camera（P1-1）
`zoomAt` / `setZoomAndPan` / `panBy` / `resetZoom` 最终都调 `_updateBoardTransform()`（`:1379`），它遍历 `_boardState.pieces` 逐片 `position.setFrom + scale.setAll`。而 `panBy` 由 `GamePage._onPointerMove` 驱动（`game_page.dart:850`），鼠标/触摸移动事件可达 60~125Hz ⇒ **每事件 O(n)，576 片时约 7×10⁴ 次/秒**，且每次都触发 Flame 的 transform 重算。

正确做法：用 Flame 的 `CameraComponent.viewfinder`（`zoom` + `position`）表达棋盘层的缩放/平移，一次变换取代逐片更新；托盘层保持屏幕坐标不随相机变换。这是架构级改动，但能同时消除该热点和大量坐标换算代码。

### 4.2 窗口 resize：重算过猛（P1-2）
`onGameResize` → `_computeLayout()` + `_syncResizeTransform()`（`jigsaw_puzzle_game.dart:383`）：
- 桌面模式下 `_computeLayout` 内含二分搜索：每次 `isFeasible` 调用 `estimateSlots` + `hasBalancedDistribution`，两者都是网格双重循环；12 次二分 × 2 函数 × 前置检查 ⇒ 数万次迭代 + 大量临时对象（`:606-742`）。
- `_syncResizeTransform` 对每个碎片 `edgeLayout.edgesFor()` + `new PieceShape(...)` ⇒ **重建 3 条贝塞尔 Path × 576**（`:423-428`）。

Windows 上拖动窗口边框时 `onGameResize` 每帧触发（尺寸每帧都变 >0.5px），整条链路每帧重跑 ⇒ 拖窗口严重掉帧。
建议：resize 用 100~150ms 防抖（或只在 resize 结束回调后执行）；`_computeLayout` 结果按 `(size.x, size.y, rows, cols)` 缓存；`PieceShape` 按「(r,c) → 缓存 + 尺寸档位」复用。

### 4.3 每次松手的 GC 压力（P1-3）
`_boardState.copyWith(pieces: ...)` 在 dragEnd 中被调用 ≥3 次（`handlePieceDragEnd` 一次、`resolveSnap` 内 `_translateCluster` 每次合并一次、`_mergeAllAdjacentClusters` 每轮一次）。每次都是 **576 个 `PieceState` 全量重建**。配合 `Point`/`Vector2`/闭包分配，一次松手可产生 5000+ 短命对象，容易触发新生代 GC 造成掉帧。
建议：`_translateCluster` / 合并改为原地写 `nx, ny`（保留 `PieceState` 可变字段或引入内部 `PieceStateBuffer`），只在最终提交时生成一次不可变快照。

---

## 5. P2：可感知但影响面较小的项

### 5.1 `organizeTray()` 的 O(n²)（P2-1）
```dart
// jigsaw_puzzle_game.dart:1877（tabletop）与 :1912（tray）
final clusterSize = _pieces.values.where((o) => o.clusterId == p.clusterId).length;
```
外层遍历 n 片 × 内层 O(n) ⇒ 576² ≈ 3.3×10⁵，两个分支都存在。改为先统计一次 `Map<int,int> clusterSizes`。

### 5.2 `updatePieceVisibility()` 重复建对象（P2-2）
- 循环内 `edgeLayout.edgesFor(p.r, p.c)`（`:1805`、`:1812`）：每次 new `PieceEdges` + 最多 4 个 `complementary()` 描述子；576 片 ⇒ 每次调用建数千小对象。`edgesFor` 结果是纯确定性的，按 `r*cols+c` 缓存一次即可。
- 即使 `_borderFilterActive == false`，循环仍然全量跑一遍并调用 `pieceById` ⇒ 见 P0-2。

### 5.3 GamePage 的 setState 粒度（P2-3）
- `_markNeedsUIUpdate()` 已把 `onProgressChanged`/`onStateUpdated` 合并为一帧一次 setState，做得对。
- 但 `_onPointerUp` / `_onPointerCancel`（`game_page.dart:864`、`:877`）无条件 `setState(() {})`，状态并未改变，纯属浪费。
- 每次 setState 重建整棵 `Scaffold`：AppBar（6 个 IconButton，其中一个还套 `Stack`）+ `Image.asset(repeat: ImageRepeat.repeat)` 全屏平铺背景 + `SafeArea/Column/Listener/AnimatedOpacity/ClipRect/GameWidget`。
- 既有方案文档 §3 提出的「`RepaintBoundary` 隔离 GameWidget + 顶层遮罩淡出代替 `AnimatedOpacity(GameWidget)`」**尚未落地**：当前仍是 `AnimatedOpacity` 直接包裹 `ClipRect → GameWidget`（`game_page.dart:1171-1180`），且无 `RepaintBoundary`。进入游戏那 300ms 会为整屏画布分配离屏缓冲。
- 建议：`_buildProgressLine` 用 `ValueListenableBuilder` 局部刷新；背景层加 `RepaintBoundary`；删掉 pointerUp 的空 setState。

### 5.4 保存路径的空转（P2-4）
`_flushSync()`（`game_page.dart:371`）：`exportSnapshotJson()` 生成 30KB+ JSON → `jsonDecode` → `PuzzleBoardState.fromJson`，**编码完立刻解回来**，等于把 576 片的序列化做了两遍，还多一次 `PieceState.fromJson` 分配。且它在 `didChangeAppLifecycleState(paused)` 和 `dispose()` 中同步执行。
建议：`exportSnapshotJson` 增加返回 `PuzzleBoardState` 的兄弟方法（或让 `_flushSync` 直接构造 state，JSON 只在真正需要字符串时才生成）。

### 5.5 其它
- `scrollTray()`（`:1115`）每次调用 `where().toList()` 建临时 List 再 `_realignTrayPieces()` 全量重排：滚动期间高频。可缓存「当前托盘可见 id 列表」，仅在集合变化时重建。
- `updateHoldingPiecePosition()`（`:992`）每次鼠标移动都 `_pieces.values.where(...)` 全量扫描求集群成员。可维护 `Map<int, List<PuzzlePieceComponent>> clusterMembers`。
- `isDraggingAnyPiece`（`:228`）同样是 O(n) 全扫，被 `GamePage._onPointerMove` 高频调用。改成一个 int 计数器即可。
- 原图未降采样：`decodeFlameImage(widget.imageBytes)` 直接全量解码。4000×3000 的图 ⇒ 约 48MB GPU 纹理；576 次 `drawImageRect` 从超大纹理采样，对纹理缓存不友好。可按「屏幕像素 × maxZoom × 1.2」上限做一次 `instantiateImageCodec(targetWidth:)` 降采样（`_loadHeaderColor` 里已有同样的降采样写法可复用）。

---

## 6. 死代码 / 债务（P3）

| 项 | 位置 | 说明 |
|---|---|---|
| `hideBorders` | `puzzle_piece_component.dart:77` | 恒为 false，通关停止绘制的优化未接线（见 1.3） |
| `resetCurrentGame()` | `jigsaw_puzzle_game.dart:1424` | 无任何调用点（连带 `hideBorders=false` 是唯一写入） |
| `_secondsNotifier` | `game_page.dart:69` | 创建、赋值、dispose，但 build 中无 `ValueListenableBuilder` 监听 ⇒ 无实际 UI 效果 |
| `_topPriority` | `:196` | 每次 dragStart/hint `+= 2` 单调增长，虽无功能问题，但宜设上限或改用「置顶层专用父节点」 |

---

## 7. 验证方法（改前先量化，改后要对比）

1. **规模**：不要用 24 片测试。用 `square1x1` 最高倍率（24×24 = 576 片）建局，分别测 tray 与 tabletop 两种 `scatterMode`。
2. **插桩**：项目已有 `Stopwatch` + `AppLogger.game` 先例（`onLoad` 内）。在以下位置加耗时埋点并输出到日志页：
   - `handlePieceDragEnd`（整体 + `resolveSnap` + `updatePieceVisibility` + `updatePiecesStateAndPriorities` 分段）
   - `organizeTray`、`_applyBoardState`、`_syncResizeTransform`
   - `PuzzlePieceComponent.render`（统计每帧 render 调用次数与总耗时 —— 这才是 P0-1 的直接证据）
3. **帧率**：`flutter run --profile`，开 `PerformanceOverlay`，重点看：(a) 静止不动时的基线帧耗时；(b) 拖窗口边框时；(c) 每次松手瞬间的尖刺。
4. **分配**：DevTools Memory → Allocation profile，对比一次松手前后的 `PieceState` / `Point` / `Vector2` 分配次数。

---

## 8. 建议实施顺序

1. **第 2 节**（`pieceById` O(1) 化）—— 一行索引，全链路收益，风险最低。
2. **第 1.5 节 第 1 项**（已归位碎片移出组件树 / 烘焙）—— 直接砍掉后期 90% 的每帧绘制。
3. **第 5.3 节**（RepaintBoundary + 遮罩淡出 + setState 收敛）—— 既有方案已定，直接落地。
4. **第 3 节**（resolveSnap 网格索引 + 减少对象分配）—— 消除松手尖刺。
5. **第 4.1 / 4.2 节**（Camera 化 + resize 防抖）—— 架构级，单独立项。
6. **第 1.5 节 第 2 项**（Cache-as-Picture）—— 若 1~5 完成后帧率仍不达标再做。

---

## 9. 与既有文档的关系

- `docs/rendering-performance-optimization-plan-20260906.md` 的方案二（亚麻 `softLight → srcOver`）**已落地**（`linen_texture_manager.dart:72` 现为 `BlendMode.srcOver`）。
- 同文档的方案一（`RepaintBoundary` + 顶层遮罩淡出）**未落地**，见 5.3。
- 同文档的方案三（Picture 离屏缓存）**未落地**，本文 1.5 节给出更具体的失效条件与优先级建议。
- 既有文档的 profile 样本为 24 片规模，未覆盖本文第 2、3 节的大盘 O(n²) 问题。
