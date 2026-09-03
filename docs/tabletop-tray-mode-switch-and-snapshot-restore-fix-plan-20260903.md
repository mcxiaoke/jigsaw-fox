# 桌面模式读档缩放冻结与跨模式切换（桌面/托盘）布局自适应修复方案 (v1.1)

> 日期：2026-09-03  
> 状态：方案已定稿并全量落地，测试与构建 100% 通过  
> 关联文件：`lib/game/jigsaw_puzzle_game.dart`, `lib/logic/models/puzzle_state.dart`, `test/game_layout_test.dart`

---

## 一、 用户问题与现象复现

### 现象 1：桌面模式读档后缩放部分碎片冻结
- **100% 复现路径**：
  1. 启动游戏，进入桌面散落模式（Tabletop Mode）；
  2. 任意移动几块碎片（例如移到顶部接近 AppBar）；
  3. 退出游戏（触发自动保存快照），然后再进入该关卡“继续游戏”；
  4. 使用鼠标滚轮或双指缩放画布。
- **问题表现**：
  - 只有刚才手动移动过的那几块碎片会跟着棋盘缩放并改变位置；
  - 其余所有初始散落在四周未移动的碎片，尺寸毫无变化、位置彻底冻结在原地，如同死物。

### 现象 2：在设置中切换托盘/桌面模式后“继续游戏”，碎片布局完全错乱
- **100% 复现路径**：
  1. 在桌面模式下移动部分碎片；
  2. 退出到设置界面，将散落模式切换为“托盘模式（Tray Mode）”；
  3. 点击“继续游戏”进入拼图界面。
- **问题表现**：
  - 桌面四周散落的碎片没有被收纳进托盘，反而按照托盘模式的棋盘坐标系被错乱映射到屏幕负坐标（顶出屏幕外、钻入 AppBar 底下）或穿透托盘底部；
  - 许多碎片尺寸缩小为托盘缩放，却悬空散落在棋盘外，杂乱无章；
  - 反向操作（托盘模式切桌面模式）亦然：原本托盘里的碎片全都被挤在屏幕最下方的一条水平线上重叠，无法在桌面上散开。

---

## 二、 根因深度剖析

### 1. 现象 1 根因：`_applyBoardState` 误将桌面散落碎片标记为 `isInTray = true`

查看快照恢复逻辑核心代码（`lib/game/jigsaw_puzzle_game.dart:2011-2024`）：

```dart
// 历史遗留缺陷代码：
for (final p in newState.pieces) {
  final comp = _pieces[p.id];
  if (comp == null) continue;

  // 致命缺陷：仅以 [-0.10, 1.10] 范围硬编码判定是否在棋盘上，完全未识别 isTabletop
  final isOnBoard =
      (p.nx >= -0.10 && p.nx <= 1.10 && p.ny >= -0.10 && p.ny <= 1.10);
  comp.isInTray = !isOnBoard; // <--- 桌面散落碎片全被标记成了 isInTray = true！

  final targetScreenPos = _normalizedToScreen(p.nx, p.ny);
  comp.position.setFrom(targetScreenPos);
  if (isOnBoard) {
    comp.scale.setAll(_zoom);
  } else {
    comp.scale.setAll(_trayPieceScale); // 缩放也被误设成了 0.4x 托盘缩放！
  }
}
```

#### 为什么未移动碎片不缩放，而移动过的碎片会缩放？
1. **桌面模式根本没有托盘**。初始所有未移动碎片环形散落在四周，其归一化坐标天然在棋盘外（顶部 $ny \approx -1.15$，底部 $ny \approx 1.64$，左侧 $nx \approx -0.35$）；
2. 读档时由于 `isOnBoard` 为 `false`，它们全部被错误标记为 `comp.isInTray = true`；
3. 画布缩放函数 `_updateBoardTransform()` 遍历更新时：
   ```dart
   for (final pState in _boardState.pieces) {
     final comp = _pieces[pState.id];
     if (comp == null || comp.isInTray || comp.isDragging) continue; // <--- isInTray 会被直接跳过！
     comp.position.setFrom(_normalizedToScreen(pState.nx, pState.ny));
     comp.scale.setAll(_zoom);
   }
   ```
   未移动碎片因为被误标为 `isInTray = true`，**全部被 `continue` 跳过，位置与尺寸完全冻结**！
4. 而您手动移动到棋盘上的那几块碎片，坐标落入了 `[-0.10, 1.10]`，或者在松手时执行了 `handlePieceDragEnd` 的 `p.isInTray = false`，因此唯独它们能被 `_updateBoardTransform` 正常刷新缩放！

---

### 2. 现象 2 根因：跨模式切换导致坐标系基准错位且缺少智能收纳重排

托盘模式与桌面模式在视觉几何和碎片收纳上是完全不同的体系：
- **托盘模式**：棋盘位于上半区（避让底部约 120px 的滑动托盘）；所有游离单片必须收纳进底部的滑动槽位列表 `_trayOrder` 中；
- **桌面模式**：棋盘位于全屏居中（棋盘尺寸自适应收缩以腾出四周）；没有托盘，所有游离单片散落在四周桌面槽位 `_getTabletopScatterSlots` 中。

**当用户在设置里切换模式后读档**：
1. 快照此前**未保存当时的 `scatterMode`**；
2. 托盘模式直接把桌面模式保存的负数归一化坐标当成本模式坐标计算屏幕位置，导致碎片飞出屏幕；
3. 且托盘模式没有将这些游离碎片加入 `_trayOrder` 并执行 `_realignTrayPieces`，托盘栏空空如也，碎片却全在棋盘外游荡；
4. 反之，从托盘切到桌面时，碎片保存的托盘底部坐标在桌面模式下没有托盘承载，直接在底部叠成一长排废料。

---

## 三、 解决方案设计 (v1.1 极简高稳版)

针对上述两个问题，采用**极简、高稳的模式标记 + 游离单片自动归位机制（等效进门自动扫把）**：

### 1. 快照保存元数据打标（`exportSnapshotJson`）
在 `exportSnapshotJson` 中，将当前的 `scatterMode` 写入快照的 `extra` 字段中：
```dart
extra: {
  ..._boardState.extra,
  'scatterMode': isTabletop ? 'tabletop' : 'tray',
}
```

### 2. 快照恢复智能自适应（`_applyBoardState`）

```dart
final currentMode = isTabletop ? 'tabletop' : 'tray';
final savedMode = newState.extra['scatterMode'] as String?;
// 旧存档（无模式标记）或模式发生切换时，触发自动归位
final needsRealign = (savedMode == null || savedMode != currentMode);
```

> [!NOTE]
> `isTabletop` 是根据 `scatterMode == 'tabletop' && (size.x > 450.0 || size.y > 450.0)` 动态计算的运行时有效模式，快照持久化的是该有效模式。当玩家切换模式，或跨尺寸设备同步存档（例如手机小屏 `effective=tray` 流转至平板大屏 `effective=tabletop`）时，系统自动识别模式不一致并触发 `needsRealign` 扫把归位，已拼成果 100% 保留，未吸附游离单片自动重置为当前设备与模式下的最适位置。

#### 规则 A：核心劳动成果 100% 绝对保全
无论怎么切模式，以下碎片绝对留在棋盘上：
1. **已归位碎片**（`p.isSolved(rows, cols)`）：精准吸附在棋盘网格，锁定；
2. **多片拼合集群**（`clusterSize > 1`）：玩家已拼接的部分绝对保持在棋盘相对归一化位置；

#### 规则 B：针对未吸附游离单片的处理
- **同模式正常继续（`!needsRealign`）**：
  - 玩家在此前游玩时放置在棋盘上的单片或桌面上的散落单片，精准恢复其上一时刻的坐标；
  - 桌面模式下所有碎片 `comp.isInTray = false`，缩放设为 `_zoom`，保证全场 100% 同步缩放。
- **旧存档 或 发生模式切换（`needsRealign`）**：
  - **当前为桌面模式**：自动将未吸附单片均匀铺满在棋盘四周的桌面槽位（`_getTabletopScatterSlots`），且 `isInTray = false`；
  - **当前为托盘模式**：自动将未吸附单片整齐收拢到底部滑动托盘中（`_trayOrder`，`_realignTrayPieces`）；
  - **效果**：相当于系统在玩家切换模式或初次读取旧存档时，贴心地自动执行了一次“扫把整理”，界面瞬间干净美观，彻底根绝所有碎片悬空、重叠、越界等顽疾！

#### 规则 C：原始碎片排序严格保全
- 通过 `updatedPiecesMap` 字典映射，构建最终 `updatedPieces` 时按 `newState.pieces` 原始顺序重组，严格保全快照中的碎片 ID 与洗牌序列。

### 3. 画布缩放与尺寸变换严格防御
- 在 `_updateBoardTransform()` 中：
  ```dart
  if (comp == null || (!isTabletop && comp.isInTray) || comp.isDragging) continue;
  ```
  桌面模式下绝不因为任何原因将桌面碎片误当托盘碎片跳过。
- 在 `_syncResizeTransform()` 中：
  ```dart
  if (!isTabletop && comp.isInTray) {
    comp.scale.setAll(_trayPieceScale);
  } else {
    comp.scale.setAll(_zoom);
    final pState = _boardState.pieceById(comp.id);
    comp.position.setFrom(_normalizedToScreen(pState.nx, pState.ny));
  }
  ```
- **统一棋盘判定容差**：
  定义常量 `static const double _boardBoundsTolerance = 0.05;` 与公共判断工具方法 `_isNormalizedOnBoard`，将 `_syncResizeTransform`、`cancelPieceDrag` 与 `_applyBoardState` 中零散的容差阈值全部统一至 `0.05`。

---

## 四、 实施计划

1. **第一步（快照打标与极简模式识别）**：
   - 修改 `exportSnapshotJson`，在 `extra` 中持久化当前 `scatterMode`；
   - 在 `_applyBoardState` 中采用 `final needsRealign = (savedMode == null || savedMode != currentMode);`，旧存档与切模式均触发自动归位重排；
2. **第二步（跨模式智能收纳与桌面 isInTray 修复）**：
   - 彻底修复 `_applyBoardState` 中的 `isOnBoard` 与 `isInTray` 逻辑，桌面模式下统一赋 `isInTray = false`；
   - 采用 `updatedPiecesMap` 保全快照原始 `newState.pieces` 顺序；
   - 编写“桌面模式游离碎片铺展”与“托盘模式游离碎片归托盘”的自适应布局算法；
3. **第三步（缩放防御与容差阈值统一）**：
   - 在 `_updateBoardTransform`、`_syncResizeTransform` 等路径加入桌面模式防御；
   - 统一全局棋盘覆盖判定为 `_isNormalizedOnBoard`（容差 0.05）；
4. **第四步（自动化测试验证）**：
   - 编写 4 组针对性单元测试：
     1. 桌面模式读档后，全场所有碎片（包括初始未移动碎片）缩放 100% 跟手同步；
     2. 桌面模式导出快照 -> 托盘模式加载，验证游离碎片全部整齐进入托盘，无悬空越界碎片；
     3. 托盘模式导出快照 -> 桌面模式加载，验证游离碎片全部铺展到棋盘四周桌面，全场碎片缩放正常；
     4. 历史旧存档加载（无 `scatterMode` 标记），验证游离单片自动初始化归位，已归位碎片完美保全。
5. **第五步（全量回归与平台验证）**：
   - 执行 `dart format`、`flutter analyze`、全量 `flutter test`，以及 `flutter build windows --debug`。
