# 代码审查报告 · 2026-10-03

> 审查范围：`lib/`（100 个 dart 文件）+ `test/`（54 个文件）+ `integration_test/`
> 重点：游戏核心拼图（`lib/game/`、`lib/logic/engine/`、`lib/logic/geometry/`、`lib/logic/models/`）
> 审查人：AI 代码审查（opencode）
> 审查日期：2026-10-03（GMT+8）

## 0. 审查方法与取证原则

本报告的每条结论都满足以下之一，否则不写入：

1. **代码引用**：给出 `文件:行号` 与关键代码片段，并说明推演路径；
2. **实测数据**：用一次性探针测试（跑在 `temp/`，验证后已删除）复刻生产公式/算法，
   打印真实数值或耗时；
3. **命令输出**：`flutter analyze` / `flutter test` 由审查人本人于 2026-10-03 实跑。

**明确不做的事**：不把"看起来可能有问题"写成缺陷；不把构造出来的极端场景当作已确认的
线上问题；不重复 `docs/code-review-full-20260916.md` 等历史报告中已修复的问题。

### 0.1 本次实跑的构建/测试基线

```
$ flutter analyze
No issues found! (ran in 10.2s)

$ flutter test
00:18 +395 ~8: All tests passed!      # 395 通过 / 8 跳过 / 0 失败
```

### 0.2 探针实测关键数据（供复核）

| 探针 | 结论 |
|---|---|
| PROBE-1 | 生产吸附容差 `effectiveSnapDistance()` 与 `solvedEpsilonFor()` 在 zoom=2 时**反向**，比值低至 0.49 |
| PROBE-2 | 孤立内部碎片精确落槽 → `isSolved=true`、`solvedCount` 计入、`planted` 不含、`resolveSnap.didSnap=false` |
| PROBE-3/7 | **真实散落逐块放置：5×5→24×24 全程集群网格不变量无违规，单次 `resolveSnap` 最长 4.9ms**（正常玩法引擎是健康的） |
| PROBE-8 | 576 片同时网格对齐但整体错位 → 单次 `resolveSnap` **849~857ms** + 不变量违规（构造场景） |
| PROBE-11 | 存在 `planted=true && isLocked=false` 的碎片状态组合 |
| PROBE-12 | `_maxZoom` 实测 2.0~3.285，**并非恒为 2.0** |
| PROBE-13 | 400 片集群落位 `resolveSnap` 30ms |
| PROBE-14 | "在托盘区域"两套阈值在碎片高 ≥100px 时分歧 5~30px |
| PROBE-16 | 桌面散落约束分配 `_buildScatterAssignment` 全档位 **1 轮命中零冲突，≤4ms**（无性能问题） |

---

## 1. 结论摘要

### 1.1 分级统计

| 级别 | 数量 | 编号 |
|---|---|---|
| 阻塞（会导致无法游玩/丢档） | 0 | — |
| 高 | 1 | G-1 |
| 中 | 6 | G-2、G-3、G-4、D-1、D-2、D-3 |
| 低 | 11 | G-5~G-10、D-4~D-7、E-1~E-4 |

### 1.2 一句话总体判断

**核心引擎的数学与拓扑是正确的，正常玩法下性能可接受、不变量不被破坏**（PROBE-7 已证明）。
真实风险集中在三处：**（a）"就位"这件事存在三套互相不一致的判据**（G-1）；
**（b）权威状态从渲染组件的瞬时位置派生，与在途动画不同步**（G-2/G-3）；
**（c）存档层缺少真正的回滚副本**（D-1）。

### 1.3 本次审查**没有**发现的（避免夸大）

- 未发现崩溃级缺陷；`PuzzleEngine.resolveSnap` 的两阶段吸附 + 集群合并 + 级联逻辑经实测正确。
- 未发现"碎片被吸附到错误槽位"或"公母扣不契合"——`EdgeLayout` 的互补边生成是正确的。
- 未发现桌面散落约束分配的性能问题（PROBE-16 实测 ≤4ms）。
- 未发现难度选择与实际开局片数不一致（`ChooseDifficultySheet` 已按图片真实比例给出 tiers，
  `adaptiveForSize` 的最近邻必然命中同一档）。
- 未发现重复通关结算（`_isSolved` 在首个 `await` 前同步置位，`game_page.dart:594/620-623`）。

---

## 2. 核心拼图系统架构评估

### 2.1 分层与依赖方向（做得好的部分）

```
lib/logic/geometry/     纯几何：EdgeLayout / EdgeCurve / PieceShape（无 Flutter 状态依赖）
lib/logic/models/       纯数据：PieceState / PuzzleBoardState（@immutable + 惰性索引）
lib/logic/engine/       纯领域：PuzzleEngine / UndoManager（不 import flame，不 import widgets）
lib/game/               渲染 + 交互：JigsawPuzzleGame(FlameGame) / PuzzlePieceComponent
lib/pages/game_page.dart  页面壳：计时、存档调度、指针手势分发、结算弹窗
```

依赖方向是单向的（game → engine → models → geometry），`PuzzleEngine` 完全不依赖 Flame，
因此核心算法可以纯单元测试——这也是 `snap_algorithm_test.dart` 能覆盖 13 个用例的前提。
这个分层是本项目最健康的资产。

### 2.2 状态权威设计（存在缺陷）

设计意图是"`_boardState`（`PuzzleBoardState`）为唯一权威，Flame 组件为投影"。
但实现上**权威状态在多个路径下是从组件的瞬时位置反算出来的**：

- `handlePieceDragEnd`（`jigsaw_puzzle_game.dart:2169-2188`）
- `exportSnapshotJson`（`jigsaw_puzzle_game.dart:2558`）
- `_pullbackOutOfBoundsClustersAndPieces`（`jigsaw_puzzle_game.dart:2393`）
- `_syncResizeTransform`（`jigsaw_puzzle_game.dart:614-616 / 653-654`）

组件位置是**渲染层的中间态**（可能处于 `MoveToEffect` 插值中途）。这违反了"权威状态不应
从投影反推"的基本原则，是 G-2 / G-3 两条中等级缺陷的共同根因。

代码里其实已经有正确的做法，只是没有统一：`missingPieceCheck` 在整簇平移前显式调用了
`comp.clearMoveEffects()`（`jigsaw_puzzle_game.dart:2972`）。

### 2.3 "就位"的三套判据（本次最重要的发现）

| 用途 | 判据 | 位置 | 是否随缩放变化 |
|---|---|---|---|
| 进度、通关、筛选、整理 | `isSolved` → `solvedEpsilonFor(rows,cols)` = `min(0.035, min(1/cols,1/rows)*0.40*0.5)` | `puzzle_state.dart:21-24, 110-116` | **否** |
| 吸附到槽位、邻居合并 | `effectiveSnapDistance()` = `min(cellPx*0.40, 48px)` 换算回归一化 | `jigsaw_puzzle_game.dart:1517-1525` | **是** |
| 锁定（`isLocked`） | `planted.contains(id) && dist <= effectiveSnapDistance()` | `jigsaw_puzzle_game.dart:1908-1913` | **是** |

`puzzle_state.dart:19-20` 的注释明确宣称"保证任意网格下『通关容差 <= 吸附容差』，
杜绝『碎片比吸附还远却被判定已就位』"。**这个保证在生产链路上不成立**，因为它只对比了
`PuzzleEngine.calculateSnapThreshold`（引擎默认值），而生产实际传入的是
`effectiveSnapDistance()`（`jigsaw_puzzle_game.dart:2200`），后者带 48px 硬上限且随 zoom 收缩。

---

## 3. 影响游玩的缺陷（核心拼图）

### G-1【高】进度 / 锁定 / 通关使用三套判据，放大态下互相矛盾

**现象**：玩家把一块内部碎片放到"看起来正确"的位置后，进度条前进，但碎片既不吸附也不锁定，
仍可被拖走；在特定缩放下还会出现"已就位但可拖动"的碎片把整块已锁定装配体一起拖走。

**证据 1 —— 容差反向（PROBE-1 实测）**

生产公式 `effectiveSnapDistance()` 在 1400px 棋盘、zoom=2 时：

| 网格 | snap@zoom1 | snap@zoom2 | solvedEpsilon | snap@2 / solvedEps |
|---|---|---|---|---|
| 5×5 | 0.03429 | **0.01714** | 0.03500 | **0.49** |
| 8×8 | 0.03429 | 0.01714 | 0.02500 | 0.69 |
| 10×10 | 0.03429 | 0.01714 | 0.02000 | 0.86 |
| 12×12 | 0.03333 | 0.01714 | 0.01667 | 1.03 |
| 24×24 | 0.01667 | 0.01667 | 0.00833 | 2.00 |

即存在一个 **0.017 ~ 0.035 的归一化"既算已通关、又不被吸附锁定"的死区**（1400px 棋盘上
约 24~49 屏幕像素）。所有 ≤10×10 的档位在放大态都落在死区内。

**证据 2 —— 进度虚高（PROBE-2 实测）**

5×5 盘，把 (2,2) 精确放到槽位、其余碎片丢到远处：

```
isSolved(2,2)      = true
planted contains   = false
solvedCount        = 1
resolveSnap didSnap= false didMerge= false
```

`solvedCount`（进度条 / `progressPercent` / 分享卡片 stepCount / `total_snaps` 之外的进度来源）
已经把它算作完成，但 `canSnapCluster`（`puzzle_engine.dart:136-154`）的"无邻居不吸附"规则
正确地拒绝了它。玩家看到进度 +1，却没有吸附音效、没有绿框、碎片还能再拖走。

这是"无邻居不吸附"（WebJigex 手感规则）的**合理设计**，问题在于**进度口径没有跟随**。

**证据 3 —— 已就位但可拖动的碎片（PROBE-11 实测）**

5×5 / 1400px / zoom=2，构造 `#0` 精确在槽位、`#2` 偏离 0.03、两者同簇：

```
#2 isSolved=true   planted=true   锁定条件(planted && dist<=snap)=false
```

`updatePiecesStateAndPriorities` 会把 `#2` 判为未锁定，而 `handlePieceDragStart`
（`jigsaw_puzzle_game.dart:1938-1944`）**只检查 `piece.isLocked`**：

```dart
void handlePieceDragStart(PuzzlePieceComponent piece) {
  if (piece.isLocked || _isSolved) { ... return; }
  _topPriority += 2;
  for (final p in _pieces.values) {
    if (p.clusterId == piece.clusterId) { p.priority = _topPriority; ... }
  }
```

`updateHoldingPiecePosition`（`:1347-1355`）随后按 `relCol/relRow` 重排**整簇**，
于是同簇的已锁定碎片被一起拖离槽位。

**可达性评估（诚实说明）**：在正常引擎路径下，吸附/合并后整簇会精确落在网格上
（`lockEps` 逻辑，`:233-250`），簇内成员到各自槽位的偏移量相同，因此不会出现"半锁半不锁"。
要触发证据 3，必须先破坏集群网格不变量——这正是 G-3 描述的路径。所以 **G-3 是 G-1 的放大器**。

**影响面**：`solvedCount` 同时是进度条分子、`_doSave` 的 `progressPercent`、
分享卡片的 `stepCount`、`ResumeHelper` 的续玩判定依据（`resume_helper.dart:50`）。

**建议**：把 `isSolved` 的容差改为与锁定同源——即由 `JigsawPuzzleGame` 把当前生效的
吸附容差注入状态判定，或反过来把锁定容差改为 `max(solvedEps, snapDist)`；
更彻底的做法是引入单一 `PlacementPolicy`（SSOT），由进度、锁定、通关、`progressPercentOf`
四处共同调用，从结构上消灭多口径。

---

### G-2【中】桌面散落模式按"扫把整理"会覆盖刚分配的干净槽位

**位置**：`jigsaw_puzzle_game.dart:2437-2460`

```dart
p.animateTo(targetPos, duration: 0.25);          // :2452  分配好的散落槽位
updatedPieces.add(statePiece.copyWith(nx: baseNx, ny: baseNy));
...
_pullbackOutOfBoundsClustersAndPieces(animate: true);   // :2460
```

`_pullbackOutOfBoundsClustersAndPieces` 读的是**动画启动前**的 `comp.position`（`:2342-2346`），
越界时计算 `shift`，然后：

```dart
final target = comp.position + shift;
if (animate) { comp.animateTo(target, duration: 0.25); }   // :2389
_screenToNormalized(target, normOut);
updatedPiecesMap[comp.id] = pState.copyWith(nx: normOut[0], ny: normOut[1]);
```

而 `PuzzlePieceComponent.animateTo` 的第一步就是（`puzzle_piece_component.dart:487`）：

```dart
removeAll(children.whereType<MoveEffect>());
```

——**前一个 `MoveToEffect` 被移除**，碎片最终停在"旧位置 + shift"，而不是刚分配的槽位；
`_boardState` 也被写成这个错误坐标。

**触发条件**：把单片拖到窗口边缘。`_clampDragTarget`（`:1279-1294`）只把**主片中心**夹进
安全区，`position.x = center.x - visualW/2` 可以远小于 `_sideMargin`。
例：zoom=2、碎片视觉宽 700px、中心贴到 x=8 → `position.x = -342` → `shift = 350`，
碎片最终偏离槽位 350px，很可能压在其他散落碎片上，并且破坏了"原图邻居不占空间相邻槽位"的约束。

**对照组**：`missingPieceCheck` 在整簇平移前调用了 `comp.clearMoveEffects()`（`:2972`），
说明作者知道这个坑，只是 `organizeTray` 路径漏了。

**建议**：`_pullbackOutOfBoundsClustersAndPieces` 在 `animate: true` 时，或先
`comp.clearMoveEffects()`，或从"待生效的目标位置"而非 `comp.position` 计算 shift；
并在 `organizeTray` 中把 pullback 放到 `animateTo` 之前，或对刚重散落的碎片跳过 pullback。

---

### G-3【中】权威状态从组件瞬时位置派生，未与在途补间动画同步

**位置**：`handlePieceDragEnd`（`:2169-2188`）、`exportSnapshotJson`（`:2558`）、
`_pullbackOutOfBoundsClustersAndPieces`（`:2393`）、`_syncResizeTransform`（`:614/653`）

`handlePieceDragEnd` 对**所有**非托盘碎片重算坐标：

```dart
final updatedPieces = _boardState.pieces.map((p) {
  final comp = _pieces[p.id];
  if (!comp.isInTray) {
    _screenToNormalized(comp.position, out);      // ← 组件瞬时位置
    return p.copyWith(nx: out[0], ny: out[1], clusterId: comp.clusterId, ...);
  }
```

若某碎片此刻正处在 `MoveToEffect` 插值中途，写入的就是中间值而非终点。在途动画来源：

| 动画 | 时长 | 触发点 |
|---|---|---|
| 吸附落位 | 0.15s | `_applySnapSettlement:2066` |
| 托盘重排 | 0.2s | `_realignTrayPieces:1461` |
| 扫把整理 | 0.25s | `organizeTray:2452/2502/2505` |
| 拖拽取消复位 | 0.15s | `cancelPieceDrag:1999` |

**后果**：
1. 对多片集群，会破坏"集群内精确网格相对偏移"不变量
   （`clusterGridInvariantViolation:2850`，容差 1e-6）。
   debug 下 `_debugAssertClusterGridInvariant`（`:2878-2890`）会 `throw FlutterError` → 红屏；
   release 下无 assert，留下状态与视觉撕裂，后续 `relCol/relRow` 重排会把整簇拽到错误位置。
2. 托盘碎片被排除在外（`if (!comp.isInTray)`），所以最常见的 0.2s 托盘重排是安全的 ——
   这也是该缺陷不易被发现的原因。
3. `_syncResizeTransform` 步骤 5 写 `comp.position.setFrom(...)` 时**不**清除在途
   `MoveEffect`，窗口缩放撞上吸附动画时碎片会被动画拉回旧目标。

**可达性**：需要"某碎片处于多片集群 + 处于动画中途 + 玩家在此期间完成另一次落位结算"。
扫把整理（0.25s，全场动画）后立刻拖拽是现实路径；概率不高但非零。
**这是"中等"而非"高"的原因**：窗口窄、动画窗口短。

**建议**：为组件引入 `settledPosition`（动画终点）概念，所有状态派生改读该终点；
或在状态派生前统一对非拖拽碎片调用 `clearMoveEffects()`。

---

### G-4【中】`_mergeAllAdjacentClusters` 存在 O(n³) 复杂度悬崖

**位置**：`puzzle_engine.dart:435-546`

`while (changed)` 包裹 O(n²) 双循环，且**每次成功合并后 `break` 重启整个双循环**
（`:538 break` / `:541 if (changed) break`）。576 片时最坏 575 次重启 × 165k 对比较。

**实测（PROBE-3 / PROBE-8）**：

| 场景 | 24×24 单次 `resolveSnap` |
|---|---|
| 真实散落 + 逐块放置（PROBE-7） | **最长 4.9ms**（全程无违规） |
| 400 片已装配集群落位（PROBE-13） | 30ms |
| 576 片同时网格对齐但整体错位 0.30（PROBE-8） | **849~857ms** |

**诚实结论**：最后一行是**构造场景**。要让一次 drop 触发 575 次级联合并，需要全部碎片
事先彼此精确网格对齐——而引擎自身的合并规则会让它们在更早的一次 drop 就已合并，
所以正常玩法到不了这个状态。我**没有**在正常玩法中复现出卡顿。

但 30ms 的大集群落位（PROBE-13）是可感知的，且 `_mergeAllAdjacentClusters` 内部的
`result.any((p) => p.clusterId == ... && p.isSolved(...))`（`:487-492`）每次都是 O(n) 扫描。

另外 `canSnapCluster`（`:136-154`）是 O(集群成员数 × 4 × 总片数)，
400 片集群 + 576 片总规模 = 92 万次内层比较，每次 drop 都跑。

**建议**：把 `clusterSizes` 之外再维护 `clusterHasSolved` 增量表消除 `result.any`；
用空间哈希（`r*cols+c → clusterId`）替代 `canSnapCluster` 的线性查找；
把 `while(changed)` 重启改为"本轮合并列表 + 队列传播"。

---

### G-5【低】"在托盘区域"存在两套不一致的阈值

| 用途 | 公式 | 位置 |
|---|---|---|
| 松手时判定"是否回托盘" | `piece.position.y >= trayPosition.y - pieceSize.y * 0.25` | `jigsaw_puzzle_game.dart:2096` |
| 组件手势仲裁 / 存档保护 | `pos.y >= trayPosition.y - 20.0` | `jigsaw_puzzle_game.dart:1476` |

**实测（PROBE-14）**：碎片基础高 100/150/200px 时分歧带分别为 5 / 17.5 / 30px。
`pieceSize.y ≥ 100px` 在小网格大窗口下可达（如 3×4 比例 k=2 → 6×8=48 片，
1920×1080 窗口下 `pieceSize.y ≈ 126px`）。

**后果**：`exportSnapshotJson:2550` 用 `isPointInTrayArea` 判定，
若碎片刚被放进托盘但仍处于 0.15s 动画中途、位置落在分歧带内，
会被当作棋盘碎片存档（`_screenToNormalized` 写入棋盘坐标 + `inTray: false`），
读档后该碎片出现在棋盘上而非托盘里。

**建议**：抽 `_isInTrayZone(Vector2 pos)` 单一权威方法，两处共用。

---

### G-6【低】旋转难度整条链路是死代码，且一旦启用会立刻导致无法通关

**证据**：
- `rotationEnabled` 参数一路默认 `false`，`GamePage` 构造 `JigsawPuzzleGame` 时
  **完全没有传该参数**（`game_page.dart:355-379`）；
- `PuzzlePieceComponent.render()`（`:201-303`）**从不读取 `rot`**，
  全文只在 `containsLocalPoint`（`:196`）里用到；
- `PuzzleEngine.rotateCluster`（`:553-595`）、`PieceEdges.rotateClockwise`（`edge_layout.dart:40`）、
  `PieceShape(tipRatio:)`（`piece_shape.dart:76`）均无生产调用方。

**风险**：`resolveSnap:208` 与 `:277` 会因 `rot % 4 != 0` 拒绝吸附/合并。
一旦有人把开关打开，玩家会看到"碎片外观完全正确但怎么拖都不吸附"，且**没有任何旋转 UI**
可以纠正 `rot`（`rotateCluster` 无调用方）→ **该局永久无法完成**。

**建议**：要么删除整条链路，要么补齐渲染旋转 + 旋转交互 + 测试。当前状态是最坏的
——看起来能开，实际开了就坏。

---

### G-7【低】undo / redo / reset 是不可达功能，但持续占用内存

全仓 grep 证实：`undo()`、`redo()`、`canUndo`、`canRedo`、`resetCurrentGame()`
在 `lib/` 与 `test/` 中**没有任何调用方**（仅定义与 `undoManager.record`）。

但 `handlePieceDragEnd:2213` 每次吸附仍会 `undoManager.record(prevState)`，
`UndoManager` 默认保留 30 份完整 `PuzzleBoardState`。24×24 时约 30 × 576 = 17,280 个
`PieceState` 常驻内存，且**永远不会被读取**。

**建议**：要么接上 UI（撤销是拼图游戏的核心预期功能之一），要么摘掉 record 调用。

---

### G-8【低】"通关后由底板渲染整图"的优化从未接线

`PuzzlePieceComponent.hideBorders`（`:76`）的注释写"拼图通关后整体由底板渲染整图，
碎片停止绘制以节省 GPU 算力"，`render()` 也确实 `if (isFilteredOut || hideBorders) return;`。
但全仓唯一赋值点是 `resetCurrentGame` 里的 `..hideBorders = false`（`jigsaw_puzzle_game.dart:1861`），
**没有任何地方置 true**。通关后仍是逐片绘制 576 次 clipPath。

---

### G-9【低】吸附统计被集群规模放大，成就提前达成

`_applySnapSettlement:2079-2080`：

```dart
final snapCount = finalAffectedIds.isNotEmpty ? finalAffectedIds.length : 1;
onPieceSnapped?.call(snapCount);
```

`affectedPieceIds` 包含级联合并卷入的**全部**碎片（`puzzle_engine.dart:532-534`），
既包括真正吸附到槽位的，也包括仅仅在空中对齐合并的。

→ `GamePage._onPieceSnapped`（`:401-408`）把 `count` 同时喂给
`_repo.recordSnapStats(pieceCount: count)` 与
`AchievementService.recordPieceSnapped(count: count)`。

**实测（PROBE-13）**：一次 400 片集群落位 → `affected=400`。
即"累计吸附 100/500/2000 片"三档成就（`achievement_service.dart:284-310`）
可在远少于 2000 次真实放置的情况下达成。

**建议**：`snapCount` 只统计"本步首次进入 `isSolved` 且 `planted`"的碎片。

---

### G-10【低】`_maxZoom` 并非恒为 2.0，相关注释与实测不符

`_dragCenterSafeBounds`（`:1257`）的注释称"当 `_zoom >= 2`（本项目各难度 `maxZoom` 恒为 2.0）"，
并以此论证安全区间不会退化。

**实测（PROBE-12）**：遍历全部预设难度 × 5 种窗口尺寸，`_maxZoom` 取值集合为
`{2.0, 2.053, 2.19, 2.738, 2.464, 3.285, 2.875, 2.075, 2.49, 2.179}`。
例：800×600 窗口 + 24×24 → `pieceMaxSide = 21.9px` → `_maxZoom = 3.285`。

窗口下限正是 `kDesktopMinWindowSize = 800×600`（`main.dart:30`），所以该场景可达。
结论（区间恒为正、不会退化）仍然成立，但**论证前提是错的**，且在 maxZoom=3.285 时
吸附容差会进一步收紧到 `48px / (boardPx * 3.285)`。

---

## 4. 存档 / 进度 / 经济层缺陷

### D-1【中】`.bak` 只在单次 `save` 内回滚，读取失败时没有任何副本可回滚

`SnapshotStore.save`（`snapshot_store.dart:164-227`）与 `saveSync`（`:230-291`）的流程：

```
写 .tmp → 把正式文件 rename 成 .bak → 把 .tmp rename 成正式文件 → 删除 .bak
```

成功后 `.bak` 立即被删（`:197-201` / `:265-269`）。
而读取失败时（`:323-334` / `:364-374`）：

```dart
final isFormat = e is FormatException || e is TypeError;
if (isFormat) { ...; await file.delete(); }
```

`PuzzleBoardState.fromJson` 在下列情况抛 `FormatException`，都会导致**直接删除玩家存档**：
- `pieces.length != rows*cols`（`puzzle_state.dart:240-244`）
- `version < minSupportedVersion`（`puzzle_state.dart:248-252`）

全仓**不存在**任何"读取失败时把 `.bak` 提升为正式文件"的分支。
所以 `.bak` 只是单次 `save` 调用内的回滚手段，对"写入成功但内容损坏"这个真实场景毫无保护。

（另注：`:189-193` 的 `file.rename(bak.path)` 失败被 `catch (_) {}` 静默吞掉，
此时若 `tmp.rename(file.path)` 在 Windows 上成功替换，旧 `.bak` 会成为永不清理的孤儿文件。）

**建议**：读失败时先尝试 `.bak`；或把"删除损坏文件"改为"重命名到 `.corrupt` 保留 N 天"，
让玩家有一次人工恢复机会。

---

### D-2【中】`recordDifficultyCompletion` 落盘失败仍返回 `playCount + 1`

`ProgressStore.save`（`progress_store.dart:272-294`）在磁盘写失败时**回滚内存并吞掉异常**
（不 rethrow）。但 `recordDifficultyCompletion`（`:346-434`）在 `await save(next)` 之后
仍返回基于 `updatedRecord`（`playCount = oldRecord.playCount + 1`）构造的结果：

```dart
await save(next);                      // :419  失败时只回滚内存
...
return DifficultyRecordUpdateResult(
  stars: stars,
  record: updatedRecord,               // :428-434  playCount 已 +1
  ...
);
```

`GamePage._handleSolved:711` 用它判定首次通关：

```dart
isFirstCompletion: updateResult.record.playCount <= 1,
```

磁盘持续故障期间，每次通关都会被判为"首次通关"从而拿到**全额** `rewardFor(tier, stars)`
而非复玩保底 20%。

**建议**：`save` 返回 `bool`（或抛），`recordDifficultyCompletion` 据此决定
`isFirstCompletion`；或把 `playCount` 的判定改为读盘后确认。

---

### D-3【中】`consumeHint` 非原子，且提示按钮无重入保护

`EconomyService.consumeHint`（`economy_service.dart:205-233`）是典型的读-改-写分离：

```dart
if (hintCoupons > 0) {
  await putRaw(_box, _keyCoupons, hintCoupons - 1);   // 读和写之间有 await
  return true;
}
```

`GamePage._onHintPressed`（`:785-812`）在 `await consumeHint(...)` 期间不锁 UI，
提示按钮 `onPressed`（`:1152`）也没有 `_isChargingHint` 之类的重入闸门。

**后果**：双击（或快速连点）提示 → 两次 `consumeHint` 并发 → 只扣一次费/券，
但 `_game?.hint()` 执行两次（`hintsUsed += 2`，多放一块提示片，且 `onMoveMade` 记两步）。
反向的伤害（多扣费）不会发生，所以这是**对玩家有利**的漏洞，但仍是明确的并发缺陷。

**建议**：`EconomyService` 加串行锁（可直接复用 `game_repository.dart:783` 的
`_snapStatsLock` 模式）；`GamePage` 加重入闸门。

---

### D-4【低】`daily_solved` 计数无按图去重

`AchievementService.onPuzzleSolved`（`achievement_service.dart:458-474`）中，
3 星用了按 `canonicalId` 去重的 `addStarred`（`:459-464`），但每日/自制是裸自增：

```dart
if (puzzleType == 'daily') { await _store.incrementCounter('daily_solved'); }
if (puzzleType == 'custom') { await _store.incrementCounter('custom_solved'); }
```

成就 `daily_7`（`:343-351`）描述为"累计完成 7 次每日挑战"，但同一张日卡重玩 7 次即可达成。
（`custom_solved` 描述为"完成 5 次自制拼图"，语义上次数计数可接受，不算缺陷。）

另外：成就领奖走 `addCoins(..., bypassCap: true)`（`:565`）绕过 `kDailyCoinCap=200`。
这是**明确的设计决策**（注释已写明），不算缺陷，但意味着 25 项成就共 3680 币完全不受日上限约束。

---

### D-5【低】`default_level` 孤儿快照键仍可被写出

`PuzzleBoardState.effectiveCanonicalId`（`puzzle_state.dart:401-402`）在 `canonicalId` 为空时
回落到 `levelId`，而 `levelId` 默认值就是 `'default_level'`（`:200`）。
`SnapshotStore.save/saveSync` 的空值守卫（`snapshot_store.dart:168-173` / `:243`）
只拦空串，拦不住 `'default_level'`。

`GamePage._flushSync:460-466`：

```dart
final canonicalId = _canonicalIdForSave();
var state = PuzzleBoardState.fromJson(map);
if (canonicalId.isNotEmpty) { state = state.copyWith(canonicalId: canonicalId); }
...
SnapshotStore.instance.saveSync(state);              // ← 在守卫之外
if (canonicalId.isNotEmpty) { _repo.updateGenericProgress(...); }
```

四个 id（canonicalId / levelIndex / dailyDateStr / customId）全空的 GamePage
会写出一个 `default_level` 孤儿快照文件，且**永远不会被任何入口读到**。

（`choose_difficulty_sheet.dart:493` 已经用 `SnapshotStore.difficultyKeyFor` 走正确路径，
说明该问题在难度选择页已修，仅剩 GamePage 这一条路径。）

---

### D-6【低】`reconcileSnapshots` 只挂在 `resetAllData`，启动路径不对账

`ProgressStore.reconcileSnapshots` 仅在 `game_repository.dart:867`（`resetAllData` 内）被调用。
`main.dart` 的启动 Group1（`:173-180`）不跑它。
因此"索引 `hasSnapshot=true` 但文件已丢失"的记录只能等到玩家点进该关卡、
触发 `ResumeHelper.fetchResume` 的自愈分支（`resume_helper.dart:64-71`）才被纠正。
若玩家从不点进那一关，卡片会一直显示一个假的进度百分比。

---

### D-7【低】`fetchResume` 对 `percent >= 100` 直接返回 null，不清理文件与索引

`resume_helper.dart:72`：

```dart
if (percent >= 100 || snapshot.isSolved) return null;
```

此处既不删快照文件，也不清 `ProgressStore` 的 `hasSnapshot` / `activeDifficultyKey`。
与 D-6 叠加的后果是：这类快照成为**既不可续玩、也不被清理、还让卡片显示 100%** 的僵尸记录。

**可达性诚实说明**：`percent` 由 `SnapshotStore.progressPercentOf`（`:476-481`）按
逐片 `isSolved` 计数，100% 要求全部碎片 `isSolved`。正常路径下达成全盘 `isSolved` 的那一刻
`_applySnapSettlement:2084-2090` 会同步置 `_isSolved=true` 并调 `onSolved()`，
而 `_handleSolved` 第一件事就是 `_saveDebounce?.cancel()`（`game_page.dart:596`），
所以 pending 的 100% 保存会被取消。**我没能构造出常规路径**。
但这与 G-1 的膨胀口径耦合：一旦 G-1 那类"全部 `isSolved` 但未锁定"的状态被存档，
就会命中这条无出口的路径。属于**潜在陷阱**而非已确认缺陷。

---

## 5. 工程质量评估

### 5.1 规模信号（实测行数）

| 文件 | 行数 | 说明 |
|---|---|---|
| `lib/game/jigsaw_puzzle_game.dart` | **2996** | god class，约 58 个方法；`_computeLayout` 250 行、`onLoad` 160 行、`_applyBoardState` 174 行、`organizeTray` 117 行 |
| `lib/pages/game_page.dart` | 1517 | 计时 + 存档调度 + 指针手势 + 结算 四合一 |
| `lib/logic/engine/puzzle_engine.dart` | 668 | `resolveSnap` 单函数 **L165→L412 ≈ 247 行** |
| `test/game_layout_test.dart` | **2915** | 64 个用例，单文件规模是 `puzzle_engine.dart` 的 4.4 倍 |
| `lib/pages/tabs/my_center_tab_view.dart` | 1321 | 单个 `build()` 约 770 行 |
| `lib/widgets/choose_difficulty_sheet.dart` | 1108 | 单个 `build()` 约 615 行 |

`docs/architecture-debt-refactor-roadmap-v2-20260912.md` 中记录的 P3-1（god class）、
P3-2（巨型 `build()`）、P3-3（O(n³) 合并循环）三项，本次复核**仍未落地**。

### 5.2 静态检查

- `flutter analyze`：**No issues found**（本次实跑）。
- 基线为 `very_good_analysis 10.3.0`（精确锁版），`strict-casts` / `strict-raw-types` /
  `strict-inference` 全开，配置本身是严格的。
- 但 `lib/` 下有 **98 处** `// ignore:` / `ignore_for_file`（约 85 处为
  `avoid_catches_without_on_clauses`），且**未启用 `--fatal-infos`**。
  "0 error / 0 warning" 的实际门槛因此偏低。

### 5.3 测试

- `flutter test`：**395 通过 / 8 跳过 / 0 失败**（本次实跑）。
- 覆盖质量最高的核心区：`lib/logic/geometry/*`（10 例）+
  `PuzzleEngine.resolveSnap` / `canSnapCluster` / `computePlantedPieceIds`（13 例）。
- `test/test_helper.dart` 用独立临时目录 + `forTest` 注入隔离 Hive/单例，规范扎实。
- **空白（grep 证实 0 命中）**：
  - 两个 `render()`（`:41` / `:75`）——所有测试都 `new JigsawPuzzleGame(...)` 直构，
    从不经过 `GameWidget`，**渲染管线从未在自动化中执行过一次**；
  - 输入事件分发层：`onDragUpdate`、`onMouseMove`、`onTapDown`、`scrollTray`；
  - `updatePieceVisibility`、`effectiveSnapDistance`、`_clampDragTarget` 无直接断言
    ——**恰好是 G-1 / G-5 所在的那几行**；
  - `lib/logic/rendering/linen_texture_manager.dart`（157 行）零测试零 import。
- `lib/` 100 个 dart 文件中 **28 个从未被任何测试 import**，其中
  `update/`（3 个）、`share_card_generator`、`online_image_picker_page`、
  `app_logger`、`boot_gate_page`、`pack_levels_page` 属完全无覆盖。
- **静默假绿**：3 个 jigsawdata 验证测试在条件不满足时 `debugPrint('SKIP'); return;`，
  无断言却计为通过（`jigsawdata_local_verify_test.dart:35`、
  `jigsawdata_remote_verify_test.dart:84`、`jigsawdata_three_channel_verify_test.dart:271`）。
- **无 CI**：`.github/` 下 0 文件。`scripts/release.py` 只跑 `flutter build`，不跑 analyze/test。
  唯一自动化测试门禁是 `scripts/publish/check_local.py:98` 调用单个测试文件，
  且可用 `--skip-flutter` 跳过。质量门禁 100% 依赖人工。
- **无覆盖率工具**，pubspec 无相关依赖。

### 5.4 其他

**release 下每次拖拽都产生文件 I/O。** `AppLogger.init:79` 在非 debug 时把根级别设为
`Level.INFO`，而 `_fileEnabled` 为 true、`_writeToConsole:232-235` 对 INFO+ 执行 `print()`。
`handlePieceDragEnd`（`:2100`）、`resolveSnap`（`:253` / `:371` / `:399`）、
`_pullbackOutOfBoundsClustersAndPieces`、`missingPieceCheck` 都用 `AppLogger.*.info`
记录常规事件（这两个文件共 21 处 `.info` 调用点），一次落位通常产生 2~4 行。
这些日志的字符串在调用点就完成插值（不受级别惰性保护）。
建议把逐次拖拽的 trace 降为 `fine`，只保留异常与里程碑为 `info`。

---

## 6. 死代码与未完成功能汇总

| 项 | 位置 | 状态 |
|---|---|---|
| 旋转难度全链路 | `puzzle_engine.dart:553` / `edge_layout.dart:40` / `piece_shape.dart:76` / `puzzle_piece_component.render` | 无生产调用；打开即坏（G-6） |
| undo / redo | `jigsaw_puzzle_game.dart:2585/2596` | 无 UI 入口，仍持续占用内存（G-7） |
| `resetCurrentGame` | `jigsaw_puzzle_game.dart:1797` | 无调用方 |
| `hideBorders` | `puzzle_piece_component.dart:76` | 永不置 true（G-8） |
| `EdgeCurveDescriptor.maxOverhangRatio` | `edge_curve.dart:309-312` | `Overhang.fromEdges` 用的是 `standardTabRatio` 常量，此 getter 无调用方 |
| `PuzzleBoardState.mainAssemblyPieceIds` / `clusterCount` | `puzzle_state.dart:378 / 357` | 全仓（lib + test）零调用方 |
| `_seed` 的 `generateScatterState` 语义 | `puzzle_engine.dart:30-76` | `createInitialState` 算出的 nx/ny 在 `onLoad:374-388` 被整体覆盖，引擎的打散坐标是废算 |

---

## 7. 修复优先级建议

### P0（建议本轮处理）

1. **G-1 统一"就位"判据**。这是唯一一条"高"级别缺陷，也是唯一一条玩家能直接看到
   （进度条与实际装配脱节）的缺陷。最小改动方案：把
   `effectiveSnapDistance()` 的结果注入 `isSolved` 判定，或把锁定容差改为
   `max(solvedEps, snapDist)`；同时给 `snap_algorithm_test.dart` 补一条
   "生产容差下 isSolved ⟺ planted" 的回归断言。
2. **G-2 / G-3 让状态派生与动画解耦**。给 `PuzzlePieceComponent` 增加
   `settledPosition`（动画终点），`handlePieceDragEnd` / `exportSnapshotJson` /
   `_pullback*` 全部改读它。改动集中、收益覆盖 3 条缺陷。

### P1

3. **D-1 给存档加真正的回滚**：读失败时先试 `.bak`；或把损坏文件重命名为 `.corrupt` 保留。
4. **D-2 / D-3 修并发**：`ProgressStore.save` 返回成功标志；
   `EconomyService` 加串行锁 + `GamePage` 提示按钮加重入闸门。
5. **补最小 CI**：`.github/workflows/ci.yml` 跑 `flutter analyze` + `flutter test`；
   给 `scripts/release.py` 加 analyze/test 前置。
6. **补三条缺失的关键测试**：`effectiveSnapDistance` 的生产容差表、
   `_clampDragTarget` 的边界、`updatePieceVisibility` 的筛选态。
   这三处正是 G-1/G-5 的所在地。

### P2

7. **G-4 优化合并循环**：增量维护 `clusterHasSolved`；用空间哈希替换 `canSnapCluster` 的线性查找。
8. **G-6 / G-7 / G-8 处置死代码**：要么接线（撤销按钮、旋转交互、通关整图渲染），
   要么删除。当前"看起来能用、打开就坏"的状态最危险。
9. **D-5 / D-6 / D-7 收口存档键与对账**：`main.dart` 启动跑 `reconcileSnapshots`；
   `SnapshotStore` 显式拒绝 `cid == 'default_level'`；`fetchResume` 返回 null 前清理。
10. **日志降级**：逐次拖拽的 trace 从 `info` 降到 `fine`。

### P3

11. 拆分 `jigsaw_puzzle_game.dart`（2996 行）：至少把 `_computeLayout`、
    `_applyBoardState`、`organizeTray`、桌面散落槽位分配抽成独立 mixin/类。
12. 拆 `test/game_layout_test.dart`（2915 行）为核心逻辑 / 布局 / 交互三份。
13. 把 3 个 jigsawdata 静默跳过改成 `skip:` 标记，让跳过在报告里可见。

---

## 8. 附：本次审查未能覆盖的范围（诚实声明）

- **未做真机/真窗口手动游玩验证**。所有交互类结论（G-2 的 350px 偏移、G-3 的动画竞态、
  G-5 的托盘分歧带）都是**代码路径推演 + 数值实测**，未经真人操作复现。
  报告已对每条标注可达性评估与置信度。
- **未审查渲染像素正确性**（卡扣曲线与原图的 1:1 对齐、凸头遮挡顺序、阴影观感）。
  这需要 `GameWidget` 级截图对比测试，当前仓库不具备该能力（见 5.3）。
- **未审查 `studio/`（Python 素材工作室）、`scripts/`（构建发布脚本）、
  `update/`（自更新，含安装器与 SHA256 校验）**。其中 `update/` 零测试覆盖，
  建议单独立项审查。
- **`lib/logic/content/` 内容管线**只做了抽样阅读（canonicalId 拼接、原子替换、
  红线保留有测试覆盖），未逐行审查五个 pipeline 的完整一致性。
- 未审查 l10n 资源完整性（`slang` 生成的 `strings_*.g.dart` 已排除在 analyze 之外）。
