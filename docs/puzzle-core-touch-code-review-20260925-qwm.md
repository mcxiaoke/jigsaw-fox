# 拼图核心逻辑与触摸处理专项审查（2026-09-25，QwenWork 产出）

> 审查范围：`lib/game/jigsaw_puzzle_game.dart`、`lib/game/puzzle_piece_component.dart`、
> `lib/logic/engine/puzzle_engine.dart`、`lib/logic/engine/undo_manager.dart`、
> `lib/logic/models/puzzle_state.dart`、`lib/logic/geometry/*`、
> `lib/pages/game_page.dart`（手势部分）。
> 性质：纯代码审查，未改动任何代码。所有结论均给出文件:行号证据链。

## 结论摘要

整体架构质量高：吸附数学、集群合并、公母扣几何、快照兼容层经逐项验算均正确。
发现 **4 个确认 BUG**（1 中、3 低-中）与 **3 项设计风险**。
其中最重要的是 `missingPieceCheck` 可撕裂多片集群——它是全仓唯一破坏
"集群内精确网格相对偏移"不变量的代码点，并连锁击穿"已锁定碎片不可移动"承诺。

---

## 一、确认 BUG（代码可证）

### BUG-1【中】missingPieceCheck 撬单块成员，撕裂多片集群

- 位置：`lib/game/jigsaw_puzzle_game.dart:2751-2810`
- 现象：`missingPieceCheck` 对每个越界未拼碎片**单独** `clamp` 回视口并只更新该片
  `nx/ny`（2795-2807），没有像 `_pullbackOutOfBoundsClustersAndPieces`（2214）那样
  按集群外接包围盒整体原子平移。
- 触发条件：剩余未拼碎片 ≤ 2 且某集群成员越出视口超过自身可视尺寸一半
  （拖拽限位按设计允许集群成员伸出视口，见 `_clampDragTarget` 注释 1208-1227，
  所以"把 2 片集群推到屏幕边缘松手"即可触发）。
- 后果链（关键）：
  1. 视觉撕裂：同集群两片分离。
  2. **破坏集群偏移不变量**：全体系依赖"集群成员间恒为精确网格相对偏移"
     （由 resolveSnap 阶段二 293-319 与级联合并 511-519 的"平移到精确对齐"归纳保证；
     由此可推出"一个集群要么全就位、要么全未就位"，锁定与解锁永远不会混杂）。
     `missingPieceCheck` 是唯一单独平移成员的破坏点。
  3. 撕裂后若玩家拖动另一成员触发槽位吸附（resolveSnap 阶段一整簇平移），
     被撬走的成员带着偏移误差永久偏离槽位，永远无法锁定/与真实邻居合并。
  4. 进一步：撕裂造成"同一集群内已锁定+未锁定混杂"，此后抓取未锁定成员会把
     **已锁定（planted）碎片拖离槽位**（`startHoldingPiece` 1193-1206 与
     `updateHoldingPiecePosition` 1303-1311 均不检查集群内是否含 isLocked 成员），
     进度条回退，击穿"已植入装配体不可移动"的设计承诺（引擎侧注释 95-99、131-135）。
- 修复方向：missingPieceCheck 检测到越界成员时按整簇包围盒平移（复用
  `_pullbackOutOfBoundsClustersAndPieces` 的逻辑）；或在循环前按 clusterId 分组。

### BUG-2【低-中】托盘滚轮双路径重复滚动（实际速度 1.6 倍）

- 位置：`lib/pages/game_page.dart:986-1005`（外层 `Listener.onPointerSignal`）与
  `lib/game/jigsaw_puzzle_game.dart:1155-1166`（Flame `ScrollDetector.onScroll`）。
- 证据：`PointerSignalEvent` 会广播到 hit-test 路径上的**所有** Listener；
  GamePage 外层 Listener（`behavior: translucent`，1286 行）与 Flame GameWidget
  内部 Listener（flame-1.38.0 `gesture_detector_builder.dart:189-201`，已实测源码确认
  转发 `PointerScrollEvent` → `game.onScroll`）位于同一条路径。
- 现象：滚轮/触摸板在托盘区域滚动时，两处各自执行一次
  `scrollTray(delta * 0.8)`，托盘滚动速度翻为 1.6 倍。两处还各自维护了一份
  几乎相同的托盘命中判定（GamePage 992 行无下界、game 1159-1160 行有上下界），
  属明显的重复代码漂移隐患。
- 修复方向：删除 `JigsawPuzzleGame.onScroll`（保留 GamePage 单一入口），
  或 GamePage 只处理缩放、托盘滚动完全交给 Flame 层。

### BUG-3【低-中】持有碎片期间滚轮缩放 → 集群撕裂（click-to-pick 下可持续）

- 位置：`lib/pages/game_page.dart:1000-1003`（缩放分支无 `holdingPiece` 守卫）→
  `zoomAt` → `_updateBoardTransform`（`lib/game/jigsaw_puzzle_game.dart:1675-1699`）。
- 证据：`_updateBoardTransform` 只跳过 `comp.isDragging` 的碎片（1691）；
  但拖拽/吸附抓取只给**主片**置 `isDragging = true`（`startHoldingPiece` 1203），
  集群其他成员未标记 → 被重置回**拖拽前**的 `pState.nx/ny` 坐标并强制 `_zoom` 缩放，
  与停留在光标处的主片视觉撕裂。`_syncResizeTransform`（508-511）同样只跳过主片，
  拖拽中改窗口尺寸同理。
- 影响：鼠标拖拽（按住+滚轮）为瞬态撕裂（下次 move 自愈）；
  **click-to-pick 模式下滚动缩放后不动鼠标则撕裂持续存在**。持有主片的 scale
  也不会随 `_zoom` 更新，锚点对位漂移。
- 修复方向：`_updateBoardTransform` / `_syncResizeTransform` 跳过整个 holding 集群
  （`clusterId == holdingPiece.clusterId`）；或给集群成员统一置位标记。

### BUG-4【低】tabletop/tray 模式运行中翻转 → 托盘碎片搁浅失踪

- 位置：`isTabletop` 依赖运行时视口（`jigsaw_puzzle_game.dart:240-242`：
  `scatterMode == 'tabletop' && (size.x > 450 || size.y > 450)`）；
  `_syncResizeTransform`（450-648）不处理模式翻转。
- 证据链：设置页可选 tabletop（`settings_page.dart:174-182`）。当 tabletop 用户把窗口
  缩到 <450×450（isTabletop 翻为 false）再放大回去（翻为 true）时：
  翻回 true 的那次 resize 中，`isInTray == true` 的碎片走 else 分支（513-519）被摆到
  **托盘哨兵坐标 `ny ≥ 2.0` 对应的屏幕位置（视口外）**；随后步骤 6 的越界收拢明确跳过
  `isInTray` 碎片（538-546），且 tabletop 模式托盘背景不渲染 → 这些碎片永久搁浅在
  视口外不可交互，只能靠"扫把整理"（organizeTray 会强制 `isInTray = false` 重散落，
  2356）、undo 或 hint 找回。快照恢复路径 `_applyBoardState` 反而正确处理了模式切换
  （needsRealign，2524-2533），说明 resize 路径是遗漏而非设计。
- 触发窄（需窗口跨越 450 阈值两次），但属于状态机漏洞；建议 resize 时检测
  isTabletop 翻转并走与 `_applyBoardState` 相同的重散落逻辑。

---

## 二、设计风险（当前不触发，判断性结论）

### RISK-1 旋转功能是半成品，一旦启用即渲染/命中错位

- `rotationEnabled` 全仓无启用路径（GamePage 构造未传，默认 false）；
  引擎侧逻辑完备（初始随机 rot、旋转簇 `rotateCluster`、旋转对齐判定、
  `PieceShape.containsLocalPoint` 233-251 的逆向旋转换算均正确）；
  但**渲染层从未旋转**：`PuzzlePieceComponent.render` 无 `canvas.rotate`，
  组件 `angle` 全仓无赋值，`rotateCluster` 无任何调用方。
- 若未来开启：碎片显示不旋转、命中区域却按旋转计算 → 点击/拖拽区域与视觉不符。
  建议要么补齐渲染（angle/旋转采样）再启用，要么删除死代码路径。

### RISK-2 effectiveSnapDistance 的"48px 硬上限"对非正方形棋盘是各向异性的

- `jigsaw_puzzle_game.dart:1468-1476`：阈值除以 `min(boardSize.x, boardSize.y)`，
  宽棋盘 x 方向的实际屏幕吸附半径 = 48 × boardSize.x/minBoardPx > 48px。
  注释宣称"屏幕像素吸附半径恒定"不严谨。归一化空间各向同性是原引擎口径的延续，
  非手感 BUG，但注释应修正。

### RISK-3 "集群精确网格偏移"不变量无防护

- 该不变量是锁定判定（锁定 ⟺ 精确槽位）、"整簇全就位/全未就位"、
  集群拖拽按 `relCol/relRow` 重排（1306-1310）共同依赖的隐含基石，
  却没有任何 debug 断言。BUG-1 正是静默破坏它的实例。
  建议在 debug 模式对每个集群断言成员间偏移为网格整数倍。

---

## 三、已核查无问题的关键点（验算记录）

1. **resolveSnap 三阶段数学**：阶段一槽位吸附平移量、阶段二 expected/actual 偏移与
   对齐方向（aToB/bToA 两种平移符号）、级联 `_mergeAllAdjacentClusters` 的
   平移-重映射-尺寸增量维护，逐项验算正确；合并后相对偏移精确归零。
2. **定海神针规则**两处实现（阶段二 299-319 与级联 487-507）一致：
   已就位者绝对不动，同状态按规模裁决。
3. **锁定一致性**：`updatePiecesStateAndPriorities`（1813-1858）的锁定条件
   `planted && dist <= snapDistLock` 中，planted 本身要求 `isSolved`
   （容差 min(0.035, 0.2/N)）恒强于随 zoom 变化的 snapDistLock，
   不存在"缩放导致已锁碎片解锁"的抖动；锁定即强制对齐槽位坐标。
4. **computePlantedPieceIds**：BFS + 惰性 id 索引（`PuzzleBoardState._index`）正确，
   O(n) 无重复访问。
5. **canSnapCluster**（136-154）：边缘片触边 / 邻接已植入装配体二判据与注释的
   WebJigex 规则一致；与锁定判定同源。
6. **边缘几何**：`EdgeLayout.edgesFor` 的对偶取边（top 取上邻 complementary 等）
   保证公母扣 100% 契合；`Overhang` 裕量（Tab 0.35 / Blank 0.15）经曲线极值验算
   充分（Blank 最大外扩 ≈0.10-0.11 < 0.15，Tab 峰值 0.3446×depthScale ≤ 0.35）；
   bend=false 镜像映射的 ctrl/anchor 索引换算逐点核对单调递增、from 不翻转，正确。
7. **托盘手势歧义状态机**（`puzzle_piece_component.dart:88-91, 336-432`）：
   pending → 滚动锁定/向上拖出的阈值判定、dragEnd/cancel 的完整清理、
   isPinching 中断路径，逻辑自洽；拖出后 anchor 以拖出点重算，光标锁定正确。
8. **命中测试**：`containsLocalPoint` 用 `isFilteredOut` 短路 + 贝塞尔精确拾取，
   rot 逆向旋转向量验算正确（仅 RISK-1 所述渲染缺失使其暂不可达）。
9. **快照往返**：托盘哨兵 `ny ≥ 2.0` 写入/读取一致；`scatterMode`/`trayOrder`
   经 extra 透传；尺寸不匹配防御（2513-2522）、版本兼容（v2/v3）正确；
   拖拽中/锁定碎片的导出保护（2442-2464）完备。
10. **UndoManager**：栈管理、redo 清空时机、容量上限正确（redo 增长受 undo 次数约束）。
11. **单指平移**（GamePage 949-957）：zoom>1 + 非拖拽 + 区域守卫，
    与 Flame DragCallbacks 无竞技场冲突（game 侧已刻意移除 onPanUpdate，1343-1347）。
12. **双指捏合**：第二指落下即取消持有/拖拽（908-910），isPinching 经 60ms 延迟复位
    防抖；三指时 base 以 2 指重算，无崩溃路径。

---

## 四、优先级建议

| 编号 | 严重度 | 修复成本 | 建议 |
|------|--------|----------|------|
| BUG-1 | 中 | 低（复用 pullback 逻辑） | 尽快修 |
| BUG-3 | 低-中 | 低（跳过 holding 集群） | 尽快修 |
| BUG-2 | 低-中 | 极低（删一处重复） | 顺手修 |
| BUG-4 | 低 | 中（需模式翻转重散落） | 排期修 |
| RISK-1 | 潜伏 | — | 启用旋转前必须补渲染，或删除死代码 |
| RISK-3 | 防护性 | 极低（debug 断言） | 建议加 |
