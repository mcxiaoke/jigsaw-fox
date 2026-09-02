import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/events.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart'
    show BlurStyle, Color, MaskFilter, Paint, PaintingStyle;

import '../logic/geometry/piece_shape.dart';
import '../logic/rendering/linen_texture_manager.dart';
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
    with DragCallbacks, TapCallbacks, HasGameReference<JigsawPuzzleGame> {
  PuzzlePieceComponent({
    required this.id,
    required this.r,
    required this.c,
    required this.shape,
    required this.image,
    required this.srcRect,
    required Vector2 initialPosition,
    required Vector2 baseSize,
  }) : super(position: initialPosition, size: baseSize, anchor: Anchor.topLeft);

  /// 碎片唯一编号 ID
  final int id;

  /// 在目标完整拼图中的目标网格行索引（0 到 rows - 1）
  final int r;

  /// 在目标完整拼图中的目标网格列索引（0 到 cols - 1）
  final int c;

  /// 预计算的几何贝塞尔轮廓与包围盒
  PieceShape shape;

  /// 在窗口 resize 或尺寸改变时动态刷新几何贝塞尔轮廓与逻辑尺寸
  void updateShapeAndSize(PieceShape newShape, Vector2 newBaseSize) {
    shape = newShape;
    size.setFrom(newBaseSize);
  }

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

  /// 是否已被吸附归位锁定（锁定后禁止拖拽移动，置于最底层渲染）
  bool isLocked = false;

  /// 是否被边缘筛选过滤隐藏（当开启仅显示边缘碎片时，未拼的内部碎片会被过滤隐藏）
  bool isFilteredOut = false;

  /// 归一化抓取锚点（用于保持光标在缩放过程中与拾取点锁定）
  double grabAnchorX = 0.5;
  double grabAnchorY = 0.5;

  // 托盘手势歧义阈值判定：托盘内碎片在未明确向上拖出前，不应随手指移动，避免误触导致左右滑动托盘时碎片跟手
  Vector2? _trayDragStartPos;
  bool _pendingTrayDrag = false;
  bool _trayScrollLocked = false;

  /// 计算玩家光标相对碎片逻辑包围盒的归一化锚点坐标 ([0.0, 1.0])
  void computeGrabAnchor(Vector2 canvasPos) {
    final curScaleX = scale.x > 0.001 ? scale.x : 1.0;
    final curScaleY = scale.y > 0.001 ? scale.y : 1.0;
    final visualW = size.x * curScaleX;
    final visualH = size.y * curScaleY;

    grabAnchorX = ((canvasPos.x - position.x) / visualW).clamp(0.0, 1.0);
    grabAnchorY = ((canvasPos.y - position.y) / visualH).clamp(0.0, 1.0);
  }

  // ---------------------------------------------------------------------------
  // 视觉画笔常量配置与选值理由
  // ---------------------------------------------------------------------------

  /// 纹理贴图画笔：启用双线性抗锯齿插值，确保在缩放和移动时不出现像素噪点
  static final Paint _imagePaint = Paint()
    ..filterQuality = ui.FilterQuality.medium
    ..isAntiAlias = true;

  /// 静止/贴地接触微阴影画笔（Contact AO）：
  /// - 模糊半径 1.0px，垂直位移 0.8px，透明度 0x30 (约 19%)
  /// - 模拟硬纸板受重力紧压在底托/桌面时的环境光遮挡（Ambient Occlusion），形成逼真贴地感。
  static final Paint _contactShadowPaint = Paint()
    ..color = const Color(0x30000000)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.0)
    ..isAntiAlias = true;

  /// 拖拽拾起悬浮扩散软阴影画笔：
  /// - 模糊半径 7.0px，偏移 (2.0, 6.0px)，透明度 0x40 (约 25%)
  /// - 模拟碎片被玩家手指拾起并悬浮在棋盘上方时的真实光学向右下方扩散的深层软投影。
  static final Paint _dragShadowPaint = Paint()
    ..color = const Color(0x40000000)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7.0)
    ..isAntiAlias = true;

  /// 纸板物理厚度截面填充画笔（方案 2）：
  /// - 填充荷兰天然白卡/灰卡纸的夹芯浅米灰截面色（Color(0xFFD6D0C4)）
  static final Paint _cardboardSidePaint = Paint()
    ..color = const Color(0xFFD6D0C4)
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;

  /// 纸板厚度背光侧底边切线画笔（方案 2）：
  /// - 线宽 0.8px，半透明深黑，增强 1.8mm 纸板厚度侧边的分界清晰度
  static final Paint _cardboardBottomEdgePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8
    ..color = const Color(0x55000000)
    ..isAntiAlias = true;

  /// 迎光面冲压倒角高光微边画笔（方案 1）：
  /// - Top 边与 Left 边（迎光面）：线宽 0.8px，约 27% 半透明纯白（Color(0x45FFFFFF)）
  /// - 模拟来自左上方 135° 光源照射在金属刀模挤压 V 形倒角上的柔和反光。
  static final Paint _highlightOutlinePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8
    ..color = const Color(0x45FFFFFF)
    ..isAntiAlias = true;

  /// 背光面冲压切缝暗线画笔（方案 1）：
  /// - Bottom 边与 Right 边（背光面）：线宽 1.2px，约 44% 半透明深黑（Color(0x70000000)）
  /// - 模拟金属冲压刀模深陷切口与拼合咬合时的清晰立体阴影线。
  static final Paint _shadowOutlinePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2
    ..color = const Color(0x70000000)
    ..isAntiAlias = true;

  /// 吸附成功高亮画笔（鲜艳绿色光晕）
  static final Paint _snapHighlightPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5
    ..color = const Color(0xFF4CAF50)
    ..isAntiAlias = true;

  /// 当前是否处于吸附高亮或边缘筛选高亮状态
  bool isHighlight = false;

  /// 碰撞拾取判定：精确测试触摸点是否在碎片实际贝塞尔外轮廓内
  @override
  bool containsLocalPoint(Vector2 point) {
    if (isFilteredOut) return false;
    final offset = ui.Offset(point.x, point.y);
    return shape.containsLocalPoint(offset, rot);
  }

  /// 核心渲染循环（分层渲染管线）
  @override
  void render(ui.Canvas canvas) {
    if (isFilteredOut || hideBorders) return; // 边缘过滤隐藏或通关后整图渲染，跳过单片绘制

    final isElevated = isDragging && !isInTray;

    // 1. 第一层：根据当前物理状态绘制 3D 软阴影（在剪裁外部）
    canvas.save();
    if (isElevated) {
      canvas.translate(2.0, 6.0);
      canvas.drawPath(shape.path, _dragShadowPaint);
    } else {
      canvas.translate(0.0, 0.8);
      canvas.drawPath(shape.path, _contactShadowPaint);
    }
    canvas.restore();

    // 2. 第二层：在拾起/悬浮状态下，绘制 1.8mm 硬纸板物理厚度截面（3D Extrusion Side）
    if (isElevated) {
      canvas.save();
      canvas.translate(0.8, 1.6);
      canvas.drawPath(shape.path, _cardboardSidePaint);
      canvas.drawPath(shape.shadowPath, _cardboardBottomEdgePaint);
      canvas.restore();
    }

    // 3. 第三层：正面图案纹理层与亚麻漫反射层（使用精确二次贝塞尔曲线 Path 剪裁画布）
    canvas.save();
    canvas.clipPath(shape.path);
    canvas.drawImageRect(image, srcRect, shape.fillRect, _imagePaint);
    // 方案 4：亚麻布纹压花 / 纸质漫反射微纹理（消除数码塑料反光）
    final linenPaint = LinenTextureManager.paint;
    if (LinenTextureManager.enabled && linenPaint != null) {
      canvas.drawRect(shape.fillRect, linenPaint);
    }
    canvas.restore();

    // 4. 第四层：绘制表面定向冲压光影切线或吸附高亮光效
    if (isHighlight) {
      canvas.drawPath(shape.path, _snapHighlightPaint);
    } else {
      // 迎光面（Top & Left）柔白高光微边
      canvas.drawPath(shape.highlightPath, _highlightOutlinePaint);
      // 背光面（Bottom & Right）深黑冲压暗线
      canvas.drawPath(shape.shadowPath, _shadowOutlinePaint);
    }
  }

  // ---------------------------------------------------------------------------
  // 拖拽与轻点手势生命周期
  // ---------------------------------------------------------------------------

  @override
  void onTapDown(TapDownEvent event) {
    if (isFilteredOut || game.isSolved || game.isPinching) return;

    // 如果当前游戏已有吸附抓取的碎片，任意点击都触发放下
    if (game.holdingPiece != null) {
      event.handled = true;
      game.dropHoldingPiece();
      return;
    }

    if (isLocked) return;

    // 托盘内碎片：点击不立即拾取，交由拖拽阈值统一判定为“横向滚动托盘”或“向上拖出”
    // 避免手机上左右滑动托盘时误触移动碎片，符合“大部分时候判定为左右滑动”的预期
    if (isInTray && !game.isTabletop) {
      return;
    }

    super.onTapDown(event);
    event.handled = true;
    computeGrabAnchor(event.canvasPosition);
    game.startHoldingPiece(this, grabAnchorX, grabAnchorY);
  }

  @override
  void onDragStart(DragStartEvent event) {
    if (isFilteredOut || isLocked || game.isSolved || game.isPinching) return;

    // 若已有正在拖拽的碎片，同集群保持跟随，不打断不重入
    if (game.holdingPiece != null) {
      if (game.holdingPiece == this ||
          game.holdingPiece!.clusterId == clusterId) {
        return;
      }
      game.dropHoldingPiece();
    }

    // 托盘内碎片：进入待判定状态，不立即拾取；由 onDragUpdate 依据滑动角度阈值
    // 区分“横向滚动托盘”与“向上拖出碎片”，阈值设计保证大部分手势判定为滚动
    if (isInTray && !game.isTabletop) {
      _pendingTrayDrag = true;
      _trayScrollLocked = false;
      _trayDragStartPos = event.canvasPosition.clone();
      isDragging = false;
      return;
    }

    super.onDragStart(event);
    isDragging = true;
    computeGrabAnchor(event.canvasPosition);
    game.startHoldingPiece(this, grabAnchorX, grabAnchorY);
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    if (game.isPinching) {
      if (isDragging) {
        isDragging = false;
        game.cancelPieceDrag(this);
      }
      _pendingTrayDrag = false;
      _trayDragStartPos = null;
      _trayScrollLocked = false;
      return;
    }

    // 托盘内碎片待判定：依据滑动角度/位移阈值区分横向滚动与向上拖出
    if (_pendingTrayDrag) {
      final startPos = _trayDragStartPos;
      if (startPos == null) return;
      final curPos = event.canvasEndPosition;
      final delta = curPos - startPos;
      final adx = delta.x.abs();
      final ady = delta.y; // 向上为负
      final dist = delta.length;

      // 位移过小，继续等待更多位移以判定方向（避免微抖误判）
      if (dist < 8.0) {
        return;
      }

      // 已锁定为横向滚动：持续滚动托盘，不再转为拖拽碎片
      if (_trayScrollLocked) {
        game.scrollTray(event.canvasDelta.x);
        return;
      }

      // 阈值定义（经权衡：大部分手势应判定为左右滑动托盘）：
      // - 向上拖出需同时满足：向上位移 >= 12px 且 垂直分量 > 水平 * 1.7（约 >59° 偏离水平，接近垂直）
      // - 其余所有情况（横向为主、斜向、下移、微小上移）均判为托盘滚动
      const double upThreshold = 12.0;
      const double angleFactor = 1.7; // tan(59.5°) ≈1.7，角度陡峭才视为拖出

      if (ady < -upThreshold && ady.abs() > adx * angleFactor) {
        // 确认为向上拖出：正式进入持有拖拽状态，集群整体跟随光标
        _pendingTrayDrag = false;
        _trayDragStartPos = null;
        _trayScrollLocked = false;
        super.onDragUpdate(event);
        isDragging = true;
        computeGrabAnchor(curPos);
        game.startHoldingPiece(this, grabAnchorX, grabAnchorY);
        game.updateHoldingPiecePosition(curPos);
        return;
      } else {
        // 判定为托盘左右滚动（不移动碎片），直接驱动托盘滚动
        // 当已产生显著横向位移（>16px）且横向占优，锁定为滚动以避免中途突变为拖拽产生抖动
        if (adx > 16.0 && adx > ady.abs()) {
          _trayScrollLocked = true;
        }
        game.scrollTray(event.canvasDelta.x);
        return;
      }
    }

    if (!isDragging && game.holdingPiece != this) return;

    super.onDragUpdate(event);
    // 驱动引擎以光标当前绝对位置精准更新碎片及集群的位置与缩放（拖拽过程全程平滑跟随，绝不中途 drop）
    game.updateHoldingPiecePosition(event.canvasEndPosition);
  }

  @override
  void onDragEnd(DragEndEvent event) {
    // 待判定阶段直接结束：仅滚动托盘，不产生拖拽/吸附
    if (_pendingTrayDrag) {
      _pendingTrayDrag = false;
      _trayDragStartPos = null;
      _trayScrollLocked = false;
      super.onDragEnd(event);
      return;
    }
    super.onDragEnd(event);
    if (!isDragging && game.holdingPiece != this) return;

    isDragging = false;
    // 鼠标抬起松手，平稳释放放下并结算吸附
    game.dropHoldingPiece();
  }

  @override
  void onDragCancel(DragCancelEvent event) {
    if (_pendingTrayDrag) {
      _pendingTrayDrag = false;
      _trayDragStartPos = null;
      _trayScrollLocked = false;
      super.onDragCancel(event);
      return;
    }
    super.onDragCancel(event);
    if (!isDragging && game.holdingPiece != this) return;

    isDragging = false;
    game.dropHoldingPiece();
  }

  /// 立即清除所有正在运行的补间动画（如 MoveToEffect / ScaleEffect）
  void clearActiveEffects() {
    removeAll(children.whereType<Effect>());
  }

  /// 带有平滑曲线的缓动平移位移动画
  void animateTo(Vector2 targetPos, {double duration = 0.15}) {
    removeAll(children.whereType<MoveEffect>());
    if ((position - targetPos).length < 0.5) {
      position.setFrom(targetPos);
      return;
    }
    add(
      MoveToEffect(
        targetPos,
        EffectController(duration: duration, curve: Curves.easeOutQuad),
      ),
    );
  }

  /// 带有平滑曲线的缓动缩放动画
  void animateScaleTo(Vector2 targetScale, {double duration = 0.15}) {
    removeAll(children.whereType<ScaleEffect>());
    if ((scale - targetScale).length < 0.01) {
      scale.setFrom(targetScale);
      return;
    }
    add(
      ScaleEffect.to(
        targetScale,
        EffectController(duration: duration, curve: Curves.easeOutQuad),
      ),
    );
  }

  /// 碎片成功吸附就位时触发短暂的流光反馈特效
  void triggerSnapGlow() {
    isHighlight = true;
    Future.delayed(const Duration(milliseconds: 380), () {
      if (isRemoved) return;
      isHighlight =
          game.isBorderFilterActive && game.edgeLayout.edgesFor(r, c).isBorder;
    });
  }
}
