# 关卡恢复碎片越界与托盘整理逻辑修复总结

- 日期：2026-09-17
- 涉及模块：lib/game/jigsaw_puzzle_game.dart, lib/game/puzzle_piece_component.dart, test/game_layout_test.dart

---

## 1. 问题描述

在游戏关卡中点击“继续”读档恢复游戏进度后，存在以下现象：
1. 部分碎片出现在屏幕可视区域外或屏幕右下边缘，仅露出局部边缘；
2. 停留在屏幕边缘的碎片无法通过点击或拖动手势将其拉回屏幕；
3. 点击扫把按钮（托盘一键整理 organizeTray）无法将散落碎片收回托盘，也无法处理边缘碎片的越界问题。

---

## 2. 原因分析

通过对快照恢复流程、托盘整理逻辑以及碎片手势事件分发的排查，确认上述现象由以下三个原因引起：

### 2.1 恢复快照时的坐标映射与越界处理缺失
- 在 _applyBoardState() 中恢复碎片位置时，托盘碎片与棋盘碎片的物理坐标计算逻辑混淆。当玩家在不同视口分辨率、缩放比例下恢复，或在桌面模式与托盘模式之间切换时，托盘内碎片的坐标曾依赖视口变换矩阵 _normalizedToScreen，导致在视口发生偏移或缩放时，计算出的屏幕物理位置超出当前窗口视口。
- 此外，对于已拼合的多片集群（clusterSize > 1），在视口重置或缩放恢复后，系统未对集群的全局包围盒进行视口边界检测，导致跨出边界的集群未被拉回。

### 2.2 托盘一键整理（organizeTray）扫描范围不完整
- 原 organizeTray() 在托盘模式下仅遍历 _trayOrder 列表中的碎片索引，未能遍历所有位于棋盘上的游离单片（_pieces.values）。散落在棋盘上的未就位单片不会被重新收回托盘。
- 原逻辑对整理对象设置了 clusterSize == 1 的前置条件，多片拼合集群在逻辑上不能放入托盘，同时缺乏拉回视口内的兜底逻辑，因此点击扫把时对越界集群无响应。

### 2.3 碎片组件手势拦截逻辑未校验物理位置
- PuzzlePieceComponent 的 onTapDown 与 onDragStart 仅通过 piece.isInTray 布尔值判断是否将拖动手势拦截并转交为托盘水平滚动。
- 当碎片物理位置已在棋盘边缘或视口外，但状态标志位尚未与物理区域严格同步时，用户向屏幕内拉动碎片的操作被组件直接丢弃或判定为托盘滚动，导致碎片无法拖动。

---

## 3. 实施的解决办法与代码改动

### 3.1 增加托盘物理区域坐标判定
在 JigsawPuzzleGame 中新增物理坐标判定方法：
- isPointInTrayArea(Vector2 pos)：根据当前游戏模式（托盘模式/桌面模式）以及托盘物理矩形区域，判定给定坐标点是否在托盘物理边界之内。
- 在 PuzzlePieceComponent.onTapDown 和 onDragStart 中，将判断条件增加物理区域复合校验（piece.isInTray && game.isPointInTrayArea(position)）。当碎片物理位置不在托盘内时，不拦截手势，确保玩家可正常拖动碎片。

### 3.2 增加可视边界拉回机制（Pullback）
在 JigsawPuzzleGame 中新增 _pullbackOutOfBoundsClustersAndPieces({bool animate = false})：
- 计算当前可用视口安全区域（考虑边距 _sideMargin、顶部工具栏高度 _topToolbarHeight 及底部托盘上沿）；
- 扫描所有未处于托盘且未就位锁定的碎片及多片拼合集群，计算其整体包围盒；
- 当包围盒超出视口安全边界时，计算最小平移偏移量 (dx, dy)，并将集群内所有碎片原子平移回可视区域内。

### 3.3 重构快照恢复逻辑
在 JigsawPuzzleGame._applyBoardState() 中调整恢复流程：
- 托盘模式下，所有处于托盘状态的碎片，严格通过 _getTrayPositionForIndex(trayIdx) 分配物理位置，不再通过视口矩阵 _normalizedToScreen 计算；
- 在所有碎片状态恢复完成后，统一调用 _pullbackOutOfBoundsClustersAndPieces(animate: false) 作为恢复兜底，确保无论跨模式读档还是视口变动，所有棋盘碎片均位于屏幕可视区域内。

### 3.4 重构托盘一键整理逻辑
在 JigsawPuzzleGame.organizeTray() 中：
- 托盘模式下全量遍历 _pieces.values，筛选出所有不在正确槽位且未拼合的单片（!piece.isSolved && piece.clusterSize == 1），统一清空并重构 _trayOrder，驱动碎片通过平滑动画飞回托盘插槽；
- 针对棋盘上已拼合的多片集群，调用 _pullbackOutOfBoundsClustersAndPieces(animate: true)，通过平滑动画将越界集群平移拉回视口安全区。

### 3.5 动画组件生命周期保护
在 `PuzzlePieceComponent.animateTo` 与 `animateScaleTo` 中：
- 增加 `if (!isMounted)` 分支，在组件未挂载时直接赋值位置与缩放，避免在非渲染环境或单元测试中因缺失父节点导致 Flame 抛出空指针异常。

---

## 4. 验证情况

1. **单元测试**：在 `test/game_layout_test.dart` 中新增 4 个针对性测试用例：
   - 验证托盘模式下棋盘游离单片被扫把收回托盘；
   - 验证屏幕外多片集群被扫把拉回屏幕可视区；
   - 验证读档恢复时自动平移拉回出界碎片与集群；
   - 验证棋盘碎片在状态标志异常时不拦截拖拽手势。
   全量测试 `flutter test` 执行通过（383 passed, 0 failed）。
2. **静态分析**：`flutter analyze` 结果为 0 issues。
3. **平台构建**：`flutter build windows --debug` 编译通过。
4. **集成测试**：`flutter test .\integration_test\app_test.dart -d windows` 运行通过。
