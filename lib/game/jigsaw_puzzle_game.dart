import 'dart:convert';
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

/// Tray background component that renders a sleek container for unplaced pieces.
class TrayBackgroundComponent extends PositionComponent
    with DragCallbacks, HasGameReference<JigsawPuzzleGame> {
  TrayBackgroundComponent({
    required Vector2 position,
    required Vector2 size,
  }) : super(position: position, size: size, priority: 2);

  static final Paint _bgPaint = Paint()
    ..color = const Color(0x66000000)
    ..style = PaintingStyle.fill;

  static final Paint _borderPaint = Paint()
    ..color = const Color(0x33FFFFFF)
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

/// Flame game engine handling jigsaw puzzle canvas, multi-modal scrollable tray,
/// smart aspect ratio adaptation, 3D piece rendering, cluster drag-and-drop, and undo/redo.
class JigsawPuzzleGame extends FlameGame with ScrollDetector, PanDetector {
  JigsawPuzzleGame({
    required this.image,
    required this.rows,
    required this.cols,
    int? seed,
    this.rotationEnabled = false,
    this.initialSnapshotJson,
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
  final String? initialSnapshotJson;
  final VoidCallback onSolved;
  final VoidCallback? onPieceSnapped;
  final ValueChanged<int>? onProgressChanged;

  final UndoManager undoManager;

  static const int _basePriority = 10;
  static const double targetTrayPieceBaseSize = 64.0; // Standard touch-friendly base size
  static const double _topToolbarHeight = 52.0;
  static const double _sideMargin = 8.0;
  static const double _bottomTrayMargin = 8.0;

  late Vector2 boardTopLeft;
  late Vector2 boardSize;
  late Vector2 pieceSize;

  double _zoom = 1.0;
  double get zoom => _zoom;
  double _maxZoom = 3.0;
  double get maxZoom => _maxZoom;
  final Vector2 _panOffset = Vector2.zero();
  Vector2 get panOffset => _panOffset;

  late RectangleComponent _boardBgRect;
  late RectangleComponent _boardOutlineRect;

  Vector2 trayPosition = Vector2.zero();
  Vector2 traySize = Vector2.zero();
  double _trayScrollX = 0.0;
  double _trayPieceScale = 1.0;
  double get trayPieceScale => _trayPieceScale;
  double _trayPieceWidth = 64.0;
  double _trayPieceHeight = 64.0;
  double _traySpacing = 16.0;

  int _topPriority = _basePriority;
  bool _isSolved = false;
  bool get isSolved => _isSolved;
  bool _borderFilterActive = false;

  late EdgeLayout edgeLayout;
  late PuzzleBoardState _boardState;
  final Map<int, PuzzlePieceComponent> _pieces = {};

  int get totalPieces => rows * cols;
  int get solvedCount =>
      _boardState.pieces.where((p) => p.isSolved(rows, cols)).length;

  bool get canUndo => undoManager.canUndo;
  bool get canRedo => undoManager.canRedo;
  bool get isBorderFilterActive => _borderFilterActive;

  @override
  Color backgroundColor() => const Color(0x00000000);

  @override
  Future<void> onLoad() async {
    _computeLayout();

    // 1. Draw Board Background Frame
    _boardBgRect = RectangleComponent(
      position: boardTopLeft.clone(),
      size: boardSize.clone(),
      paint: Paint()..color = const Color(0x1A000000),
      priority: 0,
    );
    add(_boardBgRect);

    _boardOutlineRect = RectangleComponent(
      position: boardTopLeft.clone(),
      size: boardSize.clone(),
      paint: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = const Color(0x66FFFFFF),
      priority: 1,
    );
    add(_boardOutlineRect);

    // 2. Draw Scrollable Bottom Tray Component
    add(
      TrayBackgroundComponent(
        position: trayPosition.clone(),
        size: traySize.clone(),
      ),
    );

    // 3. Initialize Edge Layout & Domain State
    edgeLayout = EdgeLayout(rows: rows, cols: cols, seed: seed);
    _boardState = PuzzleEngine.createInitialState(
      rows: rows,
      cols: cols,
      seed: seed,
      rotationEnabled: rotationEnabled,
    );

    final srcPieceW = image.width / cols;
    final srcPieceH = image.height / rows;
    final initialPieces = <PieceState>[];

    // 4. Generate Piece Shapes and arrange inside Bottom Tray with Normalized Size
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

    // 5. Restore from snapshot if available
    if (initialSnapshotJson != null && initialSnapshotJson!.isNotEmpty) {
      try {
        final json = jsonDecode(initialSnapshotJson!) as Map<String, dynamic>;
        final restored = PuzzleBoardState.fromJson(json);
        _applyBoardState(restored);
      } catch (_) {}
    }

    undoManager.record(_boardState);
  }

  /// Computes smart board maximizing layout and normalized tray metrics.
  void _computeLayout() {
    // 1. Bottom Tray Height (comfortably houses ~64px touch piece)
    final targetTrayH = min(size.y * 0.28, max(size.y * 0.20, 100.0));
    traySize = Vector2(size.x - _sideMargin * 2, targetTrayH);
    trayPosition =
        Vector2(_sideMargin, size.y - targetTrayH - _bottomTrayMargin);

    // 2. Smart Board Layout in remaining upper workspace (maximize available area, minimize side margins)
    final availableBoardW = max(100.0, size.x - _sideMargin * 2);
    final availableBoardH =
        max(100.0, trayPosition.y - _topToolbarHeight - 8.0);
    final imageAspect = image.width / image.height;
    final areaAspect = availableBoardW / availableBoardH;

    double bW, bH;
    if (imageAspect >= areaAspect) {
      // Image is wider than available space: width is 100% of available width
      bW = availableBoardW;
      bH = bW / imageAspect;
    } else {
      // Image is taller / squarish: height is 100% of available height
      bH = availableBoardH;
      bW = bH * imageAspect;
    }

    boardSize = Vector2(bW, bH);
    boardTopLeft = Vector2(
      _sideMargin + (availableBoardW - bW) / 2,
      _topToolbarHeight + (availableBoardH - bH) / 2,
    );
    pieceSize = Vector2(bW / cols, bH / rows);

    // Max zoom allows up to 1:1 original image resolution
    _maxZoom = max(3.0, (image.width / bW).toDouble());

    // 3. Normalized Tray Scaling (Target max side = 64px, preserving piece aspect ratio)
    final maxPieceSide = max(pieceSize.x, pieceSize.y);
    _trayPieceScale = targetTrayPieceBaseSize / maxPieceSide;
    _trayPieceWidth = pieceSize.x * _trayPieceScale;
    _trayPieceHeight = pieceSize.y * _trayPieceScale;
    _traySpacing = 14.0;
  }

  /// Computes the exact screen coordinate for the N-th piece in the bottom tray.
  Vector2 _getTrayPositionForIndex(int index) {
    final startX = trayPosition.x + 18.0 + _trayScrollX;
    final px = startX + index * (_trayPieceWidth + _traySpacing);
    final py = trayPosition.y + (traySize.y - _trayPieceHeight) / 2;
    return Vector2(px, py);
  }

  @override
  void onScroll(PointerScrollInfo info) {
    super.onScroll(info);
    final mousePos = info.eventPosition.global;
    if (mousePos.y >= trayPosition.y && mousePos.y <= trayPosition.y + traySize.y) {
      final delta = info.scrollDelta.global.y != 0
          ? -info.scrollDelta.global.y
          : -info.scrollDelta.global.x;
      scrollTray(delta * 0.8);
    }
  }

  @override
  void onPanUpdate(DragUpdateInfo info) {
    super.onPanUpdate(info);
    final pos = info.eventPosition.global;
    if (pos.y >= trayPosition.y && pos.y <= trayPosition.y + traySize.y) {
      final isPieceDragging = _pieces.values.any((p) => p.isDragging);
      if (!isPieceDragging) {
        scrollTray(info.delta.global.x);
      }
    }
  }

  /// Scrolls the bottom tray horizontally.
  void scrollTray(double deltaX) {
    final trayPieces = _pieces.values.where((p) => p.isInTray).toList();
    if (trayPieces.isEmpty) return;

    final contentWidth = trayPieces.length * (_trayPieceWidth + _traySpacing) + 36.0;
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
    final effectiveTopLeft = boardTopLeft + _panOffset;
    final effectiveBoardSize = boardSize * _zoom;
    return effectiveTopLeft +
        Vector2(nx * effectiveBoardSize.x, ny * effectiveBoardSize.y);
  }

  void _screenToNormalized(Vector2 screenPos, List<double> out) {
    final effectiveTopLeft = boardTopLeft + _panOffset;
    final effectiveBoardSize = boardSize * _zoom;
    out[0] = (screenPos.x - effectiveTopLeft.x) / effectiveBoardSize.x;
    out[1] = (screenPos.y - effectiveTopLeft.y) / effectiveBoardSize.y;
  }

  /// Clamps panOffset so that the board cannot be panned too far out of view.
  void _clampPanOffset() {
    if (_zoom <= 1.0) {
      _panOffset.setZero();
      return;
    }
    final maxExcessW = (boardSize.x * (_zoom - 1.0)) / 2 + 80.0;
    final maxExcessH = (boardSize.y * (_zoom - 1.0)) / 2 + 80.0;
    _panOffset.x = _panOffset.x.clamp(-maxExcessW, maxExcessW);
    _panOffset.y = _panOffset.y.clamp(-maxExcessH, maxExcessH);
  }

  /// Zooms in or out centered at the specified screen [focalPoint].
  void zoomAt(Vector2 focalPoint, double deltaScale) {
    final oldZoom = _zoom;
    final newZoom = (oldZoom + deltaScale).clamp(1.0, _maxZoom);
    if ((newZoom - oldZoom).abs() < 0.0001) return;

    final scaleRatio = newZoom / oldZoom;
    final curTopLeft = boardTopLeft + _panOffset;
    final newTopLeft = focalPoint - (focalPoint - curTopLeft) * scaleRatio;

    _zoom = newZoom;
    _panOffset.setFrom(newTopLeft - boardTopLeft);
    _clampPanOffset();

    _updateBoardTransform();
  }

  /// Sets zoom and pan directly (e.g. from pinch-to-zoom).
  void setZoomAndPan(double newZoom, Vector2 newPan) {
    _zoom = newZoom.clamp(1.0, _maxZoom);
    _panOffset.setFrom(newPan);
    _clampPanOffset();
    _updateBoardTransform();
  }

  /// Pans the board by [delta].
  void panBy(Vector2 delta) {
    if (_zoom <= 1.0) return;
    _panOffset.add(delta);
    _clampPanOffset();
    _updateBoardTransform();
  }

  /// Resets zoom to 1.0 and centers the board.
  void resetZoom() {
    _zoom = 1.0;
    _panOffset.setZero();
    _updateBoardTransform();
  }

  /// Updates board background rects and pieces on board after zoom / pan.
  void _updateBoardTransform() {
    final effectiveTopLeft = boardTopLeft + _panOffset;
    final effectiveBoardSize = boardSize * _zoom;

    _boardBgRect.position.setFrom(effectiveTopLeft);
    _boardBgRect.size.setFrom(effectiveBoardSize);

    _boardOutlineRect.position.setFrom(effectiveTopLeft);
    _boardOutlineRect.size.setFrom(effectiveBoardSize);

    // Update positions and scale of all pieces currently on the board
    for (final pState in _boardState.pieces) {
      final comp = _pieces[pState.id];
      if (comp == null || comp.isInTray || comp.isDragging) continue;

      final targetPos = _normalizedToScreen(pState.nx, pState.ny);
      comp.position.setFrom(targetPos);
      comp.scale.setAll(_zoom);
    }
  }

  /// Called when user begins dragging a piece.
  void handlePieceDragStart(PuzzlePieceComponent piece) {
    _topPriority += 2;

    for (final p in _pieces.values) {
      if (p.clusterId == piece.clusterId) {
        p.priority = _topPriority;
        if (p.isInTray) {
          p.isInTray = false;
        }
      }
    }

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
    final inTrayArea = piece.position.y >= trayPosition.y - pieceSize.y * 0.25;
    final clusterPieces =
        _pieces.values.where((p) => p.clusterId == piece.clusterId).toList();

    final out = [0.0, 0.0];
    final updatedPieces = _boardState.pieces.map((p) {
      final comp = _pieces[p.id];
      if (comp == null) return p; // 防御：跳过 _pieces 中不存在的碎片
      _screenToNormalized(comp.position, out);
      return p.copyWith(
        nx: out[0],
        ny: out[1],
        clusterId: comp.clusterId,
        rot: comp.rot,
      );
    }).toList();

    _boardState = _boardState.copyWith(pieces: updatedPieces);

    final result = PuzzleEngine.resolveSnap(
      state: _boardState,
      draggedPieceId: piece.id,
    );

    if (result.didSnap || result.didMerge) {
      _boardState = result.state;
      undoManager.record(_boardState);

      for (final affectedId in result.affectedPieceIds) {
        final statePiece = _boardState.pieceById(affectedId);
        final comp = _pieces[affectedId]!;
        comp.isInTray = false;
        comp.scale.setFrom(Vector2.all(_zoom));
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
        for (final p in _pieces.values) {
          p.hideBorders = true;
        }
        onSolved();
      }
    } else if (inTrayArea && clusterPieces.length == 1) {
      // Returned back into tray -> dock smoothly
      piece.isInTray = true;
      piece.animateScaleTo(Vector2.all(_trayPieceScale), duration: 0.15);
      _realignTrayPieces(animate: true);
    } else {
      // Kept on board -> ensure _zoom scale
      for (final p in clusterPieces) {
        p.isInTray = false;
        p.animateScaleTo(Vector2.all(_zoom), duration: 0.15);
      }
      _realignTrayPieces(animate: true);
    }
  }

  /// Toggles border pieces filter (highlights/top-prioritizes border pieces).
  void toggleBorderFilter() {
    _borderFilterActive = !_borderFilterActive;
    for (final p in _pieces.values) {
      final isBorder = edgeLayout.edgesFor(p.r, p.c).isBorder;
      p.isHighlight = _borderFilterActive && isBorder;
    }
  }

  /// Organizes all unlinked/unplaced floating pieces cleanly back into the tray.
  void organizeTray() {
    for (final p in _pieces.values) {
      // If piece is not solved and is single in cluster, park back into tray
      final clusterSize = _pieces.values.where((o) => o.clusterId == p.clusterId).length;
      final statePiece = _boardState.pieceById(p.id);
      if (clusterSize == 1 && !statePiece.isSolved(rows, cols)) {
        p.isInTray = true;
        p.animateScaleTo(Vector2.all(_trayPieceScale), duration: 0.2);
      }
    }
    _trayScrollX = 0.0;
    _realignTrayPieces(animate: true);
  }

  /// Serializes current board state into Snapshot JSON string.
  String exportSnapshotJson() {
    final out = [0.0, 0.0];
    final updated = _boardState.pieces.map((p) {
      final comp = _pieces[p.id];
      if (comp != null) {
        _screenToNormalized(comp.position, out);
        return p.copyWith(nx: out[0], ny: out[1], clusterId: comp.clusterId, rot: comp.rot);
      }
      return p;
    }).toList();
    return jsonEncode(_boardState.copyWith(pieces: updated).toJson());
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
    // 快照尺寸与当前拼图不一致时忽略，避免 _boardState 与 _pieces 失步导致拖拽崩溃
    if (newState.rows != rows ||
        newState.cols != cols ||
        newState.pieces.length != _pieces.length) {
      return;
    }
    _boardState = newState;
    for (final p in newState.pieces) {
      final comp = _pieces[p.id]!;
      comp.clusterId = p.clusterId;
      comp.rot = p.rot;
      final targetScreenPos = _normalizedToScreen(p.nx, p.ny);
      comp.animateTo(targetScreenPos);
      if (!comp.isInTray) {
        comp.scale.setAll(_zoom);
      }
    }
    onProgressChanged?.call(solvedCount);
  }

  /// Automatically snaps one unsolved piece into place.
  void hint() {
    final hint = PuzzleEngine.hintFor(_boardState);
    final targetPieceId = hint.pieceId;
    final targetComp = _pieces[targetPieceId];
    if (targetComp == null) return;

    final updated = _boardState.pieces.map((p) {
      if (p.id == targetPieceId) {
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

    final result = PuzzleEngine.resolveSnap(
      state: _boardState,
      draggedPieceId: targetPieceId,
    );

    _boardState = result.state;
    undoManager.record(_boardState);

    // ONLY animate the hinted piece and its directly affected cluster members
    final affectedIds = result.affectedPieceIds.isNotEmpty
        ? result.affectedPieceIds
        : [targetPieceId];

    _topPriority += 2;
    for (final id in affectedIds) {
      final statePiece = _boardState.pieceById(id);
      final c = _pieces[id];
      if (c == null) continue; // 防御：跳过 _pieces 中不存在的碎片
      c.priority = _topPriority;
      c.isInTray = false;
      c.scale.setFrom(Vector2.all(_zoom));
      c.clusterId = statePiece.clusterId;
      c.rot = statePiece.rot;
      c.animateTo(_normalizedToScreen(statePiece.nx, statePiece.ny), duration: 0.25);
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
