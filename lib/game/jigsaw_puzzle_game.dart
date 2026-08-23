import 'dart:math';
import 'dart:ui' show Color, Image, Paint, PaintingStyle;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show decodeImageFromList;

typedef PuzzleImage = Image;

/// Decodes raw image bytes into a [PuzzleImage] usable by Flame sprites.
Future<PuzzleImage> decodeFlameImage(Uint8List bytes) =>
    decodeImageFromList(bytes);

class JigsawPuzzleGame extends FlameGame {
  JigsawPuzzleGame({
    required this.image,
    required this.rows,
    required this.cols,
    required this.onSolved,
  });

  final PuzzleImage image;
  final int rows;
  final int cols;
  final VoidCallback onSolved;

  static const _boardRatio = 0.68;
  static const _lockedLayerPriority = -1000;

  late final Vector2 boardTopLeft;
  late final Vector2 pieceSize;
  int _lockedCount = 0;
  int _topPriority = 0;
  bool _solvedNotified = false;

  int get totalCount => rows * cols;
  int get lockedCount => _lockedCount;

  @override
  Future<void> onLoad() async {
    final imageAspect = image.width / image.height;
    var boardW = size.x * _boardRatio;
    var boardH = boardW / imageAspect;
    final maxH = size.y * _boardRatio;
    if (boardH > maxH) {
      boardH = maxH;
      boardW = boardH * imageAspect;
    }
    final boardSize = Vector2(boardW, boardH);
    pieceSize = Vector2(boardW / cols, boardH / rows);
    boardTopLeft = (size - boardSize) / 2;

    add(
      RectangleComponent(
        position: boardTopLeft.clone(),
        size: boardSize,
        paint: Paint()..color = const Color(0x14000000),
      ),
    );
    add(
      RectangleComponent(
        position: boardTopLeft.clone(),
        size: boardSize,
        paint: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0x55FFFFFF),
      ),
    );

    final rng = Random();
    final srcPiece = Vector2(image.width / cols, image.height / rows);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final target =
            boardTopLeft + Vector2(c * pieceSize.x, r * pieceSize.y);
        final sprite = Sprite(
          image,
          srcPosition: Vector2(c * srcPiece.x, r * srcPiece.y),
          srcSize: srcPiece.clone(),
        );
        final piece = PuzzlePiece(
          sprite: sprite,
          target: target,
          snapDistance: min(pieceSize.x, pieceSize.y) * 0.38,
          onLock: _handlePieceLocked,
          bringToFront: () => priority = ++_topPriority,
        )
          ..size = pieceSize.clone()
          ..position = _scatterPosition(rng, target, boardSize);
        add(piece);
      }
    }
  }

  /// Random spot outside the board area (inflated by half a piece) so the
  /// initial layout never looks accidentally solved.
  Vector2 _scatterPosition(Random rng, Vector2 target, Vector2 boardSize) {
    final inflate = pieceSize / 2;
    final innerMin = boardTopLeft - inflate;
    final innerMax = boardTopLeft + boardSize + inflate;
    for (var attempt = 0; attempt < 64; attempt++) {
      final p = Vector2(
        rng.nextDouble() * max(1.0, size.x - pieceSize.x),
        rng.nextDouble() * max(1.0, size.y - pieceSize.y),
      );
      final outsideX = p.x < innerMin.x || p.x > innerMax.x - pieceSize.x;
      final outsideY = p.y < innerMin.y || p.y > innerMax.y - pieceSize.y;
      if (outsideX || outsideY) return p;
    }
    return target + Vector2(20, 20);
  }

  void _handlePieceLocked() {
    _lockedCount++;
    if (_lockedCount == totalCount && !_solvedNotified) {
      _solvedNotified = true;
      onSolved();
    }
  }
}

class PuzzlePiece extends PositionComponent with DragCallbacks {
  PuzzlePiece({
    required this.sprite,
    required this.target,
    required this.snapDistance,
    required this.onLock,
    required this.bringToFront,
  });

  final Sprite sprite;
  final Vector2 target;
  final double snapDistance;
  final void Function() onLock;
  final void Function() bringToFront;

  bool locked = false;
  late final RectangleComponent _border;

  @override
  Future<void> onLoad() async {
    await add(SpriteComponent(sprite: sprite, size: size));
    _border = RectangleComponent(
      size: size,
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = const Color(0xAAFFFFFF),
    );
    await add(_border);
  }

  @override
  void onDragStart(DragStartEvent event) {
    super.onDragStart(event);
    if (locked) return;
    bringToFront();
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    super.onDragUpdate(event);
    if (locked) return;
    position += event.localDelta;
  }

  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    if (locked) return;
    if ((position - target).length <= snapDistance) {
      position.setFrom(target);
      locked = true;
      priority = JigsawPuzzleGame._lockedLayerPriority;
      _border.paint.color = const Color(0xFF66BB6A);
      onLock();
    }
  }
}
