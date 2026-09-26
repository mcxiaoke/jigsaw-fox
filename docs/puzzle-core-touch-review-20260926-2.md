# 拼图核心功能与触摸处理复审（第二轮·实证）

> 复审时间：2026-09-26 09:29 GMT+8
> 复审范围：`lib/game/jigsaw_puzzle_game.dart`、`lib/game/puzzle_piece_component.dart`、`lib/pages/game_page.dart`、`lib/logic/engine/puzzle_engine.dart`、`lib/logic/models/puzzle_state.dart`，并核对 Flame 1.38.0 与 Flutter 手势分发的实际实现
> 复审性质：代码审查 + 实证复现；**本次未修改任何业务代码**
> 基线：`flutter analyze` → `No issues found!`；`flutter test` → `391 passed / 8 skipped / 0 failed`
> 复现脚手架：`temp/verify_puzzle_touch_probe_test.dart`（临时探针，可删除）

## 1. 结论

发现 **1 个已实证复现的功能缺陷**（碎片被拖回托盘后权威状态不同步，随后会「飞回」棋盘并被锁定），以及 **3 个代码层面确认的交互/状态缺陷**。吸附判定、集群合并、级联合并、托盘隔离、缩放平移等核心数学未发现新问题。

| 编号 | 问题 | 严重度 | 状态 |
| --- | --- | --- | --- |
| F1 | 拖回托盘不写回 `_boardState`，后续可将碎片从托盘拽回棋盘并锁定 | 高 | 已复现 |
| F2 | 放大态下抓取碎片的第一帧会误触发棋盘平移 | 中 | 代码确认 |
| F3 | 托盘碎片手势判定期间托盘滚动与棋盘平移同时生效 | 中 | 代码确认 |
| F4 | 生命周期/系统中断不清理 holding / dragging / 指针状态 | 中 | 代码确认 |
| F5 | 未处理 Flame `TapCancelEvent` | 低 | 代码确认 |
| F6 | 拖拽用 `canvasEndPosition`，在 Flame 1.38 下比真实指针超前一帧位移 | 低 | 代码确认 |
| F7 | 落位动画在途时，插值坐标会被写回权威状态（非锁定集群） | 低 | 代码确认 |

---

## 2. F1（高）：拖回托盘不写回权威状态 —— 碎片会「飞回」棋盘并被锁定

### 位置

`lib/game/jigsaw_puzzle_game.dart:2083-2093`，`handlePieceDragEnd` 步骤 1：

```dart
if (!isTabletop && inTrayArea && clusterPieces.length == 1) {
  _insertPieceIntoTrayAt(piece, piece.position.x);
  piece.isInTray = true;
  piece.animateScaleTo(Vector2.all(_trayPieceScale));
  updatePieceVisibility();
  updatePiecesStateAndPriorities();
  onStateUpdated?.call();
  return;                      // ← 直接返回，_boardState 未更新
}
```

对比步骤 2（`:2133-2155`）会为所有 `!isInTray` 的组件把 `nx/ny/inTray/clusterId/rot` 全量写回 `_boardState`。两条出路只有托盘这条不落库，是唯一的非对称分支。

### 后果

组件已置 `isInTray = true` 并动画进入托盘槽位，但 `_boardState` 仍保留该碎片**拖走前的棋盘坐标**与 `inTray: false`。于是：

1. `solvedCount`（`:240-241`，基于 `_boardState`）会把它继续算作「已就位」，进度虚高；
2. 一旦它后来被 `computePlantedPieceIds` 判为连通到边缘（`updatePiecesStateAndPriorities`:1891-1904），就会命中 `isPieceSolved` → 置 `isLocked = true`、`isInTray = false`，并强制 `comp.position.setFrom(_normalizedToScreen(nx, ny))` —— **碎片从托盘瞬移回棋盘槽位并锁定**，玩家手上的托盘凭空少一块。

### 复现（探针 PROBE-1，3×3，600×900）

```
before      : isLocked=false isSolved=true inTray(comp)=true  inTray(state)=false
拖入托盘后  : inTray(comp)=true  inTray(state)=false nx=0.333 ny=0.333 isSolved=true
补全外框后  : inTray(comp)=false isLocked=true  pos=(202.7, 284.7)   trayTop=764.0
```

最后一行即故障：`pos.y = 284.7` 远在托盘顶部 `764.0` 之上，碎片已被搬回棋盘。

**触发条件**（不需要刻意构造，正常玩法可达）：碎片处于「坐标已在槽位容差内、但所属装配体尚未连通边缘」的孤岛态（未吸附、未锁定、可拖动），玩家把它拖回托盘；随后外框补全。提示功能 `hint()`（`:2762-2767` 直接写入精确目标坐标）会显著提高孤岛片命中该坐标的概率。

### 建议修法（最小改动，与既有约定一致）

在步骤 1 内补写状态，托盘标记沿用项目既有约定 `ny >= 2.0`（见 `organizeTray`:2471-2474、`_applyBoardState`:2708-2711、`exportSnapshotJson`:2515-2522）：

```dart
final updated = _boardState.pieces.map((p) {
  if (p.id == piece.id) return p.copyWith(inTray: true, ny: max(p.ny, 2.0));
  return p;
}).toList();
_boardState = _boardState.copyWith(pieces: updated);
```

`_isNormalizedOnBoard`（`:205-211`）对 `ny = 2.0` 返回 false，与 `_legalDomain`/越界收拢判据不冲突。

---

## 3. F2（中）：放大态下抓取碎片的第一帧会误平移棋盘

### 位置

`lib/pages/game_page.dart:949-957`：

```dart
} else if (_game != null &&
    _game!.zoom > 1.0 &&
    _pointerPositions.length == 1 &&
    !_game!.isDraggingAnyPiece &&                 // ← 关键判据
    (_game!.isTabletop || event.localPosition.dy < _game!.trayPosition.y)) {
  _game!.panBy(Vector2(event.delta.dx, event.delta.dy));
}
```

### 依据（Flutter 实际分发顺序，非推测）

`GestureBinding.dispatchEvent`（flutter/packages/flutter/lib/src/gestures/binding.dart:496）按 hit test path **顺序**调用 `entry.target.handleEvent`；`GestureBinding` 自身由 `hitTest` 追加在路径**最后**，其 `handleEvent`（同文件 :527-528）才执行 `pointerRouter.route(event)` 把事件交给手势识别器。

即：**`Listener.onPointerMove` 先于 Flame 的拖拽识别器收到同一个 move 事件**。

因此拖拽的第一个 `PointerMoveEvent` 到达时，`onDragStart` 尚未触发（`isDragging == false`）、`holdingPiece == null`，`isDraggingAnyPiece` 为 false → 该帧被当成「空白区平移」执行 `panBy(delta)`。之后 Flame 才建立拖拽，后续帧不再平移。

### 表现

`maxZoom` 恒为 2.0（各难度），所以放大后每次按下碎片开始拖动，棋盘都会先抖动一个位移量，且快速拖动时抖动更明显。

### 建议

判据改为「按下点是否命中碎片」而非「是否已在拖拽中」。可在 `_onPointerDown` 时用 `game.componentsAtPoint(...)` 预存命中结果，或让 Flame 侧 `onDragStart` 置位一个 `_dragActiveSinceDown` 标志供页面读取；亦可在 `_onPointerMove` 平移前补一次 `event.buttons & kPrimaryButton != 0` 且要求本次 move 与 down 的累计位移超过 pan slop。

---

## 4. F3（中）：托盘碎片手势判定期间，托盘滚动与棋盘平移同时生效

### 位置

- 托盘方向判定：`lib/game/puzzle_piece_component.dart:379-425`
- 页面平移：`lib/pages/game_page.dart:949-957`

### 依据

拖出判定要求「向上 ≥ 12px 且垂直分量 > 水平 × 1.2」，其余（含斜向、横向占优）一律判为托盘滚动并调用 `game.scrollTray(...)`。判定期间 `_pendingTrayDrag == true` 而 `isDragging == false`、`holdingPiece == null`，因此 `isDraggingAnyPiece` 为 false。

于是当玩家从托盘碎片上斜向上滑动、且手指越过托盘上沿（`dy < trayPosition.y`）且 `zoom > 1.0` 时，同一帧内：

- Flame 侧：`scrollTray(delta.x)` —— 托盘横向滚动；
- 页面侧：`panBy(delta)` —— 棋盘同时平移。

`_trayScrollLocked` 锁定后（`:419-421`）该双重动作会持续存在。

### 建议

把「是否处于托盘手势」暴露给页面（如 `game.isTrayGestureActive`），`_onPointerMove` 平移分支增加该条件取反；或把托盘滚动也收归页面 `Listener` 统一分发，消除双通道。

---

## 5. F4（中）：生命周期/系统中断不清理交互状态

`lib/pages/game_page.dart:116-131` 的 `didChangeAppLifecycleState` 在 `inactive/paused/hidden/detached` 时只做停音、上报时长、同步落盘，未执行：

- `_game?.cancelHoldingPiece()` / `_game?.cancelAllPieceDragging()`
- `_pointerPositions.clear()`、`_baseDistance = 0`、`_game?.isPinching = false`

指针状态维护在 `:87-91`、`:896-984`。常规双指、右键、ESC 路径都有取消逻辑，但切后台、窗口失焦、系统手势抢占时，页面层与 Flame 层的取消回调不一定成对到达。残留后表现为：回到游戏时 `holdingPiece` 非空，下一次点击变成「放下旧碎片」而非拾取新碎片；`_pointerPositions` 残留还会让下一次单指手势被误判为双指（触发 `:907-911` 的 `cancelAllPieceDragging`）。

建议抽一个幂等的 `_cancelActivePointerInteraction()`，在非活动生命周期与 `dispose` 中统一调用。

---

## 6. F5（低）：未处理 `TapCancelEvent`

`PuzzlePieceComponent` 覆写了 `onTapDown`(310) / `onDragStart`(336) / `onDragUpdate`(366) / `onDragEnd`(435) / `onDragCancel`(453)，未覆写 `onTapCancel`。Flame 的 `MultiTapDispatcher._tapCancelImpl`（flame/src/events/dispatchers/multi_tap_dispatcher.dart:106-114）会在 `TapUp` 之后对未收到 up 的组件补发 `onTapCancel`，在系统取消轻点识别的路径下会出现 `TapDown → TapCancel` 而不经过拖拽取消流程，`_pendingTrayDrag`、`isDragging` 可能残留。建议补一个幂等取消入口统一清理。

---

## 7. F6（低）：拖拽位置比真实指针超前一帧

`PuzzlePieceComponent.onDragUpdate` 用 `event.canvasEndPosition` 作为「当前光标位置」传给 `game.updateHoldingPiecePosition`（`:431`，托盘分支 `:412` 与 `computeGrabAnchor` 同理）。

Flame 1.38 的 `DragUpdateEvent`（flame/src/events/messages/displacement_event.dart）定义为：

```dart
deviceStartPosition = details.globalPosition                    // 当前真实位置
deviceEndPosition   = details.globalPosition + details.delta    // 当前 + 本帧位移
```

而识别器传入的是 `DragUpdateDetails(globalPosition: event.position, delta: event.position - previous)`（flame/src/events/multi_drag_scale_recognizer.dart:477-499），即 `delta` 是「相对上一帧的位移」。故 `canvasEndPosition = 真实位置 + 一帧位移`，比指针超前。

同一事件上的 `canvasDelta`（`end - start`）才是正确位移，代码在托盘滚动处用的正是 `canvasDelta`（`:395`/`:422`），两处口径不一致。

建议：改用 `event.canvasStartPosition`（等于真实当前位置）或 `canvasEndPosition - canvasDelta`。实机上表现为碎片略微「跑在手指前面」，快速拖动更明显，建议上真机确认后再改。

---

## 8. F7（低）：落位动画在途时插值坐标被写回状态

`handlePieceDragEnd` 步骤 2（`:2134-2153`）对所有 `!isInTray` 组件执行 `_screenToNormalized(comp.position)` 并覆盖状态。若此刻某集群的 `MoveToEffect` 尚在途中（`_applySnapSettlement`:2045 的 `animateTo`，默认 0.15s；hint 为 0.25s），写回的就是插值坐标。

实测：已吸附并被锁定的碎片不受影响——`updatePiecesStateAndPriorities`(1901) 会对锁定片强制 `position.setFrom(槽位)`，PROBE-2 显示吸附后组件位置已是槽位坐标。仅**未锁定的合并集群**会在动画窗口内出现状态/视觉瞬时不一致；由于整簇同时长同时长曲线插值、相对网格偏移保持不变，不变量不破，且下一次 dragEnd 会自然同步。属可自愈的瞬时问题，优先级低。

---

## 9. 复核未发现问题的路径

- 棋盘槽位吸附 / 正交邻居合并 / 级联合并的阈值与度量（`puzzle_engine.dart`）
- 孤立内部碎片「无邻居不吸附」与边缘装配体连通规则（`canSnapCluster` / `computePlantedPieceIds`）
- 吸附容差 `effectiveSnapDistance()` 的缩放无关化与 48px 硬上限
- 托盘碎片与棋盘坐标隔离（读档、导出、resize 三处的 `ny >= 2.0` 约定）
- 滚轮在托盘/棋盘之间的分流（游戏侧已移除 `ScrollDetector`）
- 双指捏合时取消抓取、持有集群期间的缩放与 resize 重排
- `missingPieceCheck` 的整簇原子平移与「含已就位成员不搬」保护
- 集群网格偏移不变量自检
- Undo/Redo 与快照尺寸不匹配防护

另：已核对 Flame 的事件传播语义，澄清两处易误判点——
1. `DragStartEvent` 继承 `PositionEvent`，走 `containsLocalPoint` 命中测试；只有 `DragUpdateEvent`（`DisplacementEvent`）才绕过命中测试继续投递给已记录组件，**拖拽起始点的命中的确是精确的**。
2. `deliverAtPoint` 默认 `continuePropagation = false`，命中后即停止下传；`PuzzlePieceComponent.onTapDown` 对托盘碎片提前 return 不会让事件漏到 `FlameGame.onTapDown`，「点击空白放下」语义成立。

---

## 10. 建议处理顺序

1. **F1**（唯一已实证的功能缺陷，改动 3 行，风险最低，收益最高）；
2. **F2 + F3**（同一处平移判据，可一并重构为「按下点命中判定」，建议配真机/集成测试）；
3. **F4 + F5**（统一幂等取消入口）；
4. **F6 / F7**（低优先，F6 建议先上真机确认手感差异）。

不建议调整吸附距离、集群合并阈值与托盘方向阈值——这些路径已有专项测试覆盖且当前全绿。
