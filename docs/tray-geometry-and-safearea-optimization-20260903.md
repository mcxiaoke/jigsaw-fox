# 拼图底部托盘几何重构与移动端 SafeArea 触控适配方案

> **文档状态**：实施定稿  
> **日期**：2026-09-03  
> **责任范围**：拼图游戏核心布局（`lib/game/jigsaw_puzzle_game.dart`）、游戏主页面容器（`lib/pages/game_page.dart`）、布局单元测试（`test/game_layout_test.dart`）  

---

## 1. 业务背景与问题定义

### 1.1 问题现象
在移动端实机游玩时（参考截图 `temp/Screenshot_2026-09-03-19-10-11-597_com.mcxiaoke.jigsawpuzzle.jpg`），用户反馈：
1. **托盘空间变小且紧绷**：托盘整体高度显得非常紧凑，碎片排列拥挤；
2. **切片凸头溢出边缘**：带有向上凸头（Tab）的拼图切片，凸头明显戳出了灰色托盘的上边框；
3. **底部手势条遮挡**：托盘底边紧贴屏幕物理底边缘，直接覆盖在 Android / iOS 的系统全面屏手势导航横条（Home Bar）上。

### 1.2 根因分析与追溯
1. **历史提交追溯**：
   在 2026-09-02 的提交 `7e03045` 中，为了最大化中央棋盘面积，托盘高度被从原先的屏幕比例自适应（`min(size.y * 0.28, max(size.y * 0.20, 100.0))`，约 160px ~ 190px）重构为基于碎片基础高度的公式：
   $$\text{targetTrayH} = \text{\_trayPieceHeight} \times (1.0 + 0.15 + 0.30) \approx 92.8\text{px}$$
   并将切片垂直位置固定为顶部留白 15%：
   $$\text{py} = \text{trayPosition.y} + \text{\_trayPieceHeight} \times 0.15$$

2. **几何假设计算疏漏（漏算凸头 Overhang）**：
   - 拼图切片不是规则的平边矩形。根据几何模型 [`PieceShape`](lib/logic/geometry/piece_shape.dart)，拼图切片的凸头（Tab）向外延伸 **35%**（`standardTabRatio = 0.35`）；
   - 此前的计算将切片误当作只有 `1.0 * _trayPieceHeight` 的矩形单元格，顶部只预留了 15% 上边距；
   - **几何冲突**：当切片上方带凸头时，凸头向上突起 35%，而托盘仅留白 15%：
     $$15\% - 35\% = -20\%$$
     向上的凸头**必然溢出托盘顶部达 20%（约 13px）**；
   - 当切片下方带凸头时，切片总高达到 $150\%$，超出托盘总高 $145\%$，向下凸头同样溢出托盘底边缘 5%。

3. **全面屏手势条重叠风险**：
   原托盘底边距 `_bottomTrayMargin = 8.0px`，且外层未进行 SafeArea 规避。在现代全面屏手机上，底部系统手势指示横条（Home Bar，占高约 16~34px）直接侵入托盘可操作区域，不仅视觉逼仄，且玩家滑动切片时极易误触发系统的“返回桌面”或“切换应用”手势。

---

## 2. 方案详细设计与实施细节

### 2.1 托盘高度几何重构（完全包容 35% 凸头并留白）
- **物理高度推导**：
  单个切片在极端情况下（上方为凸头且下方为凸头）的最大视觉高度为：
  $$\text{visualMaxH} = \text{\_trayPieceHeight} \times (1.0 + 0.35 + 0.35) = 1.70 \times \text{\_trayPieceHeight}$$
  在基础尺寸 `_trayPieceHeight = 64.0px` 时，最大高度为 $108.8\text{px}$。
- **公式重构**：
  托盘高度重构为基础碎片高度的 **2.0 倍**：
  $$\text{targetTrayH} = \text{\_trayPieceHeight} \times 2.0 \approx 128.0\text{px}$$
- **屏幕比例与开阔度平衡**：
  - 在典型高度 800~920px 的移动设备上，128px 仅占全屏可用高度的约 **14% ~ 16%**；
  - 中央棋盘依然拥有 **620px ~ 720px** 的宽广展示区域；
  - 在完全消除凸头溢出的同时，保持了棋盘空间的最大化。

### 2.2 碎片垂直对称居中对齐
在 [`JigsawPuzzleGame._getTrayPositionForIndex`](lib/game/jigsaw_puzzle_game.dart) 中，重构碎片在托盘中的垂直定位逻辑：
```dart
Vector2 _getTrayPositionForIndex(int index) {
  final startX = trayPosition.x + _trayStartXMargin + _trayScrollX; // _trayStartXMargin = 16.0
  final px = startX + index * (_trayPieceWidth + _traySpacing);
  // 碎片基础单元格在托盘内垂直居中对齐
  final py = trayPosition.y + (traySize.y - _trayPieceHeight) / 2;
  return Vector2(px, py);
}
```
- **对称裕量分析**：
  - 基础单元格居中后，单元格上下到托盘边缘的留白各为：
    $$\text{margin} = \frac{128.0 - 64.0}{2} = 32.0\text{px} \quad (50\% \text{ 基础高度})$$
  - 切片凸头最大外扩为 $22.4\text{px}$（35%）；
  - **凸头尖端与托盘顶边/底边均保留恒定留白**：
    $$32.0\text{px} - 22.4\text{px} = \mathbf{9.6\text{px}}$$
  - 彻底杜绝任何切片无论凸头朝向何方溢出托盘边缘的问题，呈现出均衡、呼吸感极佳的视觉效果。

### 2.3 移动端全面屏手势条 SafeArea 避让
在 [`lib/pages/game_page.dart`](lib/pages/game_page.dart) 的容器层级中引入定向安全区避让（展示完整交互与呈现层级）：
```dart
Stack(
  children: [
    // 1. 全屏平铺织物壁纸：继续使用 Positioned.fill 铺满物理整屏，保证手势条背后视觉连续无黑边
    Positioned.fill(
      child: Image.asset(_selectedBackground, repeat: ImageRepeat.repeat),
    ),

    // 2. 进度条 + 游戏画布：仅对可交互操作内容开启底部 SafeArea 规避
    SafeArea(
      top: false,
      bottom: true,
      child: Column(
        children: [
          _buildProgressLine(),
          Expanded(
            child: _game != null
                ? KeyboardListener(
                    focusNode: _focusNode,
                    autofocus: true,
                    onKeyEvent: (e) { ... }, // 响应 ESC 取消抓取
                    child: Listener(
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerUp,
                      behavior: HitTestBehavior.translucent,
                      child: AnimatedOpacity(
                        opacity: _gameFadeIn ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 300),
                        child: ClipRect(
                          child: GameWidget<JigsawPuzzleGame>(game: _game!),
                        ),
                      ),
                    ),
                  )
                : const Center(child: CircularProgressIndicator(...)),
          ),
        ],
      ),
    ),

    // 3. 通关浮动 Banner：同步增加底部安全区偏移，避免结算与返回操作撞上手势条
    if (_isSolved)
      Positioned(
        bottom: 16 + MediaQuery.paddingOf(context).bottom,
        left: 20,
        right: 20,
        child: Container(...),
      ),
  ],
)
```
- **视觉沉浸感**：底层壁纸铺满物理整屏（包含手势横条下方），不会在屏幕底部留下突兀黑边；
- **手势安全性**：操作层（托盘底边与通关 Banner）自然抬高，与移动操作系统的主屏幕手势触发区形成隔离保护。

### 2.4 托盘形态升级：直角通栏铺满（Bottom Dock）与消除滚动悬空
- **悬浮胶囊的历史成因与缺陷**：
  从项目创建伊始（提交 `00da4e2`），托盘一直使用悬浮胶囊卡片（Floating Pill Card）样式（`_sideMargin = 8.0px`，圆角 `Radius.circular(16)`）。
  当切片在托盘中向左右两端滑动时，位于最边缘的切片会跨出 16px 圆角，并在左右 8px 的间隙中直接露在壁纸底色上，导致严重的**“切片悬空在托盘外部”的视觉错觉**。
- **直角通栏平铺重构**：
  1. **背景几何平铺**：在 `TrayBackgroundComponent.render` 中，废除 `drawRRect`，改用 `canvas.drawRect(size.toRect(), _bgPaint)` 直角全宽绘制；
  2. **微光分界线设计**：废除原全包围白色描边，改为仅在托盘顶边绘制一条半透明高光分割线（`canvas.drawLine(Offset(0, 0), Offset(size.x, 0), _borderPaint)`），左右和底边贴屏无需多余线条；
  3. **横向 100% 满屏**：`traySize = Vector2(size.x, targetTrayH)`，`trayPosition.x = 0.0`，托盘完全横跨整个可视屏幕；
  4. **切片左侧安全呼吸留白**：初始切片左边距设定为 16px 共享常量（`startX = trayPosition.x + _trayStartXMargin + _trayScrollX`）。
- **纵向浮动呼吸感**：
  托盘横向 100% 满屏铺满，纵向保留 `_bottomTrayMargin = 8.0px` 并叠加上 `SafeArea(bottom: true)`，作为通栏底栏与屏幕底部壁纸/手势区之间的自然呼吸分界。
- **收益**：
  碎片滚动时完全在半透明深色托盘背景内滑动移出物理屏幕，视觉一体感强烈，彻底消除了“脱离托盘”的错觉；同时托盘宽度增加了 16px，能够显示更多切片内容。

---

## 3. 触控、拖拽与拼图吸附影响评估（无负面影响专项证明）

对于引入 `SafeArea` 是否会对整体触摸拖放、拼图吸附造成任何负面影响，进行了底层源码级排查与推导，结论为**零负面影响，且具备正向防误触收益**：

### 3.1 坐标系自洽性：1:1 局部坐标映射，绝对无像素漂移
- `GameWidget` 的直接父容器为 `ClipRect`，向外依次包裹 `AnimatedOpacity`、`Listener`、`KeyboardListener` 与 `Expanded`；
- 中间层组件（`ClipRect` 与 `AnimatedOpacity`）均不产生任何额外的外边距、内衬或几何坐标偏移；
- Flutter 的手势命中测试管线通过 `RenderBox.globalToLocal(event.position)` 将全局触摸位置转换为 `Listener` 与 `GameWidget` 绝对重合的局部相对坐标 $(0, 0) \sim (\text{size.x}, \text{size.y})$；
- `SafeArea` 改变的仅是外层容器提供的可用高度 `size.y`，**局部坐标系的原点 $(0, 0)$ 始终严格锚定在游戏画布的左上角**；
- 拖拽过程中的抓取锚点计算（`computeGrabAnchor`）、光标跟随（`updateHoldingPiecePosition`）完全基于画布局部坐标，触摸跟手精度丝毫不受外层 padding 影响。

### 3.2 吸附与集群合并：纯棋盘归一化空间运算，吸附公差毫厘不差
- 吸附判定引擎 [`PuzzleEngine.resolveSnap`](lib/logic/engine/puzzle_engine.dart) 纯粹基于棋盘归一化坐标 $nx, ny$：
  $$nx = \frac{\text{screenPos.x} - \text{boardTopLeft.x}}{\text{boardSize.x}}$$
- 棋盘位置 `boardTopLeft` 与尺寸 `boardSize` 是在同一 Canvas 局部空间内自洽推导的；
- 无论屏幕可用高度多高、托盘多高，吸附触发距离判定（`snapThresholdPx`）均工作在纯粹的棋盘坐标空间中，**毫秒级吸附手感与几何判定 100% 保持一致**。

### 3.3 手势竞技场保护：彻底消除系统手势误触
- 在全面屏手机上，玩家在托盘快速左右划动浏览碎片或向上抓取切片时，若无底部安全隔离，极易触发操作系统的“上划返回桌面”或“横划切换应用”手势；
- 引入 `SafeArea(bottom: true)` 后，托盘与系统手势区天然隔离，**彻底解决了滑动切片时被系统误杀/切出游戏的心流中断缺陷**。

### 3.4 跨平台一致性（PC / 平板 / 手机）
- 在 Windows、macOS 桌面端或无底部手势条的设备上，`MediaQuery.paddingOf(context).bottom` 自动返回 `0.0`；
- `SafeArea` 在桌面平台产生的边距为 0，与原代码完全等价，跨平台表现高度统一。

---

## 4. 影响范围与验证方案

### 4.1 单元测试更新
同步更新 [`test/game_layout_test.dart`](test/game_layout_test.dart) 中的布局断言：
- 将此前固定“上边距 15%、下边距 30%”的断言，升级为断言“碎片在托盘内垂直居中，且上下预留边距均大于 35% 凸头裕量”：
  ```dart
  expect((actualTopMargin - actualBottomMargin).abs(), lessThan(1.0));
  expect(actualTopMargin, greaterThanOrEqualTo(pieceHeight * 0.35));
  expect(actualBottomMargin, greaterThanOrEqualTo(pieceHeight * 0.35));
  ```

### 4.2 验证指标
1. **静态代码分析**：运行 `flutter analyze`，保持 **0 警告 0 错误**；
2. **布局专项测试**：运行 `flutter test test/game_layout_test.dart`，38/38 项测试全部通过；
3. **全量回归测试**：运行 `flutter test`，全量 233/233 项单元测试 **100% 全部通过**；
4. **平台构建验证**：运行 `flutter build windows --debug`，成功生成 `JigsawFox.exe` 无任何编译异常。
