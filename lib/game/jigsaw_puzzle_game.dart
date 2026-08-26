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
import '../logic/rendering/linen_texture_manager.dart';
import 'puzzle_piece_component.dart';

typedef PuzzleImage = ui.Image;

/// Decodes raw image bytes into a [PuzzleImage] usable by Flame.
Future<PuzzleImage> decodeFlameImage(Uint8List bytes) =>
    decodeImageFromList(bytes);

/// Board ghost watermark component rendering semi-transparent reference image directly on the board.
class BoardGhostComponent extends PositionComponent {
  BoardGhostComponent({
    required this.image,
    required Vector2 position,
    required Vector2 size,
    this.opacity = 0.0,
  }) : super(position: position, size: size, priority: 0);

  final PuzzleImage image;
  double opacity;

  @override
  void render(ui.Canvas canvas) {
    if (opacity <= 0.001) return;
    final paint = Paint()
      ..color = Color.fromRGBO(255, 255, 255, opacity)
      ..filterQuality = ui.FilterQuality.medium
      ..isAntiAlias = true;

    final srcRect = ui.Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final dstRect = size.toRect();
    canvas.drawImageRect(image, srcRect, dstRect, paint);
  }
}

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
    if (game.holdingPiece == null) {
      game.scrollTray(event.localDelta.x);
    }
  }
}

/// Flame game engine handling jigsaw puzzle canvas, multi-modal scrollable tray,
/// smart aspect ratio adaptation, 3D piece rendering, cluster drag-and-drop, and undo/redo.
class JigsawPuzzleGame extends FlameGame
    with ScrollDetector, PanDetector, MouseMovementDetector, TapCallbacks {
  JigsawPuzzleGame({
    required this.image,
    required this.rows,
    required this.cols,
    int? seed,
    this.rotationEnabled = false,
    this.scatterMode = 'tray',
    this.initialSnapshotJson,
    this.initialGhostOpacity = 0.0,
    required this.onSolved,
    this.onPieceSnapped,
    this.onProgressChanged,
    this.onStateUpdated,
  })  : seed = seed ?? (DateTime.now().millisecondsSinceEpoch % 1000000),
        _boardGhostOpacity = initialGhostOpacity,
        undoManager = UndoManager();

  final PuzzleImage image;
  final int rows;
  final int cols;
  final int seed;
  final bool rotationEnabled;
  final String scatterMode;
  final String? initialSnapshotJson;
  final double initialGhostOpacity;
  final VoidCallback onSolved;
  final VoidCallback? onPieceSnapped;
  final ValueChanged<int>? onProgressChanged;
  final VoidCallback? onStateUpdated;

  final UndoManager undoManager;

  // ---------------------------------------------------------------------------
  // 渲染与交互层级优先级 (Priority Hierarchy)
  // ---------------------------------------------------------------------------
  static const int _solvedPiecePriority = 5;       // 已归位正确碎片（锁定底层，不遮挡任何浮动碎片）
  static const int _trayPiecePriority = 10;        // 托盘中的待拼碎片
  static const int _boardUnsolvedPriority = 20;    // 散落在棋盘上的未归位碎片
  static const int _activeDragBasePriority = 1000; // 正在拖拽或光标吸附抓取的碎片集群（绝对顶层）

  static const double targetTrayPieceBaseSize = 64.0; // Standard touch-friendly base size
  static const double _topToolbarHeight = 8.0;
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
  late BoardGhostComponent _boardGhostComp;
  late RectangleComponent _boardOutlineRect;
  TrayBackgroundComponent? _trayBgComp;

  Vector2 trayPosition = Vector2.zero();
  Vector2 traySize = Vector2.zero();
  double _trayScrollX = 0.0;
  double _trayPieceScale = 1.0;
  double get trayPieceScale => _trayPieceScale;
  double _trayPieceWidth = 64.0;
  double _trayPieceHeight = 64.0;
  double _traySpacing = 16.0;

  int _topPriority = _activeDragBasePriority;
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;
  bool _isSolved = false;
  bool get isSolved => _isSolved;
  bool _borderFilterActive = false;
  bool get isBorderFilterActive => _borderFilterActive;
  double _boardGhostOpacity = 0.0;
  double get boardGhostOpacity => _boardGhostOpacity;
  bool isPinching = false;

  late EdgeLayout edgeLayout;
  late PuzzleBoardState _boardState;
  PuzzleBoardState get boardState => _boardState;
  final Map<int, PuzzlePieceComponent> _pieces = {};

  /// Shuffled sequence of piece ids defining their left-to-right order in the tray.
  List<int> _trayOrder = [];

  int get totalPieces => rows * cols;
  int get solvedCount =>
      _boardState.pieces.where((p) => p.isSolved(rows, cols)).length;
  int get remainingTrayPieces => _pieces.values.where((p) => p.isInTray).length;

  bool get canUndo => undoManager.canUndo;
  bool get canRedo => undoManager.canRedo;

  /// 是否处于桌面散落模式（宽屏/平板/桌面端开启散落且空间充足）
  bool get isTabletop =>
      scatterMode == 'tabletop' && (size.x > 450.0 || size.y > 450.0);

  /// 当前是否有任意碎片正在被按住拖拽或光标吸附抓取
  bool get isDraggingAnyPiece =>
      _holdingPiece != null || _pieces.values.any((p) => p.isDragging);

  @override
  Color backgroundColor() => const Color(0x00000000);

  @override
  Future<void> onLoad() async {
    await LinenTextureManager.ensureInitialized();
    _computeLayout();

    // 1. Draw Board Background Frame
    _boardBgRect = RectangleComponent(
      position: boardTopLeft.clone(),
      size: boardSize.clone(),
      paint: Paint()..color = const Color(0x1A000000),
      priority: 0,
    );
    add(_boardBgRect);

    // 1.5 Draw Ghost Reference Watermark Image
    _boardGhostComp = BoardGhostComponent(
      image: image,
      position: boardTopLeft.clone(),
      size: boardSize.clone(),
      opacity: _boardGhostOpacity,
    );
    add(_boardGhostComp);

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

    // 2. Draw Scrollable Bottom Tray Component (桌面散落模式下彻底隐藏托盘背景)
    if (!isTabletop) {
      _trayBgComp = TrayBackgroundComponent(
        position: trayPosition.clone(),
        size: traySize.clone(),
      );
      add(_trayBgComp!);
    }

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

    // 4. Generate Piece Shapes and arrange inside Bottom Tray with Normalized Size.
    //    Pieces are SHUFFLED so the tray order never matches the original image order.
    _trayOrder = List<int>.generate(totalPieces, (i) => i)..shuffle(Random(seed));
    var trayIndex = 0;
    for (final id in _trayOrder) {
      final r = id ~/ cols;
      final c = id % cols;
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

        final isTabletop = scatterMode == 'tabletop' && (size.x > 400.0 || size.y > 400.0);
        final pPos = isTabletop
            ? _getScatterPositionForIndex(trayIndex, totalPieces)
            : _getTrayPositionForIndex(trayIndex);
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
          ..isInTray = !isTabletop
          ..scale = Vector2.all(isTabletop ? _zoom : _trayPieceScale)
          ..clusterId = pState.clusterId
          ..rot = pState.rot
          ..priority = isTabletop ? _boardUnsolvedPriority : _trayPiecePriority;

        _pieces[id] = component;
        add(component);
        trayIndex++;
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

    _isInitialized = true;
    updatePiecesStateAndPriorities();
  }

  Vector2? _lastGameSize;

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    if (!_isInitialized) return;
    if (_lastGameSize != null && (_lastGameSize! - size).length < 0.5) return;
    _lastGameSize = size.clone();
    _computeLayout();
    _tabletopScatterSlots = null;
    _syncResizeTransform();
  }

  /// 当游戏视口大小变化（如 Windows 窗口拉伸/缩放）时，全量同步更新底板、托盘及所有碎片的物理尺寸与坐标
  void _syncResizeTransform() {
    // 窗口物理尺寸改变时，缩放与平移复位为基准尺寸
    _zoom = 1.0;
    _panOffset.setZero();

    // 1. 同步托盘背景组件
    if (!isTabletop) {
      if (_trayBgComp == null || _trayBgComp!.parent == null) {
        _trayBgComp = TrayBackgroundComponent(
          position: trayPosition.clone(),
          size: traySize.clone(),
        );
        add(_trayBgComp!);
      } else {
        _trayBgComp!.position.setFrom(trayPosition);
        _trayBgComp!.size.setFrom(traySize);
      }
    } else {
      _trayBgComp?.removeFromParent();
      _trayBgComp = null;
    }

    // 2. 同步棋盘底板、底图水印及外框
    _updateBoardTransform();

    // 3. 动态刷新所有碎片的几何贝塞尔轮廓与基础尺寸
    for (final comp in _pieces.values) {
      final edges = edgeLayout.edgesFor(comp.r, comp.c);
      comp.updateShapeAndSize(
        PieceShape(
          edges: edges,
          width: pieceSize.x,
          height: pieceSize.y,
        ),
        pieceSize,
      );

      if (comp.isDragging || comp == _holdingPiece) {
        // 若当前正在被鼠标吸附或拖拽，由 updateHoldingPiecePosition 在下一帧自动对准
        continue;
      }

      if (comp.isInTray) {
        comp.scale.setAll(_trayPieceScale);
      } else {
        comp.scale.setAll(_zoom);
        final pState = _boardState.pieceById(comp.id);
        comp.position.setFrom(_normalizedToScreen(pState.nx, pState.ny));
      }
    }

    // 4. 视口边界安全自适应与游离碎片/拼合集群防出界收拢 (Viewport Clamp & Cluster Pullback)
    // 当窗口缩小导致游离碎片或自由集群超出可视范围时，自动安全收拢在视野内，集群按包围盒整体平移
    final safeMinX = 8.0;
    final safeMaxX = max(safeMinX, size.x - pieceSize.x - 8.0);
    final safeMinY = 44.0;
    final safeMaxY = max(
      safeMinY,
      (isTabletop ? size.y : trayPosition.y) - pieceSize.y - 8.0,
    );

    final freeComponents = _pieces.values
        .where((p) =>
            !p.isInTray &&
            !p.isLocked &&
            p != _holdingPiece &&
            !p.isDragging)
        .toList();

    final clusterGroups = <int, List<PuzzlePieceComponent>>{};
    for (final comp in freeComponents) {
      clusterGroups.putIfAbsent(comp.clusterId, () => []).add(comp);
    }

    final outNorm = [0.0, 0.0];
    final updatedPiecesMap = <int, PieceState>{};

    for (final cluster in clusterGroups.values) {
      if (cluster.isEmpty) continue;

      if (cluster.length == 1) {
        // 单块游离碎片安全 Clamp
        final comp = cluster.first;
        final curX = comp.position.x;
        final curY = comp.position.y;
        final clampedX = curX.clamp(safeMinX, safeMaxX);
        final clampedY = curY.clamp(safeMinY, safeMaxY);

        if (clampedX != curX || clampedY != curY) {
          comp.position.setValues(clampedX, clampedY);
          _screenToNormalized(comp.position, outNorm);
          final pState = _boardState.pieceById(comp.id);
          updatedPiecesMap[comp.id] = pState.copyWith(
            nx: outNorm[0],
            ny: outNorm[1],
          );
        }
      } else {
        // 多块拼合自由集群：按外接包围盒整体原子平移（绝不拆散集群）
        double minCX = cluster.first.position.x;
        double maxCX = cluster.first.position.x + cluster.first.size.x;
        double minCY = cluster.first.position.y;
        double maxCY = cluster.first.position.y + cluster.first.size.y;

        for (final comp in cluster) {
          minCX = min(minCX, comp.position.x);
          maxCX = max(maxCX, comp.position.x + comp.size.x);
          minCY = min(minCY, comp.position.y);
          maxCY = max(maxCY, comp.position.y + comp.size.y);
        }

        double shiftX = 0.0;
        double shiftY = 0.0;

        if (minCX < safeMinX) {
          shiftX = safeMinX - minCX;
        } else if (maxCX > size.x - 8.0) {
          shiftX = (size.x - 8.0) - maxCX;
        }

        final topLimit = isTabletop ? size.y - 8.0 : trayPosition.y - 8.0;
        if (minCY < safeMinY) {
          shiftY = safeMinY - minCY;
        } else if (maxCY > topLimit) {
          shiftY = topLimit - maxCY;
        }

        if (shiftX != 0.0 || shiftY != 0.0) {
          for (final comp in cluster) {
            comp.position += Vector2(shiftX, shiftY);
            _screenToNormalized(comp.position, outNorm);
            final pState = _boardState.pieceById(comp.id);
            updatedPiecesMap[comp.id] = pState.copyWith(
              nx: outNorm[0],
              ny: outNorm[1],
            );
          }
        }
      }
    }

    if (updatedPiecesMap.isNotEmpty) {
      final newPieces = _boardState.pieces.map((p) {
        return updatedPiecesMap[p.id] ?? p;
      }).toList();
      _boardState = _boardState.copyWith(pieces: newPieces);
    }

    // 5. 刷新桌面散落槽位缓存（若是散落模式）
    if (isTabletop) {
      _tabletopScatterSlots = null;
    }

    // 6. 重排托盘碎片
    if (!isTabletop) {
      final trayPieces =
          _pieces.values.where((p) => p.isInTray && !p.isFilteredOut).toList();
      final contentWidth =
          trayPieces.length * (_trayPieceWidth + _traySpacing) + 36.0;
      final minScroll = min(0.0, traySize.x - contentWidth);
      _trayScrollX = _trayScrollX.clamp(minScroll, 0.0);
      _realignTrayPieces(animate: false);
    }

    updatePiecesStateAndPriorities();
  }

  /// Computes smart board maximizing layout and normalized tray metrics.
  void _computeLayout() {
    // 1. Bottom Tray Height (comfortably houses ~64px touch piece)
    final targetTrayH = min(size.y * 0.28, max(size.y * 0.20, 100.0));
    traySize = Vector2(size.x - _sideMargin * 2, targetTrayH);
    trayPosition =
        Vector2(_sideMargin, size.y - targetTrayH - _bottomTrayMargin);

    // 2. Smart Board Layout in remaining upper workspace (maximize available area, minimize side margins)
    final isTabletop = scatterMode == 'tabletop' && (size.x > 450.0 || size.y > 450.0);
    final availableBoardW = isTabletop
        ? max(100.0, (size.x - _sideMargin * 2) * 0.56)
        : max(100.0, size.x - _sideMargin * 2);
    final availableBoardH = isTabletop
        ? max(100.0, (size.y - _topToolbarHeight - 24.0) * 0.56)
        : max(100.0, trayPosition.y - _topToolbarHeight - 8.0);
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
    boardTopLeft = isTabletop
        ? Vector2(
            (size.x - bW) / 2,
            _topToolbarHeight + (size.y - _topToolbarHeight - bH) / 2,
          )
        : Vector2(
            _sideMargin + (availableBoardW - bW) / 2,
            _topToolbarHeight + (availableBoardH - bH) / 2,
          );
    pieceSize = Vector2(bW / cols, bH / rows);

    // 严格限制最大放大倍数不超过 300% (3.0x)
    _maxZoom = 3.0;

    // 3. Normalized Tray Scaling (Target max side = 64px, preserving piece aspect ratio)
    final maxPieceSide = max(pieceSize.x, pieceSize.y);
    _trayPieceScale = targetTrayPieceBaseSize / maxPieceSide;
    _trayPieceWidth = pieceSize.x * _trayPieceScale;
    _trayPieceHeight = pieceSize.y * _trayPieceScale;
    _traySpacing = 14.0;
  }

  List<Vector2>? _tabletopScatterSlots;

  /// Computes the exact screen coordinate for the N-th piece in the bottom tray.
  Vector2 _getTrayPositionForIndex(int index) {
    final startX = trayPosition.x + 18.0 + _trayScrollX;
    final px = startX + index * (_trayPieceWidth + _traySpacing);
    final py = trayPosition.y + (traySize.y - _trayPieceHeight) / 2;
    return Vector2(px, py);
  }

  /// 8 扇区全域开阔环形发散散落算法（Wide Perimeter Ring Scatter System）
  ///
  /// 【核心改进】：
  /// 1. 采用开阔步长（1.15 ~ 1.25 * pieceSize），确保碎片之间有良好间距，绝不互相堆叠拥挤；
  /// 2. 候选点覆盖全屏直到屏幕边缘与四角；
  /// 3. 将候选点按 8 个方位扇区归类，并在扇区内按离棋盘中心的距离从远到近排序（优先占领开阔的外围边缘与四角），
  ///    彻底消除围绕棋盘外框挤在一起的问题，让碎片开阔自然地铺满整张大桌面；
  /// 4. 8 扇区轮流交替分发（Round-Robin Interleaving），确保上下左右均匀发散；
  /// 5. 严格几何避让：棋盘中心保护区保持 100% 绝对留白。
  List<Vector2> _getTabletopScatterSlots(int total) {
    if (_tabletopScatterSlots != null && _tabletopScatterSlots!.length >= total) {
      return _tabletopScatterSlots!;
    }

    final pad = 16.0;
    final safeLeft = boardTopLeft.x - pad;
    final safeTop = boardTopLeft.y - pad;
    final safeRight = boardTopLeft.x + boardSize.x + pad;
    final safeBottom = boardTopLeft.y + boardSize.y + pad;

    // 开阔步长 (1.15 ~ 1.25)，保证碎片充分展开分散
    final stepX = max(32.0, pieceSize.x * 1.18);
    final stepY = max(32.0, pieceSize.y * 1.18);

    final cols = max(1, ((size.x - 16.0) / stepX).floor());
    final rows = max(1, ((size.y - 60.0) / stepY).floor());

    final topMargin = 48.0;
    final sideMargin = (size.x - cols * stepX) / 2;

    final centerX = boardTopLeft.x + boardSize.x / 2;
    final centerY = boardTopLeft.y + boardSize.y / 2;

    final candidates = <({double x, double y, double angle, double dist})>[];

    for (var r = 0; r < rows; r++) {
      final py = topMargin + r * stepY;
      for (var c = 0; c < cols; c++) {
        final px = sideMargin + c * stepX;

        // 碰撞判定：严格避让中央棋盘安全区域
        final isOverlap = !(px + pieceSize.x <= safeLeft ||
            px >= safeRight ||
            py + pieceSize.y <= safeTop ||
            py >= safeBottom);

        if (!isOverlap &&
            px >= 8.0 &&
            px + pieceSize.x <= size.x - 8.0 &&
            py >= 44.0 &&
            py + pieceSize.y <= size.y - 8.0) {
          final pCenterX = px + pieceSize.x / 2;
          final pCenterY = py + pieceSize.y / 2;
          final angle = atan2(pCenterY - centerY, pCenterX - centerX);
          final dist = Point(pCenterX, pCenterY).distanceTo(Point(centerX, centerY));
          candidates.add((x: px, y: py, angle: angle, dist: dist));
        }
      }
    }

    if (candidates.isEmpty) {
      return List.generate(total, (i) => _getTrayPositionForIndex(i));
    }

    // 按围绕棋盘中心的 8 个方位扇区归类
    final sectors = List.generate(8, (_) => <({double x, double y, double angle, double dist})>[]);
    for (final cand in candidates) {
      final normA = (cand.angle + pi) / (2 * pi); // 0.0 ~ 1.0
      final secIdx = (normA * 8).floor() % 8;
      sectors[secIdx].add(cand);
    }

    // 关键优化：每个扇区内部按离棋盘中心的距离从远到近排序，优先占据开阔的外围边缘与角落！
    for (final s in sectors) {
      s.sort((a, b) => b.dist.compareTo(a.dist));
    }

    final slots = <Vector2>[];
    final rng = Random(seed);
    var secI = 0;

    while (slots.length < total) {
      var found = false;
      for (var offset = 0; offset < 8; offset++) {
        final currSector = sectors[(secI + offset) % 8];
        if (currSector.isNotEmpty) {
          final item = currSector.removeAt(0);
          // 真实微扰动（±10% 自然随机抖动）
          final jx = (rng.nextDouble() - 0.5) * pieceSize.x * 0.16;
          final jy = (rng.nextDouble() - 0.5) * pieceSize.y * 0.16;
          slots.add(Vector2(
            (item.x + jx).clamp(8.0, size.x - pieceSize.x - 8.0),
            (item.y + jy).clamp(44.0, size.y - pieceSize.y - 8.0),
          ));
          secI = (secI + offset + 1) % 8;
          found = true;
          break;
        }
      }
      if (!found) break;
    }

    // 若依然不足，回退用托盘或现有位置补齐
    while (slots.length < total) {
      slots.add(_getTrayPositionForIndex(slots.length));
    }

    _tabletopScatterSlots = slots;
    return slots;
  }

  /// 获取指定碎片在桌面发散模式下的坐标
  Vector2 _getScatterPositionForIndex(int index, int total) {
    if (scatterMode != 'tabletop') {
      return _getTrayPositionForIndex(index);
    }
    final slots = _getTabletopScatterSlots(total);
    return slots[index % slots.length];
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

  /// 单击吸附抓取状态机（Click-to-Pick & Move-to-Drop）
  PuzzlePieceComponent? _holdingPiece;
  PuzzlePieceComponent? get holdingPiece => _holdingPiece;
  double _holdingAnchorX = 0.5;
  double _holdingAnchorY = 0.5;

  @override
  void onMouseMove(PointerHoverInfo info) {
    super.onMouseMove(info);
    if (_holdingPiece != null && !_isSolved) {
      final mousePos = info.eventPosition.widget;
      updateHoldingPiecePosition(mousePos);
    }
  }

  @override
  void onTapDown(TapDownEvent event) {
    super.onTapDown(event);
    if (event.handled) return;
    if (_holdingPiece != null && !_isSolved) {
      dropHoldingPiece();
    }
  }

  /// 开启单击吸附抓取模式（鼠标光标跟随）
  void startHoldingPiece(
    PuzzlePieceComponent piece,
    double anchorX,
    double anchorY,
  ) {
    if (piece.isLocked || _isSolved) return;

    _holdingPiece = piece;
    _holdingAnchorX = anchorX;
    _holdingAnchorY = anchorY;
    piece.isDragging = true;
    handlePieceDragStart(piece);
    onStateUpdated?.call();
  }

  /// 根据鼠标光标位置 [cursorCanvasPos]，精确更新被吸附碎片（及其集群）的位置与平滑缩放
  void updateHoldingPiecePosition(Vector2 cursorCanvasPos) {
    final primary = _holdingPiece;
    if (primary == null || _isSolved) return;

    // 1. 计算碎片在当前 Y 坐标下的平滑过渡缩放（桌面散落模式下全程锁定 _zoom，彻底禁用缩放跳变）
    double currentScale;
    if (isTabletop) {
      currentScale = _zoom;
    } else {
      final trayTop = trayPosition.y;
      const transitionBand = 60.0; // 60px 缓冲区间
      final boardScale = _zoom;

      if (cursorCanvasPos.y >= trayTop) {
        currentScale = _trayPieceScale;
      } else if (cursorCanvasPos.y <= trayTop - transitionBand) {
        currentScale = boardScale;
      } else {
        final t = (trayTop - cursorCanvasPos.y) / transitionBand;
        currentScale = _trayPieceScale + (boardScale - _trayPieceScale) * t;
      }
    }

    // 2. 根据归一化锚点精确计算主碎片的新左上角坐标（无论缩放多少，光标永远对准抓取点）
    final targetX =
        cursorCanvasPos.x - _holdingAnchorX * primary.size.x * currentScale;
    final targetY =
        cursorCanvasPos.y - _holdingAnchorY * primary.size.y * currentScale;

    primary.clearActiveEffects();
    primary.scale.setAll(currentScale);
    primary.position.setValues(targetX, targetY);

    // 3. 同步更新同集群内其他碎片的相对位置与缩放
    final clusterPieces = _pieces.values
        .where((p) => p.clusterId == primary.clusterId && p != primary);

    for (final p in clusterPieces) {
      p.clearActiveEffects();
      p.scale.setAll(currentScale);
      final relCol = p.c - primary.c;
      final relRow = p.r - primary.r;
      final px = targetX + relCol * primary.size.x * currentScale;
      final py = targetY + relRow * primary.size.y * currentScale;
      p.position.setValues(px, py);
    }

    // 4. 托盘碎片脱离判定：若碎片原先在托盘中，当且仅当玩家将其真正向上拖出托盘区域时，才正式脱离托盘并平滑闭合托盘空隙
    if (!isTabletop && primary.isInTray && cursorCanvasPos.y < trayPosition.y - 20.0) {
      primary.isInTray = false;
      for (final p in clusterPieces) {
        p.isInTray = false;
      }
      _realignTrayPieces(animate: true);
    }
  }

  /// 放下当前吸附抓取的碎片并触发吸附判定
  void dropHoldingPiece() {
    final piece = _holdingPiece;
    if (piece == null) return;
    _holdingPiece = null;
    piece.isDragging = false;
    handlePieceDragEnd(piece);
  }

  /// 取消当前吸附抓取的碎片并平滑恢复原位
  void cancelHoldingPiece() {
    final piece = _holdingPiece;
    if (piece == null) return;
    _holdingPiece = null;
    piece.isDragging = false;
    cancelPieceDrag(piece);
  }

  @override
  void onPanUpdate(DragUpdateInfo info) {
    super.onPanUpdate(info);
    final pos = info.eventPosition.global;
    if (!isTabletop && pos.y >= trayPosition.y && pos.y <= trayPosition.y + traySize.y) {
      if (!isDraggingAnyPiece) {
        scrollTray(info.delta.global.x);
      }
    } else {
      // 放大状态下，按住空白区域（未抓取碎片时）平移棋盘画布
      if (!isDraggingAnyPiece && _zoom > 1.0) {
        panBy(info.delta.global);
      }
    }
  }

  /// Scrolls the bottom tray horizontally.
  void scrollTray(double deltaX) {
    final trayPieces =
        _pieces.values.where((p) => p.isInTray && !p.isFilteredOut).toList();
    if (trayPieces.isEmpty) return;

    final contentWidth =
        trayPieces.length * (_trayPieceWidth + _traySpacing) + 36.0;
    final minScroll = min(0.0, traySize.x - contentWidth);
    const maxScroll = 0.0;

    _trayScrollX = (_trayScrollX + deltaX).clamp(minScroll, maxScroll);
    _realignTrayPieces(animate: false);
  }

  /// 根据松手时的屏幕横坐标 [dropScreenX]，将 [piece] 就近插入到托盘的最佳插槽位置
  void _insertPieceIntoTrayAt(PuzzlePieceComponent piece, double dropScreenX) {
    // 1. 先从 _trayOrder 中剔除该 piece.id（如果之前在）
    _trayOrder.remove(piece.id);

    // 2. 获取当前托盘内已有可见碎片在 _trayOrder 中的有序列表
    final currentTrayIds = _trayOrder
        .where((id) =>
            _pieces[id]?.isInTray == true && _pieces[id]?.isFilteredOut == false)
        .toList();

    if (currentTrayIds.isEmpty) {
      _trayOrder.insert(0, piece.id);
      return;
    }

    // 3. 计算就近插入索引
    final startX = trayPosition.x + 18.0 + _trayScrollX;
    final step = _trayPieceWidth + _traySpacing;
    final slotOffset = dropScreenX - startX;
    final targetIdx =
        ((slotOffset + step * 0.5) / step).floor().clamp(0, currentTrayIds.length);

    // 4. 将 piece.id 插入到 _trayOrder 对应位置
    if (targetIdx >= currentTrayIds.length) {
      final lastTrayId = currentTrayIds.last;
      final lastPosInOrder = _trayOrder.indexOf(lastTrayId);
      _trayOrder.insert(lastPosInOrder + 1, piece.id);
    } else {
      final targetTrayId = currentTrayIds[targetIdx];
      final targetPosInOrder = _trayOrder.indexOf(targetTrayId);
      _trayOrder.insert(targetPosInOrder, piece.id);
    }
  }

  /// Re-arranges all pieces currently parked in the tray (following shuffled order).
  void _realignTrayPieces({bool animate = true}) {
    var idx = 0;
    for (final id in _trayOrder) {
      final p = _pieces[id];
      if (p == null || !p.isInTray || p.isFilteredOut) continue;
      final targetPos = _getTrayPositionForIndex(idx);
      if (p != _holdingPiece && !p.isDragging) {
        if (animate) {
          p.animateScaleTo(Vector2.all(_trayPieceScale), duration: 0.2);
          p.animateTo(targetPos, duration: 0.2);
        } else {
          p.clearActiveEffects();
          p.scale.setAll(_trayPieceScale);
          p.position.setFrom(targetPos);
        }
      }
      idx++;
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

  @visibleForTesting
  Vector2 normalizedToScreen(double nx, double ny) => _normalizedToScreen(nx, ny);

  @visibleForTesting
  void screenToNormalized(Vector2 screenPos, List<double> out) =>
      _screenToNormalized(screenPos, out);

  @visibleForTesting
  set boardState(PuzzleBoardState state) => _boardState = state;

  /// Clamps panOffset so that the entire zoomed board and scatter area can be freely navigated
  /// without being prematurely truncated or losing sight of any corner/piece.
  void _clampPanOffset() {
    if (_zoom <= 1.0) {
      _panOffset.setZero();
      return;
    }

    final normMinX = isTabletop ? -0.35 : 0.0;
    final normMaxX = isTabletop ? 1.35 : 1.0;
    final normMinY = isTabletop ? -0.35 : 0.0;
    final normMaxY = isTabletop ? 1.35 : 1.0;

    final contentW = (normMaxX - normMinX) * boardSize.x * _zoom;
    final contentH = (normMaxY - normMinY) * boardSize.y * _zoom;

    final viewportW = size.x;
    final viewportH = isTabletop ? size.y : trayPosition.y;

    const edgeMargin = 80.0;

    final minPanX =
        edgeMargin - contentW - boardTopLeft.x - normMinX * boardSize.x * _zoom;
    final maxPanX =
        viewportW - edgeMargin - boardTopLeft.x - normMinX * boardSize.x * _zoom;

    final minPanY =
        edgeMargin - contentH - boardTopLeft.y - normMinY * boardSize.y * _zoom;
    final maxPanY =
        viewportH - edgeMargin - boardTopLeft.y - normMinY * boardSize.y * _zoom;

    if (minPanX > maxPanX) {
      _panOffset.x = (minPanX + maxPanX) / 2;
    } else {
      _panOffset.x = _panOffset.x.clamp(minPanX, maxPanX);
    }

    if (minPanY > maxPanY) {
      _panOffset.y = (minPanY + maxPanY) / 2;
    } else {
      _panOffset.y = _panOffset.y.clamp(minPanY, maxPanY);
    }
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

    _boardGhostComp.position.setFrom(effectiveTopLeft);
    _boardGhostComp.size.setFrom(effectiveBoardSize);

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

  /// Sets board ghost opacity directly.
  void setGhostOpacity(double opacity) {
    _boardGhostOpacity = opacity.clamp(0.0, 1.0);
    _boardGhostComp.opacity = _boardGhostOpacity;
  }

  /// Cycles ghost opacity between 0.0 -> 0.20 -> 0.45 -> 0.0.
  void toggleGhostOpacity() {
    if (_boardGhostOpacity <= 0.01) {
      _boardGhostOpacity = 0.20;
    } else if (_boardGhostOpacity < 0.30) {
      _boardGhostOpacity = 0.45;
    } else {
      _boardGhostOpacity = 0.0;
    }
    _boardGhostComp.opacity = _boardGhostOpacity;
  }

  /// Resets current game state and moves all unsolved pieces back to tray or tabletop.
  void resetCurrentGame() {
    _tabletopScatterSlots = null;
    _isSolved = false;
    _borderFilterActive = false;
    _zoom = 1.0;
    _panOffset.setZero();
    _trayScrollX = 0.0;
    undoManager.clear();

    _boardGhostComp.opacity = _boardGhostOpacity;
    _boardGhostComp.priority = 0;
    _boardOutlineRect.paint.color = const Color(0x66FFFFFF);

    _boardState = PuzzleEngine.createInitialState(
      rows: rows,
      cols: cols,
      seed: seed,
      rotationEnabled: rotationEnabled,
    );

    // 重新打散托盘顺序，避免每次重置都出现相同的排列
    _trayOrder = List<int>.generate(totalPieces, (i) => i)..shuffle(Random());
    final normOut = [0.0, 0.0];
    final initialPieces = <PieceState>[];
    var trayIndex = 0;

    final isTabletop = scatterMode == 'tabletop' && (size.x > 400.0 || size.y > 400.0);

    for (final id in _trayOrder) {
      final r = id ~/ cols;
      final c = id % cols;
      final pPos = isTabletop
          ? _getScatterPositionForIndex(trayIndex, totalPieces)
          : _getTrayPositionForIndex(trayIndex);
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

      final comp = _pieces[id];
      if (comp != null) {
        comp.isInTray = !isTabletop;
        comp.hideBorders = false;
        comp.isFilteredOut = false;
        comp.clusterId = id;
        comp.rot = 0;
        comp.scale.setAll(isTabletop ? _zoom : _trayPieceScale);
        comp.position.setFrom(pPos);
        comp.priority = isTabletop ? _boardUnsolvedPriority : _trayPiecePriority;
        comp.isLocked = false;
      }
      trayIndex++;
    }

    _boardState = _boardState.copyWith(pieces: initialPieces);
    _realignTrayPieces(animate: true);
    _updateBoardTransform();
    updatePiecesStateAndPriorities();
    onProgressChanged?.call(0);
    onStateUpdated?.call();
  }

  /// 统一刷新所有碎片的归位锁定状态 (isLocked) 与渲染交互层级 (Priority)
  ///
  /// 【层级与响应规则】：
  /// 1. 正在被拖拽或光标吸附抓取的碎片 -> `_topPriority`（绝对顶层 1000+）
  /// 2. 棋盘上未归位/自由合并的碎片 -> `_boardUnsolvedPriority`（20，浮于已归位底板碎片上方）
  /// 3. 托盘中的待拼碎片 -> `_trayPiecePriority`（10）
  /// 4. 吸附且已归位的正确碎片 -> `_solvedPiecePriority`（5，贴底渲染且锁定禁止移动）
  void updatePiecesStateAndPriorities() {
    for (final pState in _boardState.pieces) {
      final comp = _pieces[pState.id];
      if (comp == null) continue;

      if (comp.isDragging || comp == _holdingPiece) {
        comp.priority = _topPriority;
        comp.isLocked = false;
        continue;
      }

      final isPieceSolved = pState.isSolved(rows, cols);
      if (isPieceSolved) {
        comp.isLocked = true;
        comp.priority = _solvedPiecePriority;
        comp.isInTray = false;
      } else {
        comp.isLocked = false;
        if (comp.isInTray) {
          comp.priority = _trayPiecePriority;
        } else {
          comp.priority = _boardUnsolvedPriority;
        }
      }
    }
  }

  /// Called when user begins dragging a piece.
  void handlePieceDragStart(PuzzlePieceComponent piece) {
    if (piece.isLocked || _isSolved) return;

    _topPriority += 2;

    for (final p in _pieces.values) {
      if (p.clusterId == piece.clusterId) {
        p.priority = _topPriority;
        p.clearActiveEffects();
      }
    }
  }

  /// Called during drag movement. Moves all pieces in the cluster simultaneously.
  void handlePieceDragUpdate(PuzzlePieceComponent piece, Vector2 delta) {
    for (final p in _pieces.values) {
      if (p.clusterId == piece.clusterId) {
        p.position += delta;
      }
    }
  }

  /// 取消当前所有碎片的拖拽状态，平滑恢复其原有位置
  void cancelAllPieceDragging() {
    for (final p in _pieces.values) {
      if (p.isDragging) {
        cancelPieceDrag(p);
      }
    }
  }

  /// 取消指定碎片集群的拖拽并恢复原位
  void cancelPieceDrag(PuzzlePieceComponent piece) {
    piece.isDragging = false;
    final clusterPieces =
        _pieces.values.where((p) => p.clusterId == piece.clusterId).toList();

    // 检查集群在被拖拽前的状态：若集群包含多块碎片或任一碎片在棋盘上，则集群整体归位于棋盘（严禁拆解集群）
    final isMultiCluster = clusterPieces.length > 1;
    final primaryState = _boardState.pieceById(piece.id);
    final isPrimaryOnBoard = (primaryState.nx >= -0.10 &&
        primaryState.nx <= 1.10 &&
        primaryState.ny >= -0.10 &&
        primaryState.ny <= 1.10);
    final shouldStayOnBoard = isTabletop || isMultiCluster || isPrimaryOnBoard;

    for (final p in clusterPieces) {
      p.isDragging = false;
      p.clearActiveEffects();
      final statePiece = _boardState.pieceById(p.id);

      if (shouldStayOnBoard) {
        p.isInTray = false;
        p.scale.setAll(_zoom);
        final targetPos = _normalizedToScreen(statePiece.nx, statePiece.ny);
        p.animateTo(targetPos, duration: 0.15);
      } else {
        p.isInTray = true;
        p.scale.setAll(_trayPieceScale);
      }
    }
    if (!isTabletop) {
      _realignTrayPieces(animate: true);
    }
    updatePieceVisibility(animateTray: true);
    updatePiecesStateAndPriorities();
  }

  /// Called when user releases drag. Executes snap resolution & cluster merge.
  void handlePieceDragEnd(PuzzlePieceComponent piece) {
    final inTrayArea = piece.position.y >= trayPosition.y - pieceSize.y * 0.25;
    final clusterPieces =
        _pieces.values.where((p) => p.clusterId == piece.clusterId).toList();

    // 1. 如果拖回托盘区域且为单块碎片 -> 就近插入托盘槽位并平滑吸附就位，不触发棋盘吸附
    if (!isTabletop && inTrayArea && clusterPieces.length == 1) {
      _insertPieceIntoTrayAt(piece, piece.position.x);
      piece.isInTray = true;
      piece.animateScaleTo(Vector2.all(_trayPieceScale), duration: 0.15);
      updatePieceVisibility(animateTray: true);
      updatePiecesStateAndPriorities();
      onStateUpdated?.call();
      return;
    }

    // 2. 如果留在棋盘区域（或者是由多块拼好的集群留在棋盘）
    for (final p in clusterPieces) {
      p.isInTray = false;
    }

    // 棋盘上所有非托盘碎片的 ID 集合
    final onBoardPieceIds =
        _pieces.values.where((p) => !p.isInTray).map((p) => p.id).toSet();

    final out = [0.0, 0.0];
    final updatedPieces = _boardState.pieces.map((p) {
      final comp = _pieces[p.id];
      if (comp == null) return p;
      // 仅针对在棋盘上的碎片计算归一化坐标，托盘碎片保留原有状态
      if (!comp.isInTray) {
        _screenToNormalized(comp.position, out);
        return p.copyWith(
          nx: out[0],
          ny: out[1],
          clusterId: comp.clusterId,
          rot: comp.rot,
        );
      }
      return p.copyWith(
        clusterId: comp.clusterId,
        rot: comp.rot,
      );
    }).toList();

    _boardState = _boardState.copyWith(pieces: updatedPieces);

    final result = PuzzleEngine.resolveSnap(
      state: _boardState,
      draggedPieceId: piece.id,
      onBoardPieceIds: onBoardPieceIds,
    );

    if (result.didSnap || result.didMerge || result.isCompleted || _boardState.isSolved) {
      _boardState = result.state;
      undoManager.record(_boardState);

      for (final affectedId in result.affectedPieceIds) {
        final statePiece = _boardState.pieceById(affectedId);
        final comp = _pieces[affectedId];
        if (comp == null) continue;
        comp.isInTray = false;
        comp.scale.setFrom(Vector2.all(_zoom));
        comp.clusterId = statePiece.clusterId;
        comp.rot = statePiece.rot;
        final targetScreenPos =
            _normalizedToScreen(statePiece.nx, statePiece.ny);
        comp.animateTo(targetScreenPos);
        comp.triggerSnapGlow();
      }

      updatePieceVisibility(animateTray: true);
      updatePiecesStateAndPriorities();
      _checkEdgeCompleteAutoDismiss();
      missingPieceCheck();
      onPieceSnapped?.call();
      onProgressChanged?.call(solvedCount);
      onStateUpdated?.call();

      if ((result.isCompleted || _boardState.isSolved) && !_isSolved) {
        _isSolved = true;
        onSolved();
      }
    } else {
      // 未吸附 -> 确保保持棋盘当前 _zoom 尺寸
      for (final p in clusterPieces) {
        p.isInTray = false;
        p.animateScaleTo(Vector2.all(_zoom), duration: 0.15);
      }
      updatePieceVisibility(animateTray: true);
      updatePiecesStateAndPriorities();
      onStateUpdated?.call();
    }
  }

  /// 根据当前边缘筛选状态 [_borderFilterActive]，更新所有碎片的可见性并重排托盘
  void updatePieceVisibility({bool animateTray = true}) {
    for (final p in _pieces.values) {
      final isBorder = edgeLayout.edgesFor(p.r, p.c).isBorder;
      final statePiece = _boardState.pieceById(p.id);
      final isSolved = statePiece.isSolved(rows, cols);

      if (_borderFilterActive) {
        // 边缘筛选模式下：
        // 1. 已归位碎片始终可见；
        // 2. 边缘碎片（包含至少一条平直外框）可见；
        // 3. 与边缘碎片或已归位碎片合并在同一集群的碎片可见；
        // 4. 其他单纯未拼的内部碎片隐藏。
        final clusterPieces =
            _pieces.values.where((o) => o.clusterId == p.clusterId);
        final clusterHasBorderOrSolved = clusterPieces.any((o) =>
            edgeLayout.edgesFor(o.r, o.c).isBorder ||
            _boardState.pieceById(o.id).isSolved(rows, cols));

        p.isFilteredOut = !(isSolved || isBorder || clusterHasBorderOrSolved);
      } else {
        p.isFilteredOut = false;
      }
    }

    if (!isTabletop) {
      final trayPieces = _pieces.values
          .where((p) => p.isInTray && !p.isFilteredOut)
          .toList();
      final contentWidth =
          trayPieces.length * (_trayPieceWidth + _traySpacing) + 36.0;
      final minScroll = min(0.0, traySize.x - contentWidth);
      _trayScrollX = _trayScrollX.clamp(minScroll, 0.0);
      _realignTrayPieces(animate: animateTray);
    }
  }

  /// 检查外边缘是否全部归位闭环：若已拼完外框且当前处于边缘筛选模式，自动合拢并淡入复原内部碎片
  void _checkEdgeCompleteAutoDismiss() {
    if (!_borderFilterActive) return;
    if (_boardState.isEdgeComplete) {
      _borderFilterActive = false;
      updatePieceVisibility(animateTray: true);
      onStateUpdated?.call();
    }
  }

  /// Toggles border pieces filter (only shows border pieces when active).
  void toggleBorderFilter() {
    _borderFilterActive = !_borderFilterActive;
    updatePieceVisibility(animateTray: true);
    onStateUpdated?.call();
  }

  /// Organizes all unlinked/unplaced floating pieces cleanly back into the tray or scattered table.
  void organizeTray() {
    if (isTabletop) {
      final slots = _getTabletopScatterSlots(totalPieces);
      var slotIdx = 0;
      final updatedPieces = <PieceState>[];

      for (final p in _pieces.values) {
        final statePiece = _boardState.pieceById(p.id);
        final isSolved = statePiece.isSolved(rows, cols);
        final clusterSize =
            _pieces.values.where((o) => o.clusterId == p.clusterId).length;
        if (!isSolved && clusterSize == 1) {
          final slotPos = slots[slotIdx % slots.length];
          // slotPos 是基于基准未缩放棋盘 (1.0x) 的世界槽位
          final baseNx = (slotPos.x - boardTopLeft.x) / boardSize.x;
          final baseNy = (slotPos.y - boardTopLeft.y) / boardSize.y;

          p.isInTray = false;
          p.scale.setAll(_zoom);
          final targetPos = _normalizedToScreen(baseNx, baseNy);
          p.animateTo(targetPos, duration: 0.25);
          updatedPieces.add(statePiece.copyWith(nx: baseNx, ny: baseNy));
          slotIdx++;
        } else {
          updatedPieces.add(statePiece);
        }
      }
      _boardState = _boardState.copyWith(pieces: updatedPieces);
      updatePieceVisibility(animateTray: true);
      updatePiecesStateAndPriorities();
      onStateUpdated?.call();
      return;
    }

    final normOut = [0.0, 0.0];
    final updatedPiecesMap = <int, PieceState>{};
    var idx = 0;

    for (final id in _trayOrder) {
      final p = _pieces[id];
      if (p == null) continue;
      final statePiece = _boardState.pieceById(p.id);
      final isSolved = statePiece.isSolved(rows, cols);
      final clusterSize =
          _pieces.values.where((o) => o.clusterId == p.clusterId).length;

      if (!isSolved && clusterSize == 1) {
        p.isInTray = true;
      }

      if (p.isInTray && !p.isFilteredOut) {
        final targetPos = _getTrayPositionForIndex(idx);
        _screenToNormalized(targetPos, normOut);
        updatedPiecesMap[p.id] = statePiece.copyWith(
          nx: normOut[0],
          ny: normOut[1],
        );
        idx++;
      }
    }

    if (updatedPiecesMap.isNotEmpty) {
      final newPieces = _boardState.pieces.map((p) {
        return updatedPiecesMap[p.id] ?? p;
      }).toList();
      _boardState = _boardState.copyWith(pieces: newPieces);
    }

    _trayScrollX = 0.0;
    updatePieceVisibility(animateTray: true);
    updatePiecesStateAndPriorities();
    onStateUpdated?.call();
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
      onStateUpdated?.call();
    }
  }

  /// Restores next snapshot from redo history.
  void redo() {
    final next = undoManager.redo(_boardState);
    if (next != null) {
      _applyBoardState(next);
      onStateUpdated?.call();
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

      // 正确识别棋盘碎片与托盘碎片
      final isOnBoard = (p.nx >= -0.10 && p.nx <= 1.10 && p.ny >= -0.10 && p.ny <= 1.10);
      comp.isInTray = !isOnBoard;

      final targetScreenPos = _normalizedToScreen(p.nx, p.ny);
      comp.animateTo(targetScreenPos);
      if (isOnBoard) {
        comp.scale.setAll(_zoom);
      } else {
        comp.scale.setAll(_trayPieceScale);
      }
    }
    updatePieceVisibility(animateTray: false);
    updatePiecesStateAndPriorities();
    _checkEdgeCompleteAutoDismiss();
    onProgressChanged?.call(solvedCount);
    onStateUpdated?.call();

    if (_boardState.isSolved && !_isSolved) {
      _isSolved = true;
      onSolved();
    }
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
      c.triggerSnapGlow();
    }

    updatePieceVisibility(animateTray: true);
    updatePiecesStateAndPriorities();
    _checkEdgeCompleteAutoDismiss();
    missingPieceCheck();

    onPieceSnapped?.call();
    onProgressChanged?.call(solvedCount);
    onStateUpdated?.call();

    if ((result.isCompleted || _boardState.isSolved) && !_isSolved) {
      _isSolved = true;
      onSolved();
    }
  }

  /// “失踪碎片”防丢自检与自愈机制：
  /// 当整幅拼图剩余未拼碎片 <= 2 块时，若检测到未归位碎片因平移/缩放被甩出可视视口，
  /// 自动将其平滑弹回屏幕可视区域，彻底解决“找不到最后一块碎片”的挫败体验。
  void missingPieceCheck() {
    if (_isSolved) return;
    final unsolved = _boardState.pieces.where((p) => !p.isSolved(rows, cols)).toList();
    if (unsolved.isEmpty || unsolved.length > 2) return;

    final holdingClusterId = _holdingPiece?.clusterId;

    for (final pState in unsolved) {
      final comp = _pieces[pState.id];
      if (comp == null || comp.isDragging || comp == _holdingPiece || comp.isInTray) continue;
      if (holdingClusterId != null && comp.clusterId == holdingClusterId) continue;

      final isOutOfBounds = comp.position.x < -comp.size.x * 0.5 ||
          comp.position.x > size.x - comp.size.x * 0.5 ||
          comp.position.y < -comp.size.y * 0.5 ||
          comp.position.y > size.y - comp.size.y * 0.5;

      if (isOutOfBounds) {
        final safeTarget = Vector2(
          (size.x - comp.size.x * comp.scale.x) / 2,
          (trayPosition.y - comp.size.y * comp.scale.y - 20.0).clamp(20.0, size.y - comp.size.y * comp.scale.y),
        );
        comp.position.setFrom(safeTarget);
        comp.animateTo(safeTarget, duration: 0.35);
        comp.triggerSnapGlow();
      }
    }
  }
}
