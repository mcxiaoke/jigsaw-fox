import 'dart:math';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart'
    show Color, Paint, PaintingStyle, RRect, Radius, decodeImageFromList;

import '../logic/engine/puzzle_engine.dart';
import '../logic/engine/undo_manager.dart';
import '../logic/geometry/edge_layout.dart';
import '../logic/geometry/piece_shape.dart';
import '../logic/models/puzzle_state.dart';
import 'puzzle_piece_component.dart';

typedef PuzzleImage = ui.Image;

/// Decodes raw image bytes into a [PuzzleImage] usable by Flame.
Future<PuzzleImage> decodeFlameImage(Uint8List bytes) =>
    decodeImageFromList(bytes);

/// Tray background component that handles horizontal panning to scroll unplaced pieces.
class TrayBackgroundComponent extends PositionComponent
    with DragCallbacks, HasGameReference<JigsawPuzzleGame> {
  TrayBackgroundComponent({
    required Vector2 position,
    required Vector2 size,
  }) : super(position: position, size: size, priority: 2);

  static final Paint _bgPaint = Paint()
    ..color = const Color(0x33000000)
    ..style = PaintingStyle.fill;

  static final Paint _borderPaint = Paint()
    ..color = const Color(0x44FFFFFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;

  @override
  void render(ui.Canvas canvas) {
    final rrect = RRect.fromRectAndRadius(
      size.toRect(),
      const Radius.circular(16),
    );
    canvas.drawRRect(rrect, _bgPaint);
    canvas.drawRRect(rrect, _borderPaint);
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    super.onDragUpdate(event);
    game.scrollTray(event.localDelta.x);
  }
}

/// Flame game engine handling jigsaw puzzle canvas, bottom scrollable tray,
/// batch rendering, deterministic slicing, cluster drag-and-drop, snapping, and undo/redo stacks.
class JigsawPuzzleGame extends FlameGame {
  JigsawPuzzleGame({
    required this.image,
    required this.rows,
    required this.cols,
    int? seed,
    this.rotationEnabled = false,
    required this.onSolved,
    this.onPieceSnapped,
    this.onProgressChanged,
  })  : seed = seed ?? (DateTime.now().millisecondsSinceEpoch % 1000000),
        undoManager = UndoManager();

  final PuzzleImage image;
  final int rows;
  final int cols;
  final int seed;
  final bool rotationEnabled;
  final VoidCallback onSolved;
  final VoidCallback? onPieceSnapped;
  final ValueChanged<int>? onProgressChanged;

  final UndoManager undoManager;

  static const int _basePriority = 10;

  late Vector2 boardTopLeft;
  late Vector2 boardSize;
  late Vector2 pieceSize;

  late Vector2 trayPosition;
  late Vector2 traySize;
  double _trayScrollX = 0.0;
  double _trayPieceScale = 1.0;
  double _trayPieceWidth = 60.0;
  double _traySpacing = 16.0;

  int _topPriority = _basePriority;
  bool _isSolved = false;

  late EdgeLayout edgeLayout;
  late PuzzleBoardState _boardState;
  final Map<int, PuzzlePieceComponent> _pieces = {};

  int get totalPieces => rows * cols;
  int get solvedCount =>
      _boardState.pieces.where((p) => p.isSolved(rows, cols)).length;

  bool get canUndo => undoManager.canUndo;
  bool get canRedo => undoManager.canRedo;

  @override
  Color backgroundColor() => const Color(0x00000000);

  @override
  Future<void> onLoad() async {
    // 1. Compute Bottom Tray Dimensions
    final targetTrayH = min(size.y * 0.28, max(size.y * 0.22, 110.0));
    traySize = Vector2(size.x - 24.0, targetTrayH);
    trayPosition = Vector2(12.0, size.y - targetTrayH - 12.0);

    // 2. Compute Board Dimensions inside upper workspace
    final boardAreaHeight = trayPosition.y - 16.0;
    final boardAreaWidth = size.x - 24.0;
    final imageAspect = image.width / image.height;

    var bW = boardAreaWidth * 0.88;
    var bH = bW / imageAspect;
    if (bH > boardAreaHeight * 0.88) {
      bH = boardAreaHeight * 0.88;
      bW = bH * imageAspect;
    }

    boardSize = Vector2(bW, bH);
    boardTopLeft = Vector2(
      (size.x - boardSize.x) / 2,
      max(8.0, (boardAreaHeight - boardSize.y) / 2),
    );
    pieceSize = Vector2(bW / cols, bH / rows);

    // 3. Draw Board Background Frame
    add(
      RectangleComponent(
        position: boardTopLeft.clone(),
        size: boardSize.clone(),
        paint: Paint()..color = const Color(0x1A000000),
        priority: 0,
      ),
    );

    add(
      RectangleComponent(
        position: boardTopLeft.clone(),
        size: boardSize.clone(),
        paint: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = const Color(0x66FFFFFF),
        priority: 1,
      ),
    );

    // 4. Draw Scrollable Bottom Tray Component
    add(
      TrayBackgroundComponent(
        position: trayPosition.clone(),
        size: traySize.clone(),
      ),
    );

    // 5. Initialize Edge Layout & Domain State
    edgeLayout = EdgeLayout(rows: rows, cols: cols, seed: seed);
    _boardState = PuzzleEngine.createInitialState(
      rows: rows,
      cols: cols,
      seed: seed,
      rotationEnabled: rotationEnabled,
    );

    // 6. Compute Tray layout scaling and spacing
    _trayPieceScale = min(1.0, (traySize.y - 28.0) / pieceSize.y);
    _trayPieceWidth = pieceSize.x * _trayPieceScale;
    _traySpacing = 16.0;

    final srcPieceW = image.width / cols;
    final srcPieceH = image.height / rows;
    final initialPieces = <PieceState>[];

    // 7. Generate Piece Shapes and arrange inside Bottom Tray
    var trayIndex = 0;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final id = r * cols + c;
        final edges = edgeLayout.edgesFor(r, c);
        final shape = PieceShape(
          edges: edges,
          width: pieceSize.x,
          height: pieceSize.y,
        );

        final srcRect = shape.srcRect(
          row: r,
          col: c,
          srcWidthPerCol: srcPieceW,
          srcHeightPerRow: srcPieceH,
        );

        final pPos = _getTrayPositionForIndex(trayIndex);
        final normOut = [0.0, 0.0];
        _screenToNormalized(pPos, normOut);

        final pState = PieceState(
          id: id,
          r: r,
          c: c,
          nx: normOut[0],
          ny: normOut[1],
          clusterId: id,
          rot: 0,
        );
        initialPieces.add(pState);

        final component = PuzzlePieceComponent(
          id: id,
          r: r,
          c: c,
          shape: shape,
          image: image,
          srcRect: srcRect,
          initialPosition: pPos,
          baseSize: pieceSize.clone(),
        )
          ..isInTray = true
          ..scale = Vector2.all(_trayPieceScale)
          ..clusterId = pState.clusterId
          ..rot = pState.rot
          ..priority = _basePriority;

        _pieces[id] = component;
        add(component);
        trayIndex++;
      }
    }

    _boardState = _boardState.copyWith(pieces: initialPieces);
    undoManager.record(_boardState);
  }

  /// Computes the exact screen coordinate for the N-th piece in the bottom tray.
  Vector2 _getTrayPositionForIndex(int index) {
    final startX = trayPosition.x + 20.0 + _trayScrollX;
    final px = startX + index * (_trayPieceWidth + _traySpacing);
    final py = trayPosition.y + (traySize.y - pieceSize.y * _trayPieceScale) / 2;
    return Vector2(px, py);
  }

  /// Scrolls the bottom tray horizontally.
  void scrollTray(double deltaX) {
    final trayPieces = _pieces.values.where((p) => p.isInTray).toList();
    if (trayPieces.isEmpty) return;

    final contentWidth = trayPieces.length * (_trayPieceWidth + _traySpacing) + 40.0;
    final minScroll = min(0.0, traySize.x - contentWidth);
    const maxScroll = 0.0;

    _trayScrollX = (_trayScrollX + deltaX).clamp(minScroll, maxScroll);
    _realignTrayPieces(animate: false);
  }

  /// Re-arranges all pieces currently parked in the tray.
  void _realignTrayPieces({bool animate = true}) {
    var idx = 0;
    for (final p in _pieces.values) {
      if (p.isInTray) {
        final targetPos = _getTrayPositionForIndex(idx);
        p.animateScaleTo(Vector2.all(_trayPieceScale));
        if (animate) {
          p.animateTo(targetPos, duration: 0.2);
        } else {
          p.position.setFrom(targetPos);
        }
        idx++;
      }
    }
  }

  Vector2 _normalizedToScreen(double nx, double ny) {
    return boardTopLeft + Vector2(nx * boardSize.x, ny * boardSize.y);
  }

  void _screenToNormalized(Vector2 screenPos, List<double> out) {
    out[0] = (screenPos.x - boardTopLeft.x) / boardSize.x;
    out[1] = (screenPos.y - boardTopLeft.y) / boardSize.y;
  }

  /// Called when user begins dragging a piece.
  void handlePieceDragStart(PuzzlePieceComponent piece) {
    _topPriority += 2;

    // If piece was docked in tray, extract it to regular board workspace
    for (final p in _pieces.values) {
      if (p.clusterId == piece.clusterId) {
        p.priority = _topPriority;
        if (p.isInTray) {
          p.isInTray = false;
          p.animateScaleTo(Vector2.all(1.0), duration: 0.15);
        }
      }
    }

    // Rearrange remaining pieces in tray
    _realignTrayPieces(animate: true);
  }

  /// Called during drag movement. Moves all pieces in the cluster simultaneously.
  void handlePieceDragUpdate(PuzzlePieceComponent piece, Vector2 delta) {
    for (final p in _pieces.values) {
      if (p.clusterId == piece.clusterId) {
        p.position += delta;
      }
    }
  }

  /// Called when user releases drag. Executes snap resolution & cluster merge.
  void handlePieceDragEnd(PuzzlePieceComponent piece) {
    // Check if user dropped piece back onto tray area
    final inTrayArea = piece.position.y >= trayPosition.y - pieceSize.y * 0.3;
    final clusterPieces = _pieces.values.where((p) => p.clusterId == piece.clusterId).toList();

    // 1. Sync screen coordinates to domain PieceState list
    final out = [0.0, 0.0];
    final updatedPieces = _boardState.pieces.map((p) {
      final comp = _pieces[p.id]!;
      _screenToNormalized(comp.position, out);
      return p.copyWith(
        nx: out[0],
        ny: out[1],
        clusterId: comp.clusterId,
        rot: comp.rot,
      );
    }).toList();

    _boardState = _boardState.copyWith(pieces: updatedPieces);

    // 2. Run pure engine snap algorithm
    final result = PuzzleEngine.resolveSnap(
      state: _boardState,
      draggedPieceId: piece.id,
    );

    if (result.didSnap || result.didMerge) {
      _boardState = result.state;
      undoManager.record(_boardState);

      // Animate snapped pieces into exact pixel alignment
      for (final affectedId in result.affectedPieceIds) {
        final statePiece = _boardState.pieceById(affectedId);
        final comp = _pieces[affectedId]!;
        comp.isInTray = false;
        comp.scale.setFrom(Vector2.all(1.0));
        comp.clusterId = statePiece.clusterId;
        comp.rot = statePiece.rot;
        final targetScreenPos =
            _normalizedToScreen(statePiece.nx, statePiece.ny);
        comp.animateTo(targetScreenPos);
      }

      onPieceSnapped?.call();
      onProgressChanged?.call(solvedCount);

      if (result.isCompleted && !_isSolved) {
        _isSolved = true;
        // Hide piece borders for seamless celebration view
        for (final p in _pieces.values) {
          p.hideBorders = true;
        }
        onSolved();
      }
    } else if (inTrayArea && clusterPieces.length == 1) {
      // Return single unlinked piece back into tray
      piece.isInTray = true;
      _realignTrayPieces(animate: true);
    }
  }

  /// Restores previous snapshot from undo history.
  void undo() {
    final prev = undoManager.undo(_boardState);
    if (prev != null) {
      _applyBoardState(prev);
    }
  }

  /// Restores next snapshot from redo history.
  void redo() {
    final next = undoManager.redo(_boardState);
    if (next != null) {
      _applyBoardState(next);
    }
  }

  void _applyBoardState(PuzzleBoardState newState) {
    _boardState = newState;
    for (final p in newState.pieces) {
      final comp = _pieces[p.id]!;
      comp.clusterId = p.clusterId;
      comp.rot = p.rot;
      final targetScreenPos = _normalizedToScreen(p.nx, p.ny);
      comp.animateTo(targetScreenPos);
    }
    onProgressChanged?.call(solvedCount);
  }

  /// Automatically snaps one unsolved piece into place.
  void hint() {
    final hint = PuzzleEngine.hintFor(_boardState);

    // Move to target
    final updated = _boardState.pieces.map((p) {
      if (p.id == hint.pieceId) {
        return p.copyWith(
          nx: hint.targetNx,
          ny: hint.targetNy,
          rot: 0,
        );
      }
      return p;
    }).toList();

    _boardState = _boardState.copyWith(
      pieces: updated,
      hintsUsed: _boardState.hintsUsed + 1,
    );

    // Re-resolve snap for full cluster integration
    final result = PuzzleEngine.resolveSnap(
      state: _boardState,
      draggedPieceId: hint.pieceId,
    );

    _boardState = result.state;
    undoManager.record(_boardState);

    for (final p in _boardState.pieces) {
      final c = _pieces[p.id]!;
      c.isInTray = false;
      c.scale.setFrom(Vector2.all(1.0));
      c.clusterId = p.clusterId;
      c.rot = p.rot;
      c.animateTo(_normalizedToScreen(p.nx, p.ny), duration: 0.25);
    }

    _realignTrayPieces(animate: true);

    onPieceSnapped?.call();
    onProgressChanged?.call(solvedCount);

    if (result.isCompleted && !_isSolved) {
      _isSolved = true;
      for (final p in _pieces.values) {
        p.hideBorders = true;
      }
      onSolved();
    }
  }
}
