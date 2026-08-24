import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/events.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart'
    show BlurStyle, Color, MaskFilter, Paint, PaintingStyle;

import '../logic/geometry/piece_shape.dart';
import 'jigsaw_puzzle_game.dart';

/// Flame component responsible for rendering a jigsaw piece with authentic smooth quadratic bezier clipping,
/// crisp realistic cut outlines, dynamic floating drop shadows, normalized tray scaling, and cluster drag-and-drop.
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

  final int id;
  final int r;
  final int c;
  final PieceShape shape;
  final ui.Image image;
  final ui.Rect srcRect;

  bool isDragging = false;
  bool isInTray = true;
  int clusterId = 0;
  int rot = 0;
  bool hideBorders = false;

  // Visual paints
  static final Paint _imagePaint = Paint()
    ..filterQuality = ui.FilterQuality.medium
    ..isAntiAlias = true;

  // 3D Shadow paints
  static final Paint _restShadowPaint = Paint()
    ..color = const Color(0x28000000)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)
    ..isAntiAlias = true;

  static final Paint _dragShadowPaint = Paint()
    ..color = const Color(0x45000000)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.5)
    ..isAntiAlias = true;

  // Clean, crisp cutline outline paint - authentic subtle press line
  static final Paint _mainOutlinePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.75
    ..color = const Color(0x35000000)
    ..isAntiAlias = true;

  static final Paint _snapHighlightPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5
    ..color = const Color(0xFF4CAF50)
    ..isAntiAlias = true;

  bool isHighlight = false;

  @override
  bool containsLocalPoint(Vector2 point) {
    final offset = ui.Offset(point.x, point.y);
    if (shape.containsLocalPoint(offset, rot)) {
      return true;
    }
    return shape.fillRect.contains(offset);
  }

  @override
  void render(ui.Canvas canvas) {
    if (hideBorders) return; // When solved, full board renders the crisp complete image

    // 1. Drop shadow when unplaced
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

    // 2. Clip exact smooth jigsaw shape
    canvas.clipPath(shape.path);

    // 3. Draw texture slice from original image
    canvas.drawImageRect(
      image,
      srcRect,
      shape.fillRect,
      _imagePaint,
    );

    // 4. Draw clean, subtle cut line or snap highlight
    if (isHighlight) {
      canvas.drawPath(shape.path, _snapHighlightPaint);
    } else {
      canvas.drawPath(shape.path, _mainOutlinePaint);
    }

    canvas.restore();
  }

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

    // Smooth continuous scaling based on vertical distance between tray and board
    final trayTop = game.trayPosition.y;
    const transitionBand = 60.0;
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

  /// Smoothly animates piece to target position.
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

  /// Smoothly animates piece scale.
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

  /// Triggers a brief sparkle glow feedback when piece snaps into place.
  void triggerSnapGlow() {
    isHighlight = true;
    Future.delayed(const Duration(milliseconds: 380), () {
      if (isRemoved) return;
      isHighlight = game.isBorderFilterActive &&
          game.edgeLayout.edgesFor(r, c).isBorder;
    });
  }
}
