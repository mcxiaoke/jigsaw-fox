# 棋盘与托盘触摸拖动冲突深度分析与解决方案

- **文档日期**：2026-09-03
- **关联问题**：手指按住托盘上方与棋盘下边缘交界区域左右滑动时，棋盘（Pan）与底部托盘（Scroll）有时会同时移动
- **参考图例**：`temp/upanddownsamemove.jpg`
- **影响场景**：拼图放大状态（如 225%）且处于托盘模式（Tray Mode）下单指横向滑动

---

## 一、 问题背景与现场复现

在图例 `temp/upanddownsamemove.jpg` 中，游戏处于以下典型状态：
1. **缩放状态**：棋盘处于放大模式（界面右上角显示 `225%`），此时单指在空白区域拖动可平移棋盘画布；
2. **触控区域**：用户红圈标记位置正好处于**棋盘底边框线**与**底部托盘上边缘高光线**之间的临界过渡区（Y 轴分界线，逻辑高度约 15~24px 范围）；
3. **操作意图**：用户使用大拇指或较宽的手指横按在此区域左右滑动，主观意图多为“横向滚动翻阅托盘内的碎片”；
4. **异常表现**：手指向左或向右滑动时，上面的棋盘和下面的托盘碎片会**同时同向联动滑动**，产生严重的视觉错乱与操作失控感。

---

## 二、 根本原因分析（Root Cause）

通过跟踪 `lib/pages/game_page.dart` 与 `lib/game/jigsaw_puzzle_game.dart`、`lib/game/puzzle_piece_component.dart`，确认该现象并非单一 Bug，而是**手势分发架构的双轨监听、无状态逐帧判定、Flame手势锁定机制与物理触控特性叠加导致的必然冲突**。

### 1. 双轨手势系统并行监听，互不排斥
- **Flutter 层**：[`GamePage`](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart) 最外层包裹了一个 [`Listener`](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L1069)（`behavior: HitTestBehavior.translucent`），通过原生指针事件直接捕获移动并平移棋盘画布；
- **Flame 引擎层**：底部的 `TrayBackgroundComponent` 和 `PuzzlePieceComponent` 实现了 `DragCallbacks`，监听拖拽事件来横向滚动托盘。
- 因为 Flutter 的 `Listener` 属于原始指针事件分发，它**不参与手势竞技场（Gesture Arena）排他竞争**，无论 Flame 内部组件是否消费了该事件，`Listener` 的 `_onPointerMove` 都会在同一微秒级时刻收到完全相同的移动增量。

### 2. 棋盘平移采用“逐帧无状态判断”，手势起点未锁定
在 [`game_page.dart`](file:///c:/Home/Projects/jigsawpuzzle/lib/pages/game_page.dart#L774-L783) 中，平移棋盘的逻辑如下：
```dart
else if (_game != null &&
    _game!.zoom > 1.0 &&
    _pointerPositions.length == 1 &&
    !_game!.isDraggingAnyPiece &&
    (_game!.isTabletop || event.localPosition.dy < _game!.trayPosition.y)) {
  _game!.panBy(Vector2(event.delta.dx, event.delta.dy));
}
```
**关键漏洞**：
- 该逻辑**没有在手指按下的第一瞬间（`_onPointerDown`）判定并锁定“本次手势属于棋盘还是托盘”**；
- 而是对手指移动的**每一帧（`onPointerMove`）独立判定**：只要当前瞬间的 `dy < _game!.trayPosition.y`，就会立即执行 `_game!.panBy(...)`；
- 如果手势在移动过程中纵坐标发生几像素的微小漂移，判定条件就会在每一帧之间动态跳变。

### 3. Flame 的“拖拽捕获绑定（Drag Capture）”机制
- 当手指按下时，若触控中心落在托盘矩形范围内（`y >= trayPosition.y`），Flame 的 `DragCallbacks` 会触发 `TrayBackgroundComponent.onDragStart`（或托盘内碎片的 `onDragStart`）；
- Flame 一旦将某 Pointer 与组件绑定建立 Drag 管道，**在手指离开屏幕前，即使手指滑动到了组件的外围甚至滑到了棋盘上方，Flame 依然会持续向该组件分发 `onDragUpdate`**；
- 因此，`game.scrollTray(delta.x)` 在整个滑动期间都会被持续调用，绝对不会中途松手。

### 4. 互斥状态标志位缺失（`isDraggingAnyPiece` 的语义盲区）
`_onPointerMove` 中虽然加入了 `!_game!.isDraggingAnyPiece` 作为守卫条件，但在 [`jigsaw_puzzle_game.dart`](file:///c:/Home/Projects/jigsawpuzzle/lib/game/jigsaw_puzzle_game.dart#L216) 中：
```dart
bool get isDraggingAnyPiece =>
    _holdingPiece != null || _pieces.values.any((p) => p.isDragging);
```
- **拖动托盘空白区时**：`_holdingPiece == null`，所有碎片均未处于拖拽，`isDraggingAnyPiece` 为 `false`；
- **拖动托盘内的碎片时**：`puzzle_piece_component.dart` 特意将 `isDragging` 保持为 `false`（标记为 `_trayScrollLocked = true` 仅驱动滚动），此时 `isDraggingAnyPiece` 依然为 `false`；
- **系统内完全没有 `isScrollingTray` 这一状态**。因此在托盘滚动的全过程中，Flutter 层始终认为“当前没有任何拖拽在进行”，直接放行了棋盘平移！

### 5. 宽手指物理接触面的分界线震荡
- 用户使用大拇指或指腹按压屏幕时，电容屏感应到的并非数学上的一个点，而是长轴 8~15mm（折合 30~60 逻辑像素）的椭圆接触面；
- 手机触控驱动计算出的质心（Centroid）正好落在分界线附近；
- **冲突完整复现链路**：
  1. 按下瞬间，部分面积落在托盘上边缘，Flame 命中托盘并锁定拖拽，开始调用 `scrollTray`；
  2. 横向滑动时，手指由于生理骨骼与肌肉弧度，产生轻微的微米级纵向起伏（如上浮 2 个像素），导致质心坐标 `dy` 变为 `trayPosition.y - 1`；
  3. Flutter 层的 `_onPointerMove` 判定 `dy < trayPosition.y` 成立，立即调用 `panBy` 平移棋盘；
  4. 此时 Flame 的 `onDragUpdate` 仍未释放，继续调用 `scrollTray` 滚动托盘；
  5. **两者在同一手势内同时执行，棋盘和托盘便一起左右滑动！**

---

## 三、 解决方案设计（三道防线）

为了彻底根治冲突并保证极致丝滑的手感，建议采用 **“起点锁定 + 安全缓冲带 + 互斥状态锁”** 的三道防线架构：

```
[ 手指按下 PointerDown ]
         │
         ├─── 起点判定：downPos.dy >= (trayPosition.y - buffer) ───► 锁定为【托盘滚动模式】（全程禁动棋盘）
         │
         └─── 起点判定：downPos.dy < (trayPosition.y - buffer) ────► 锁定为【棋盘平移模式】（全程禁滚托盘）
```

---

### 防线 1：手势起点生命周期锁定（Start-Zone Ownership Locking）

**核心思想**：手势归属在按下（`onPointerDown`）那一刻就确定并锁定，滑动过程中绝不允许根据实时的 `dy` 动态叛变。

1. 在 `_GamePageState` 中定义单指拖拽意图状态：
   ```dart
   enum _SingleTouchIntent { none, panBoard, scrollTray }
   _SingleTouchIntent _touchIntent = _SingleTouchIntent.none;
   ```
2. 在 `_onPointerDown` 中：
   - 记录该 pointer 按下时的起始坐标 `downPos`；
   - 若 `downPos.dy >= _game!.trayPosition.y - 16.0`（计入防误触余量），标记 `_touchIntent = _SingleTouchIntent.scrollTray`；
   - 若 `downPos.dy < _game!.trayPosition.y - 16.0`，且未点中棋盘上的散落碎片，标记 `_touchIntent = _SingleTouchIntent.panBoard`。
3. 在 `_onPointerMove` 中：
   - **仅当 `_touchIntent == _SingleTouchIntent.panBoard` 时才允许触发 `_game!.panBy(...)`**；
   - 只要起点落在托盘或缓冲带，即便手指向上一路滑到屏幕顶端，也绝不触发棋盘平移。
4. 在 `_onPointerUp` 与 `_onPointerCancel` 中：
   - 重置 `_touchIntent = _SingleTouchIntent.none`。

---

### 防线 2：设立托盘防误触缓冲安全区（Deadzone Buffer）

**核心思想**：适应宽手指物理特性，把分界线附近的灰色空白带明确划归给托盘操作。

- **人机工程学原理**：在手机端，用户在屏幕底部附近横向滑动，95% 以上的主观心理预期都是“滑动托盘选碎片”；如果用户想要平移棋盘，通常会滑动棋盘中间或靠上的明显空白区域；
- **实施策略**：
  - 棋盘平移的判定上边界向上收缩 `16.0 ~ 20.0 px`（定义常量 `const double _trayGestureBuffer = 18.0`）；
  - 判定条件从 `event.localPosition.dy < _game!.trayPosition.y` 改为：
    ```dart
    event.localPosition.dy < (_game!.trayPosition.y - _trayGestureBuffer)
    ```
  - 这样为宽手指提供了近 20 像素的容错垫，指肚按压在红圈区域将 100% 稳定识别为托盘操作，杜绝临界点跳动。

---

### 防线 3：引擎级互斥状态标志位（`isScrollingTray`）

**核心思想**：让 Flutter 层的 `Listener` 能够实时获知 Flame 托盘的运行状态，形成双向防护网。

1. 在 `JigsawPuzzleGame` 中增加公有属性：
   ```dart
   bool isScrollingTray = false;
   ```
2. 在 `TrayBackgroundComponent` 中：
   - `onDragStart` 时设置 `game.isScrollingTray = true;`
   - `onDragEnd` / `onDragCancel` 时设置 `game.isScrollingTray = false;`
3. 在 `PuzzlePieceComponent` 中：
   - 进入 `_trayScrollLocked` 滚动托盘分支时，同步通知 `game.isScrollingTray = true;`
   - `onDragEnd` / `onDragCancel` 时同步置为 `false;`
4. 在 `_onPointerMove` 中：
   - 增加保护：`!_game!.isScrollingTray`，一旦托盘处于滚动中，棋盘平移通道立即物理锁死。

---

## 四、 预期收益与效果对比

| 评估维度 | 优化前现状 | 采用本方案后 |
| :--- | :--- | :--- |
| **手势决策机制** | 逐帧动态比对，极易受抖动影响跳变 | 按下瞬间锁定手势终身归属，全程稳定 |
| **手势互斥性** | 各管各的，`isDraggingAnyPiece` 存在盲区 | 具备 `isScrollingTray` 明确互斥锁，两者绝对互斥 |
| **宽手指容错** | 0 容差，分界线按压即踩雷 | 预留 18px 缓冲安全区，指腹横划极其平顺 |
| **架构稳定性** | 容易引入连带手势冲突 | 无需重构 Flame 事件机制，仅完善状态锁与边界，轻量高内聚 |
