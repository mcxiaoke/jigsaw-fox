# 拼图游戏渲染性能与首帧优化方案

**创建日期**：2026-09-06  
**目标版本**：v1.0.0+  
**核心原则**：优化仅限视觉呈现层（Render/Pipeline），绝对不破坏已验证通过的触控拾取、手势拖拽、并查集集群协同与吸附对齐逻辑。

---

## 1. 背景与 Profiler 分析回顾

在前期 DevTools CPU Profiler 采样中，定位并完成了音频服务的第一阶段优化（禁用 `AudioPlayer` 的 `FramePositionUpdater` 帧回调轮询，释放约 30% 无效 CPU 算力）。

随后的第二次采样分析（`profiler002.png` 与 `profiler003.png`）揭示了渲染层面的核心性能特征：
1. **常态运行健康**：在 8s 之后的常态游戏循环与拖拽手势中，帧率分布均匀，无持续卡顿；
2. **首帧长耗时（First Frame Jank）**：进入拼图界面的首帧（0 ~ 7.14s）出现长达 7 秒的管线阻塞；
3. **Canvas 绘制热点集中**：`PuzzlePieceComponent.render` 累积耗时约占采样期的 20%，`_NativeCanvas.__drawPathMethod$FfiNative`（1.17s）与 `_NativeCanvas.__drawRect$Method$FfiNative`（436ms）成为主要开销。

---

## 2. 核心架构红线与隔离设计

拼图游戏的核心交互具有高度稳定性要求，优化方案必须具备零破坏性：

```
+-------------------------------------------------------------+
|                     用户输入与手势层                         |
|  - Listener (PointerDown / PointerMove / PointerUp)         |
|  - PuzzlePieceComponent.containsLocalPoint (纯 CPU 射线算法) |
|  - JigsawPuzzleGame 手势状态机与并查集集群拖拽              |
+-------------------------------------------------------------+
                              | (仅更新 position / scale / rot)
                              v
+-------------------------------------------------------------+
|                     视觉渲染管线 (本优化范围)                 |
|  - 方案一：Flutter Widget 树图层隔离 (RepaintBoundary)        |
|  - 方案一：顶层遮罩淡出代替对 GameWidget 的 AnimatedOpacity  |
|  - 方案二：亚麻布纹 ImageShader 硬件友好混合模式优化          |
|  - 方案三 (远期)：静止碎片 Picture 离屏缓存 (Cache-as-Picture)|
+-------------------------------------------------------------+
```

- **数学几何隔离**：`PieceShape.containsLocalPoint()` 纯依靠数学点在多边形内的判断，不依赖任何 Canvas 状态或渲染管线，手势判定热区不受任何渲染变动影响；
- **组件树逻辑隔离**：组件的生命周期、位置（`position`）、旋转（`rot`）、吸附判定（`isLocked`）均由 `JigsawPuzzleGame` 统筹控制，渲染层的绘制优化纯属被动呈现。

---

## 3. 方案一：GameWidget 图层解耦与遮罩淡入优化

### 3.1 现状与瓶颈机理
在 `lib/pages/game_page.dart` 中：
```dart
AnimatedOpacity(
  opacity: _gameFadeIn ? 1.0 : 0.0,
  duration: const Duration(milliseconds: 300),
  curve: Curves.easeOutCubic,
  child: ClipRect(
    child: GameWidget<JigsawPuzzleGame>(
      game: _game!,
    ),
  ),
)
```
- **问题 1（昂贵的离屏缓冲）**：`AnimatedOpacity` 在动画过程中（`opacity` 从 0.0 到 1.0），会强迫 Flutter 渲染引擎为 `GameWidget` 分配整屏大小的离屏纹理（Offscreen Buffer / SaveLayer），将整张游戏画布（24 块碎片 + 底板 + 阴影）绘制在离屏缓冲中再带 Alpha 合成回屏幕；
- **问题 2（重合峰值）**：首帧往往伴随着所有碎片与底板的首次 Paint，此时叠加整屏离屏缓冲分配与合成，加剧 GPU 负担；
- **问题 3（RenderLayer 互相牵连）**：缺少 `RepaintBoundary` 时，游戏内部的重绘可能触发上层 Widget 树多余的图层遍历。

### 3.2 优化实现规范
1. **加入 `RepaintBoundary`**：将 `GameWidget` 包裹在独立的 `RepaintBoundary` 中，确保游戏绘制图层与外层 UI、顶部 AppBar、底部交互栏完全隔离；
2. **顶层纯色遮罩淡出（Overlay Fade Out）代替 GameWidget 自身的 AnimatedOpacity**：
   - `GameWidget` 始终保持 `opacity = 1.0` 处于正常绘制状态，无需分配昂贵的离屏透明缓冲；
   - 在 `GameWidget` 上方叠放一层与背景同色的轻量 `IgnorePointer` + `AnimatedOpacity` 遮罩层；
   - 进入游戏时，遮罩层从不透明变为透明（Fade Out），动画结束后彻底从树中移除；
   - 视觉体验保持平滑渐入，GPU 开销减少整整一个层级。

---

## 4. 方案二：亚麻布纹材质着色器轻量化

### 4.1 现状与瓶颈机理
在 `lib/logic/rendering/linen_texture_manager.dart`：
```dart
_linenPaint = Paint()
  ..shader = shader
  ..blendMode = BlendMode.softLight
  ..isAntiAlias = true;
```
- **问题 1（Non-separable 复杂着色器）**：`BlendMode.softLight` 是典型的非分离型混合模式，GPU 无法使用标准硬件混合单元直接合并，需要片元着色器读回目标像素执行非线性多项式方程计算；
- **问题 2（首帧 Shader Compilation Jank）**：当 Flutter 引擎首次遇到 `ImageShader` + `BlendMode.softLight` 时，GPU 驱动必须在主渲染线程即时编译 HLSL/GLSL 着色器程序，产生严重卡顿；
- **问题 3（高频开销）**：每一块碎片每帧执行 `canvas.drawRect(shape.fillRect, linenPaint)`，在 24 片模式下每秒执行上千次软光混合。

### 4.2 优化实现规范
1. **贴图微调与混合模式切换**：
   - 将 `BlendMode.softLight` 替换为 GPU 硬件直接支持的 `BlendMode.srcOver`；
   - 微调无缝平铺贴图中的经纬纤维与噪点透明度（Alpha），使高光线条（白色微透明）与暗纹凹槽（黑色微透明）直接通过 Alpha 通道实现哑光质感；
2. **保持完全一致的视觉艺术风格**：
   - 维持 4px 编织周期的横纵纤维与经纬节点；
   - 消除塑料反光的同时，消除片元着色器回读和动态着色器编译开销。

---

## 5. 方案三（远期规划）：静止碎片 Picture 离屏录制缓存

*注：本方案作为后续备选方案，待方案一与方案二验证完毕后根据实际帧率需求择机实施。*

- **核心思路**：在 `PuzzlePieceComponent` 内部增加 `ui.Picture? _cachedPicture`；
- **静止状态**：碎片在桌面或托盘静止时，直接调用 `canvas.drawPicture(_cachedPicture!)`，跳过 `clipPath`、原图采样与多重描边；
- **动态状态**：碎片被手指拾起、吸附高亮、旋转或尺寸改变时，清空缓存执行实时绘制；
- **对触控逻辑的影响**：零影响，`containsLocalPoint` 纯数学几何计算不涉及 Picture。

---

## 6. 验证标准

1. **功能验证**：
   - 碎片点击拾取、托盘拖拽滑出、棋盘移动无手感差异；
   - 碎片吸附对齐、集群合并、通关胜利动画正常触发；
2. **性能验证**：
   - DevTools CPU Profiler 再次采样，验证首帧耗时明显缩短；
   - `_NativeCanvas.__drawRectMethod$FfiNative` 耗时显著下降；
3. **门禁验证**：
   - `dart format` 无格式警告；
   - `flutter analyze` 0 error / 0 warning；
   - `flutter test` 全部测试通过；
   - `flutter build windows --debug` 编译通过。
