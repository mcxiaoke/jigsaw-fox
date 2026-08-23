import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/events.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart' show Color, Paint, PaintingStyle;

import '../logic/geometry/piece_shape.dart';
import 'jigsaw_puzzle_game.dart';

/// Flame component responsible for rendering a jigsaw piece with custom bezier clipping,
/// crisp interlocking borders, hit testing, tray anchoring, and cluster-wide drag interactions.
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

  static final Paint _outerBorderPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.0
    ..color = const Color(0x66000000)
    ..isAntiAlias = true;

  static final Paint _innerBorderPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0
    ..color = const Color(0x88FFFFFF)
    ..isAntiAlias = true;

  static final Paint _highlightBorderPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5
    ..color = const Color(0xFF4CAF50)
    ..isAntiAlias = true;

  bool isHighlight = false;

  @override
  bool containsLocalPoint(Vector2 point) {
    // If scaled, normalize point by scale
    final effectiveX = scale.x != 0 ? point.x / scale.x : point.x;
    final effectiveY = scale.y != 0 ? point.y / scale.y : point.y;
    return shape.containsLocalPoint(ui.Offset(effectiveX, effectiveY), rot);
  }

  @override
  void render(ui.Canvas canvas) {
    canvas.save();

    // 1. Clip exact jigsaw shape
    canvas.clipPath(shape.path);

    // 2. Draw texture slice from original image
    canvas.drawImageRect(
      image,
      srcRect,
      shape.fillRect,
      _imagePaint,
    );

    // 3. Draw dual-tone border unless game is completed and borders are hidden
    if (!hideBorders) {
      canvas.drawPath(shape.path, _outerBorderPaint);
      canvas.drawPath(
        shape.path,
        isHighlight ? _highlightBorderPaint : _innerBorderPaint,
      );
    }

    canvas.restore();
  }

  @override
  void onDragStart(DragStartEvent event) {
    super.onDragStart(event);
    isDragging = true;
    game.handlePieceDragStart(this);
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    super.onDragUpdate(event);
    if (!isDragging) return;
    // Deliver delta to game cluster handler
    game.handlePieceDragUpdate(this, event.localDelta);
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
  void animateTo(Vector2 targetPos, {double duration = 0.12}) {
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
  void animateScaleTo(Vector2 targetScale, {double duration = 0.12}) {
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
}
