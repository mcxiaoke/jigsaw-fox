import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/events.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart'
    show BlurStyle, Color, MaskFilter, Paint, PaintingStyle;

import '../logic/geometry/piece_shape.dart';
import 'jigsaw_puzzle_game.dart';

/// 拼图碎片渲染与交互组件（基于 Flame 游戏引擎）。
///
/// 【核心功能与职责】：
/// 1. **切片渲染流水线**：
///    - 3D 软阴影层：根据静止/拾起状态呈现多阶物理软阴影（Rest / Drag Shadow）；
///    - 精准贝塞尔剪裁：使用 [PieceShape.path] 进行 `clipPath`，实现 100% 圆滑卡扣；
///    - 纹理贴图采样：使用 [PieceShape.srcRect] 和 [PieceShape.fillRect] 进行无失真采样；
///    - 物理冲压切线：绘制 0.75px 半透明深灰切缝微线，模拟真实冲压刀模质感。
/// 2. **手势与拖拽状态机**：
///    - 响应触摸拖动（DragCallbacks），支持多块碎片集群（Cluster）协同拖拽；
///    - 托盘与棋盘之间的平滑尺寸无缝插值缩放（Smooth Continuous Transition）。
/// 3. **吸附反馈与光效**：
///    - 吸附成功时触发短暂高亮流光特效（Glow Feedback）。
class PuzzlePieceComponent extends PositionComponent
    with DragCallbacks, HasGameReference<JigsawPuzzleGame> {
  PuzzlePieceComponent({
    required this.id,
    required this.r,
    required this.c,
    required this.shape,
    required this.image,
    required this.srcRect,
    required Vector2 initialPosition,
    required Vector2 baseSize,
  }) : super(
          position: initialPosition,
          size: baseSize,
          anchor: Anchor.topLeft,
        );

  /// 碎片唯一编号 ID
  final int id;

  /// 在目标完整拼图中的目标网格行索引（0 到 rows - 1）
  final int r;

  /// 在目标完整拼图中的目标网格列索引（0 到 cols - 1）
  final int c;

  /// 预计算的几何贝塞尔轮廓与包围盒
  final PieceShape shape;

  /// 拼图原图纹理对象
  final ui.Image image;

  /// 原图采样区域矩形
  final ui.Rect srcRect;

  /// 当前是否正在被用户手指拖拽
  bool isDragging = false;

  /// 当前是否位于底部托盘中（影响缩放比例与阴影深度）
  bool isInTray = true;

  /// 所属已合并碎片集群的根节点 ID（并查集标识符）
  int clusterId = 0;

  /// 碎片的当前旋转状态（0=0°, 1=90°, 2=180°, 3=270°）
  int rot = 0;

  /// 是否隐藏碎片边界（拼图通关后整体由底板渲染整图，碎片停止绘制以节省 GPU 算力）
  bool hideBorders = false;

  // ---------------------------------------------------------------------------
  // 视觉画笔常量配置与选值理由
  // ---------------------------------------------------------------------------

  /// 纹理贴图画笔：启用双线性抗锯齿插值，确保在缩放和移动时不出现像素噪点
  static final Paint _imagePaint = Paint()
    ..filterQuality = ui.FilterQuality.medium
    ..isAntiAlias = true;

  /// 静止/托盘贴地阴影画笔：
  /// - 模糊半径 1.5px，垂直位移 1.2px，透明度 0x28 (约 16%)
  /// - 模拟硬纸板紧贴底托时的环境光遮挡（Ambient Occlusion），形成微弱但真实的实体感。
  static final Paint _restShadowPaint = Paint()
    ..color = const Color(0x28000000)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
    ..isAntiAlias = true;

  /// 拖拽拾起悬浮软阴影画笔：
  /// - 模糊半径 5.5px，垂直位移 5.0px，透明度 0x45 (约 27%)
  /// - 模拟碎片被玩家手指拾起并悬浮在棋盘上方时的真实光学扩散投影。
  static final Paint _dragShadowPaint = Paint()
    ..color = const Color(0x45000000)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.5)
    ..isAntiAlias = true;

  /// 物理冲压切线画笔：
  /// - 线宽 0.75px，颜色为 21% 透明度的深黑色（Color(0x35000000)）
  /// - 【设计理由】：摒弃了生硬的粗白高光与粗黑阴影，采用极细半透明微线，
  ///   完美还原实体拼图刀模冲压在纸板/木板表面留下的物理微凹切口。
  static final Paint _mainOutlinePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.75
    ..color = const Color(0x35000000)
    ..isAntiAlias = true;

  /// 吸附成功高亮画笔（鲜艳绿色光晕）
  static final Paint _snapHighlightPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5
    ..color = const Color(0xFF4CAF50)
    ..isAntiAlias = true;

  /// 当前是否处于吸附高亮或边缘筛选高亮状态
  bool isHighlight = false;

  /// 碰撞拾取判定：精确测试触摸点是否在碎片实际贝塞尔外轮廓或包围盒内
  @override
  bool containsLocalPoint(Vector2 point) {
    final offset = ui.Offset(point.x, point.y);
    if (shape.containsLocalPoint(offset, rot)) {
      return true;
    }
    return shape.fillRect.contains(offset);
  }

  /// 核心渲染循环（分层渲染管线）
  @override
  void render(ui.Canvas canvas) {
    if (hideBorders) return; // 通关后整图渲染，跳过单片绘制

    // 1. 第一层：根据当前物理状态绘制 3D 软阴影（在剪裁外部）
    canvas.save();
    if (isDragging && !isInTray) {
      canvas.translate(0, 5.0);
      canvas.drawPath(shape.path, _dragShadowPaint);
    } else if (isInTray) {
      canvas.translate(0, 1.2);
      canvas.drawPath(shape.path, _restShadowPaint);
    }
    canvas.restore();

    canvas.save();

    // 2. 第二层：使用精确二次贝塞尔曲线 Path 剪裁画布
    canvas.clipPath(shape.path);

    // 3. 第三层：将原图对应像素块绘制到剪裁区域内
    canvas.drawImageRect(
      image,
      srcRect,
      shape.fillRect,
      _imagePaint,
    );

    // 4. 第四层：绘制冲压微切线或吸附高亮光效
    if (isHighlight) {
      canvas.drawPath(shape.path, _snapHighlightPaint);
    } else {
      canvas.drawPath(shape.path, _mainOutlinePaint);
    }

    canvas.restore();
  }

  // ---------------------------------------------------------------------------
  // 拖拽手势生命周期与协同处理
  // ---------------------------------------------------------------------------

  @override
  void onDragStart(DragStartEvent event) {
    if (game.isSolved) return;
    super.onDragStart(event);
    isDragging = true;
    game.handlePieceDragStart(this);
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    super.onDragUpdate(event);
    if (!isDragging) return;

    final delta = event.canvasDelta;
    game.handlePieceDragUpdate(this, delta);

    // 托盘与棋盘之间的平滑无级尺寸缩放插值过渡
    final trayTop = game.trayPosition.y;
    const transitionBand = 60.0; // 60px 缓冲区间
    final boardScale = game.zoom;

    if (position.y >= trayTop) {
      scale.setAll(game.trayPieceScale);
    } else if (position.y <= trayTop - transitionBand) {
      scale.setAll(boardScale);
    } else {
      final t = (trayTop - position.y) / transitionBand;
      final currentScale =
          game.trayPieceScale + (boardScale - game.trayPieceScale) * t;
      scale.setAll(currentScale);
    }
  }

  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    if (!isDragging) return;
    isDragging = false;
    game.handlePieceDragEnd(this);
  }

  @override
  void onDragCancel(DragCancelEvent event) {
    super.onDragCancel(event);
    if (!isDragging) return;
    isDragging = false;
    game.handlePieceDragEnd(this);
  }

  /// 带有平滑曲线的缓动平移位移动画
  void animateTo(Vector2 targetPos, {double duration = 0.15}) {
    if ((position - targetPos).length < 0.5) {
      position.setFrom(targetPos);
      return;
    }
    add(
      MoveToEffect(
        targetPos,
        EffectController(
          duration: duration,
          curve: Curves.easeOutQuad,
        ),
      ),
    );
  }

  /// 带有平滑曲线的缓动缩放动画
  void animateScaleTo(Vector2 targetScale, {double duration = 0.15}) {
    if ((scale - targetScale).length < 0.01) {
      scale.setFrom(targetScale);
      return;
    }
    add(
      ScaleEffect.to(
        targetScale,
        EffectController(
          duration: duration,
          curve: Curves.easeOutQuad,
        ),
      ),
    );
  }

  /// 碎片成功吸附就位时触发短暂的流光反馈特效
  void triggerSnapGlow() {
    isHighlight = true;
    Future.delayed(const Duration(milliseconds: 380), () {
      if (isRemoved) return;
      isHighlight = game.isBorderFilterActive &&
          game.edgeLayout.edgesFor(r, c).isBorder;
    });
  }
}
