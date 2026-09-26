# 拼图核心功能与触摸处理复审报告

> 复审时间：2026-09-26 09:12:20 GMT+8
> 复审范围：`lib/game/jigsaw_puzzle_game.dart`、`lib/game/puzzle_piece_component.dart`、`lib/pages/game_page.dart`、`lib/logic/engine/puzzle_engine.dart`、`lib/logic/models/puzzle_state.dart` 及相关测试
> 复审性质：代码审查与测试验证；本次未修改业务代码
> 工作树状态：复审开始时无未提交变更

## 1. 总体结论

上一次专项审查发现的 4 个主要问题已经在近期提交 `f1a1722` 中完成处理，本次复核未发现新的高概率核心吸附或集群合并错误。

当前验证结果：

- `flutter analyze`：`No issues found!`
- 拼图核心与布局专项测试：`77 passed`
- 全量 `flutter test`：`391 passed / 8 skipped / 0 failed`

当前仍建议关注 4 项风险：

1. 生命周期/系统中断后，吸附抓取状态可能残留（中风险，建议优先处理）。
2. 托盘碎片跨组件滑动时仍存在手势竞技场边界风险（低到中风险）。
3. Flame `TapCancelEvent` 没有在碎片组件中专门清理（低风险）。
4. 旋转功能仍未完成渲染闭环（当前不可达，未来启用前必须处理）。

## 2. 已确认已修复的问题

### 2.1 托盘滚轮重复处理与坐标错位

`JigsawPuzzleGame` 已移除 `ScrollDetector` 和游戏侧 `onScroll`，滚轮统一由 `GamePage._onPointerSignal` 分发：

- `lib/pages/game_page.dart:986-1014`
- `lib/game/jigsaw_puzzle_game.dart:1183-1189`

当前托盘命中判断同时检查上下边界，并按 `abs(dx)` 与 `abs(dy)` 较大轴滚动。该改动避免了外层 `Listener` 与 Flame 内部监听重复滚动，也避免了全局坐标与画布局部坐标不一致导致的“托盘滚动区同时缩放棋盘”问题。

### 2.2 持有集群期间缩放导致撕裂

当前缩放和窗口变化会跳过整个 holding 集群，而非只跳过主片：

- `lib/game/jigsaw_puzzle_game.dart:515-531`
- `lib/game/jigsaw_puzzle_game.dart:1724-1732`

缩放或 resize 完成后，通过 `_refreshHoldingClusterLayout()` 使用主片位置和抓取锚点反推光标，重新计算整簇位置与缩放：

- `lib/game/jigsaw_puzzle_game.dart:1663-1675`
- `lib/game/jigsaw_puzzle_game.dart:1740-1755`

专项回归测试已覆盖 click-to-pick 抓取集群后缩放且不移动鼠标的场景。

### 2.3 残局防丢撕裂集群

`missingPieceCheck()` 已改为按 `clusterId` 聚合、每簇只处理一次，并对集群执行原子平移：

- `lib/game/jigsaw_puzzle_game.dart:2865-2960`

同时会跳过含已就位成员的集群，并只清理 `MoveEffect`，避免拆散集群或取消缩放动画。回归测试已验证多片集群被推至屏幕边缘后仍保持网格相对偏移。

### 2.4 tabletop/tray 运行时模式翻转

`isTabletop` 当前只取设置值：

```dart
bool get isTabletop => scatterMode == 'tabletop';
```

位置：`lib/game/jigsaw_puzzle_game.dart:247-255`

桌面端同时设置了最小窗口尺寸，避免窗口缩放过程中进入不适合当前布局的极小视口。已有回归测试覆盖极小窗口 resize 后模式不翻转的场景。

## 3. 当前仍存在的潜在问题

### 3.1 生命周期/PointerCancel 后可能残留吸附抓取状态

**严重度：中风险。**

页面生命周期处理位于：

- `lib/pages/game_page.dart:117-130`

进入 `inactive`、`paused`、`hidden` 或 `detached` 时，当前逻辑会停止声音、上报时间并同步保存，但没有明确执行：

- `_game?.cancelHoldingPiece()`
- `_game?.cancelAllPieceDragging()`
- `_pointerPositions.clear()`
- 重置 `_baseDistance`
- 重置 `_game?.isPinching`

指针状态维护位于：

- `lib/pages/game_page.dart:87-91`
- `lib/pages/game_page.dart:896-984`

常规双指、右键和 ESC 路径都有取消逻辑，但系统切后台、窗口失焦、系统手势抢占或输入设备取消时，页面层和 Flame 层的取消回调不一定同时到达。

**可能表现：**

1. 用户抓取一块碎片后切后台或切换窗口；
2. 返回游戏时 `holdingPiece` 或 `isDragging` 仍为非空/为 true；
3. 下一次点击可能直接放下旧碎片，而不是拾取新碎片；
4. `_pointerPositions` 残留还可能使下一次手势被误判为双指操作。

**建议：**

抽出幂等的 `_cancelActivePointerInteraction()`，在生命周期进入非活动状态时统一清理 holding、dragging、pointer map、pinch 状态；增加生命周期切换和系统取消输入的回归测试。

### 3.2 托盘跨组件滑动仍有手势竞技场边界风险

托盘碎片和托盘背景都实现了 Flame `DragCallbacks`：

- `lib/game/puzzle_piece_component.dart:336-432`
- `lib/game/jigsaw_puzzle_game.dart:82-89`

页面层同时通过外部 `Listener` 处理放大后的单指棋盘平移：

- `lib/pages/game_page.dart:947-957`

当前用 `isDraggingAnyPiece` 阻止棋盘平移，常规场景逻辑自洽。但“从托盘碎片按下，移动到碎片外，再继续横向/斜向/向上移动”的跨组件场景，仍依赖 Flame 手势竞技场持有者，代码中没有真实 Widget 手势回归测试。

托盘碎片的方向判定当前为：

- 总位移小于 `8px`：继续等待；
- 向上位移至少 `12px` 且垂直分量大于水平分量 `1.2`：判定拖出；
- 其他情况：判定为托盘滚动；
- 位置：`lib/game/puzzle_piece_component.dart:378-424`

建议增加真实触摸/Widget 或集成测试，覆盖跨碎片边界、斜向滑动、快速上滑和 PointerCancel。

### 3.3 没有专门处理 Flame `TapCancelEvent`

`PuzzlePieceComponent` 当前覆写了 `onTapDown`、`onDragStart`、`onDragUpdate`、`onDragEnd` 和 `onDragCancel`，但没有覆写 `onTapCancel`：

- `lib/game/puzzle_piece_component.dart:309-466`

Flame 的 `TapCallbacks` 明确区分 `onTapCancel` 与 `onDragCancel`。在某些系统取消轻点识别的路径中，可能出现 `TapDown -> TapCancel`，而不经过完整拖拽取消流程。

建议增加一个幂等取消入口，统一清理：

- `_pendingTrayDrag`
- `_trayDragStartPos`
- `_trayScrollLocked`
- `isDragging`
- 当前组件对应的 `holdingPiece`

实现时要避免 `cancelHoldingPiece()` 与 `cancelPieceDrag()` 重复触发恢复动画或重复回调。

### 3.4 旋转能力尚未形成完整闭环

当前 `rotationEnabled` 默认关闭，项目没有启用入口，故暂不构成当前可达 bug。但若未来打开旋转难度，存在视觉与命中不一致：

- 命中测试已经根据 `rot` 进行逆向旋转：`lib/logic/geometry/piece_shape.dart:228-250`
- 渲染流程没有相应的 `canvas.rotate` 或组件角度更新：`lib/game/puzzle_piece_component.dart:199-303`
- `PuzzleEngine.rotateCluster()` 当前没有业务调用方：`lib/logic/engine/puzzle_engine.dart:553-595`

未来启用前必须同时完成旋转渲染、纹理采样、集群旋转后的尺寸/位置处理和手势命中回归测试。

## 4. 已核查未发现问题的路径

本次复核确认以下路径逻辑和测试结果正常：

- 棋盘槽位吸附与正交邻居合并；
- 孤立内部碎片不误吸附锁定；
- 边缘装配体连接规则；
- 级联合并后的精确网格相对偏移；
- 托盘碎片与棋盘碎片隔离；
- 托盘滚轮和棋盘缩放分流；
- 双指捏合时取消碎片抓取；
- 持有集群期间缩放与窗口 resize；
- 残局防丢的整簇原子平移；
- 快照尺寸不匹配防护；
- Undo/Redo 后状态与组件同步；
- 窗口变化时缩放、平移和碎片位置同步；
- 视口越界收拢；
- 集群网格不变量调试检查；
- 托盘排序、拖出、放回与扫把整理。

## 5. 建议处理顺序

1. 增加生命周期和 PointerCancel 的统一取消逻辑；
2. 增加托盘跨组件真实触摸手势回归测试；
3. 增加 `onTapCancel` 防御处理；
4. 旋转功能启用前补齐渲染闭环。

本次不建议继续调整吸附距离、集群合并数学或现有托盘方向阈值；这些路径已有专项测试覆盖，当前验证均通过。
