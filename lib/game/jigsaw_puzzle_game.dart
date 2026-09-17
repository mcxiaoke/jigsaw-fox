import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart'
    show Color, Paint, PaintingStyle, decodeImageFromList;
import 'package:flutter/scheduler.dart';
import 'package:jigsawpuzzle/game/puzzle_piece_component.dart';
import 'package:jigsawpuzzle/logic/engine/puzzle_engine.dart';
import 'package:jigsawpuzzle/logic/engine/undo_manager.dart';
import 'package:jigsawpuzzle/logic/geometry/edge_layout.dart';
import 'package:jigsawpuzzle/logic/geometry/piece_shape.dart';
import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';
import 'package:jigsawpuzzle/logic/rendering/linen_texture_manager.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/sound_service.dart';

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
  TrayBackgroundComponent({required Vector2 position, required Vector2 size})
    : super(position: position, size: size, priority: 2);

  static final Paint _bgPaint = Paint()
    ..color = const Color(0x66000000)
    ..style = PaintingStyle.fill;

  static final Paint _borderPaint = Paint()
    ..color = const Color(0x33FFFFFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;

  @override
  void render(ui.Canvas canvas) {
    final rect = size.toRect();
    canvas.drawRect(rect, _bgPaint);
    // 顶部半透明高光微边线（通栏平铺底栏风格，替代原全包围圆角描边）
    canvas.drawLine(ui.Offset.zero, ui.Offset(size.x, 0), _borderPaint);
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    super.onDragUpdate(event);
    if (!game.isTabletop &&
        game.holdingPiece == null &&
        !game.isDraggingAnyPiece) {
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
    required this.onSolved,
    int? seed,
    this.rotationEnabled = false,
    this.scatterMode = 'tray',
    this.initialSnapshotJson,
    this.initialGhostOpacity = 0.0,
    this.onPieceSnapped,
    this.onProgressChanged,
    this.onStateUpdated,
  }) : seed = seed ?? (DateTime.now().millisecondsSinceEpoch % 1000000),
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
  static const int _solvedPiecePriority = 5; // 已归位正确碎片（锁定底层，不遮挡任何浮动碎片）
  static const int _trayPiecePriority = 10; // 托盘中的待拼碎片
  static const int _boardUnsolvedPriority = 20; // 散落在棋盘上的未归位碎片
  static const int _activeDragBasePriority = 1000; // 正在拖拽或光标吸附抓取的碎片集群（绝对顶层）

  static const double targetTrayPieceBaseSize =
      64; // Standard touch-friendly base size
  static const double _topToolbarHeight = 8;
  static const double _sideMargin = 8;
  static const double _bottomTrayMargin = 8;
  static const double _trayStartXMargin = 16;

  /// 放大倍数的**最小保证下限**：无论碎片多大，都至少允许放大到此倍数，
  /// 避免“72px 目标小于原始格子 → maxZoom<1 完全无法放大”的问题（可用于精确贴边）。
  static const double minZoom = 2;

  /// 缩放上限的主要依据：放大后**最大碎片边长**不超过该屏幕像素数。
  ///
  /// 最终 `_maxZoom = max(minZoom, maxPieceZoomPx / max(pieceSize.x, pieceSize.y))`：
  /// - 大块/稀疏拼图时，碎片尺寸项通常 < minZoom，取 minZoom（可正常放大到下限）；
  /// - 小块/密集拼图时，碎片尺寸项更大，允许按需放大更多、让碎片长到目标大小，
  ///   同时被该目标封顶，避免无限放大。
  static const double maxPieceZoomPx = 72;

  late Vector2 boardTopLeft;
  late Vector2 boardSize;
  late Vector2 pieceSize;

  double _zoom = 1;
  double get zoom => _zoom;
  final zoomNotifier = ValueNotifier<double>(1);
  double _maxZoom = 3;
  double get maxZoom => _maxZoom;
  final Vector2 _panOffset = Vector2.zero();
  Vector2 get panOffset => _panOffset;

  late RectangleComponent _boardBgRect;
  late BoardGhostComponent _boardGhostComp;
  late RectangleComponent _boardOutlineRect;
  TrayBackgroundComponent? _trayBgComp;

  Vector2 trayPosition = Vector2.zero();
  Vector2 traySize = Vector2.zero();
  double _trayScrollX = 0;
  double _trayPieceScale = 1;
  double get trayPieceScale => _trayPieceScale;
  double _trayPieceWidth = 64;
  double _trayPieceHeight = 64;
  double _traySpacing = 16;

  /// 碎片处于棋盘有效范围判定容差（归一化世界坐标）
  static const double _boardBoundsTolerance = 0.05;

  /// 桌面散落模式散落槽位的网格步长系数（相对碎片基础尺寸）。
  ///
  /// 【选值依据】：碎片含凸头（Tab 最大外扩 35%）后物理占宽可达 1.35~1.70 倍基础格，
  /// 旧值 1.18 使相邻槽位碎片视觉上几乎相贴甚至凸头重叠，洗牌后原图相邻碎片落到
  /// 相邻槽位时看起来"初始就吸附在一起"。经 7 类窗口尺寸 x 多种难度容量模拟验证，
  /// 1.45 在紧凑窗口（如 1024x768 4x4、1366x768 5x5）下槽位容量依然满足 0.80 覆盖率，
  /// 同时典型碎片间隙提升至约 0.15 格，视觉明显分开。
  static const double tabletopScatterStepRatio = 1.45;

  /// 桌面散落模式"空间相邻槽位"判定阈值系数（相对碎片长边）。
  ///
  /// 【选值依据】：水平/垂直紧邻槽位中心距上沿 = 步长 1.45 + 两侧各 ±8% 抖动 ≈ 1.61 倍碎片尺寸，
  /// 阈值 1.65 可完整覆盖全部水平/垂直紧邻对；对角线槽位（约 2.05 倍，16:9 图下 1.66 倍）中
  /// 中心距落在 [1.61, 1.65] 重叠区内的少数会被额外纳入约束——宁可多约束（回退冲突最小化），
  /// 也绝不漏判导致原图相邻碎片重新落在紧邻槽位。
  static const double tabletopScatterSpatialNeighborRatio = 1.65;

  /// 判断归一化坐标是否处于棋盘有效覆盖范围内（含微容差）
  bool _isNormalizedOnBoard(
    double nx,
    double ny, [
    double tol = _boardBoundsTolerance,
  ]) {
    return nx >= -tol && nx <= 1.0 + tol && ny >= -tol && ny <= 1.0 + tol;
  }

  int _topPriority = _activeDragBasePriority;
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;
  bool _isSolved = false;
  bool get isSolved => _isSolved;
  bool _borderFilterActive = false;
  bool get isBorderFilterActive => _borderFilterActive;
  double _boardGhostOpacity = 0;
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
    AppLogger.game.info(
      'onLoad start rows=$rows cols=$cols seed=$seed mode=$scatterMode image=${image.width}x${image.height}',
    );
    final sw = Stopwatch()..start();
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
    _trayOrder = List<int>.generate(totalPieces, (i) => i)
      ..shuffle(Random(seed));
    // [方案B] 桌面散落模式：洗牌后按"原图逻辑邻居禁空间相邻"约束分配散落槽位
    if (isTabletop) {
      _scatterAssignmentCache = _buildScatterAssignment(
        pieceIds: _trayOrder,
        slots: _getTabletopScatterSlots(totalPieces),
      );
    }
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

      final pPos = isTabletop
          ? _getScatterPositionForPieceId(id)
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
      );
      initialPieces.add(pState);

      final component =
          PuzzlePieceComponent(
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
            ..priority = isTabletop
                ? _boardUnsolvedPriority
                : _trayPiecePriority;

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
        AppLogger.game.info(
          'Snapshot restored pieces=${restored.pieces.length} solved=${restored.isSolved}',
        );
        // best-effort：记录后降级继续
        // ignore: avoid_catches_without_on_clauses
      } catch (e, st) {
        AppLogger.game.warning('Snapshot restore failed', e, st);
      }
    }

    // 记录本次布局所依据的画布尺寸：使后续 onGameResize 能以"旧几何 + 旧视口"正确推导
    // 视图中心（详见 [_normalizedViewCenter]），并让同尺寸的重复回调直接早退
    _lastGameSize = size.clone();
    _isInitialized = true;
    updatePiecesStateAndPriorities();
    AppLogger.game.info(
      'onLoad done ${sw.elapsedMilliseconds}ms board=${boardSize.x.toStringAsFixed(1)}x${boardSize.y.toStringAsFixed(1)} piece=${pieceSize.x.toStringAsFixed(1)}x${pieceSize.y.toStringAsFixed(1)} tray=${traySize.x.toStringAsFixed(1)}x${traySize.y.toStringAsFixed(1)}',
    );
  }

  Vector2? _lastGameSize;

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    if (!_isInitialized) return;
    if (_lastGameSize != null && (_lastGameSize! - size).length < 0.5) return;

    // 尺寸变化前先按"旧几何 + 旧视口"记录视图中心（归一化），
    // 供 _syncResizeTransform 在新几何下把同一世界点重新对准视口中心，
    // 避免窗口拉伸/最大化后视野跳变（详见 _syncResizeTransform 注释）。
    final prevViewport = _lastGameSize ?? size;
    final prevViewCenter = _normalizedViewCenter(prevViewport);

    AppLogger.game.info(
      'onGameResize ${size.x.toStringAsFixed(1)}x${size.y.toStringAsFixed(1)} zoom=$_zoom',
    );
    _lastGameSize = size.clone();
    _computeLayout();
    _tabletopScatterSlots = null;
    _scatterAssignmentCache = null;
    _syncResizeTransform(
      viewCenterNx: prevViewCenter.x,
      viewCenterNy: prevViewCenter.y,
    );
  }

  /// 视口中心点对应的**归一化**世界坐标。
  ///
  /// [viewportSize] 需传入目标视口尺寸：在 `onGameResize` 中于 `_computeLayout()`
  /// 之前调用时传入旧尺寸，即可得到"旧几何 + 旧视口"下的视图中心。
  Vector2 _normalizedViewCenter(Vector2 viewportSize) {
    final eff = boardSize * _zoom;
    if (eff.x <= 0 || eff.y <= 0) return Vector2(0.5, 0.5);
    final topLeft = boardTopLeft + _panOffset;
    return Vector2(
      (viewportSize.x / 2 - topLeft.x) / eff.x,
      (viewportSize.y / 2 - topLeft.y) / eff.y,
    );
  }

  /// 当游戏视口大小变化（如 Windows 窗口拉伸/缩放）时，全量同步更新底板、托盘及所有碎片的物理尺寸与坐标。
  ///
  /// **缩放与视野保持**：窗口尺寸变化不再清零缩放与平移，而是
  /// 1. 把 `_zoom` 收敛到新几何推导出的 `_maxZoom` 之内（窗口变大时 `maxZoom` 会下降，
  ///    若不收敛会出现 `_zoom > _maxZoom` 的越界状态）；
  /// 2. 把 [viewCenterNx]/[viewCenterNy] 这个世界点重新对准新视口中心，再按新几何
  ///    收敛平移范围（[`_clampPanOffset`]），避免画面跳变或棋盘被拖出视口。
  void _syncResizeTransform({
    required double viewCenterNx,
    required double viewCenterNy,
  }) {
    // 1. 缩放：保留用户当前倍率，仅收敛到合法上限
    if (_zoom > _maxZoom) {
      _setZoom(_maxZoom);
    }

    // 2. 平移：1.0x 天然锁死居中（与旧行为一致）；放大态按视图中心重新定位并 clamp
    if (_zoom <= 1.0) {
      _panOffset.setZero();
    } else {
      final eff = boardSize * _zoom;
      _panOffset.setValues(
        size.x / 2 - viewCenterNx * eff.x - boardTopLeft.x,
        size.y / 2 - viewCenterNy * eff.y - boardTopLeft.y,
      );
      _clampPanOffset();
    }

    // 3. 同步托盘背景组件
    if (!isTabletop) {
      if (_trayBgComp == null || _trayBgComp!.parent == null) {
        _trayBgComp = TrayBackgroundComponent(
          position: trayPosition.clone(),
          size: traySize.clone(),
        );
        // Flame add() 返回 FutureOr<void>（未加载时同步完成），帧循环内无需等待
        // ignore: discarded_futures
        add(_trayBgComp!);
      } else {
        _trayBgComp!.position.setFrom(trayPosition);
        _trayBgComp!.size.setFrom(traySize);
      }
    } else {
      _trayBgComp?.removeFromParent();
      _trayBgComp = null;
    }

    // 4. 同步棋盘底板、底图水印及外框
    _updateBoardTransform();

    // 5. 动态刷新所有碎片的几何贝塞尔轮廓与基础尺寸
    for (final comp in _pieces.values) {
      final edges = edgeLayout.edgesFor(comp.r, comp.c);
      comp.updateShapeAndSize(
        PieceShape(edges: edges, width: pieceSize.x, height: pieceSize.y),
        pieceSize,
      );

      if (comp.isDragging || comp == _holdingPiece) {
        // 若当前正在被鼠标吸附或拖拽，由 updateHoldingPiecePosition 在下一帧自动对准
        continue;
      }

      if (!isTabletop && comp.isInTray) {
        comp.scale.setAll(_trayPieceScale);
      } else {
        comp.scale.setAll(_zoom);
        final pState = _boardState.pieceById(comp.id);
        comp.position.setFrom(_normalizedToScreen(pState.nx, pState.ny));
      }
    }

    // 6. 合法域边界安全自适应与游离碎片/拼合集群防越界收拢 (Domain Clamp & Cluster Pullback)
    //
    // 判据从旧的"屏幕视口"升级为"合法摆放域"（[_legalDomainScreenRect]）：
    // 放大后碎片允许合法地停在当前视口之外（本次修复新增的能力），若仍以屏幕为界，
    // 每次改窗口都会把玩家摆到视野外的碎片组再次拽回，问题复发。集群仍按外接包围盒
    // 整体原子平移，绝不拆散。
    final domainRect = _legalDomainScreenRect();
    final boundLeft = max(domainRect.left, _sideMargin);
    final boundRight = max(boundLeft, domainRect.right - _sideMargin);
    final boundTop = max(domainRect.top, 44.0);
    final boundBottom = max(boundTop, domainRect.bottom - _sideMargin);
    // 单块游离碎片需整体落在域内，故再减去自身尺寸
    final singleMaxX = max(boundLeft, boundRight - pieceSize.x);
    final singleMaxY = max(boundTop, boundBottom - pieceSize.y);

    // 仅针对越过合法域的游离碎片进行收拢，处于域内的碎片随棋盘/大桌面整体自适应，严禁误 Clamp
    final freeComponents = _pieces.values.where((p) {
      if (p.isInTray || p.isLocked || p == _holdingPiece || p.isDragging) {
        return false;
      }
      final pState = _boardState.pieceById(p.id);
      // 若仍处于合法摆放域内（托盘模式 = 棋盘；桌面模式 = 大桌面），
      // 受棋盘/大桌面矩阵直接保护，绝不因窗口尺寸变化被搬动
      return !_isNormalizedInDomain(pState.nx, pState.ny);
    }).toList();

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
        final clampedX = curX.clamp(boundLeft, singleMaxX);
        final clampedY = curY.clamp(boundTop, singleMaxY);

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
        var minCX = cluster.first.position.x;
        var maxCX = cluster.first.position.x + cluster.first.size.x;
        var minCY = cluster.first.position.y;
        var maxCY = cluster.first.position.y + cluster.first.size.y;

        for (final comp in cluster) {
          minCX = min(minCX, comp.position.x);
          maxCX = max(maxCX, comp.position.x + comp.size.x);
          minCY = min(minCY, comp.position.y);
          maxCY = max(maxCY, comp.position.y + comp.size.y);
        }

        var shiftX = 0.0;
        var shiftY = 0.0;

        if (minCX < boundLeft) {
          shiftX = boundLeft - minCX;
        } else if (maxCX > boundRight) {
          shiftX = boundRight - maxCX;
        }

        if (minCY < boundTop) {
          shiftY = boundTop - minCY;
        } else if (maxCY > boundBottom) {
          shiftY = boundBottom - maxCY;
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

    // 7. 刷新桌面散落槽位缓存（若是散落模式）
    if (isTabletop) {
      _tabletopScatterSlots = null;
      _scatterAssignmentCache = null;
    }

    // 8. 重排托盘碎片
    if (!isTabletop) {
      final trayPieces = _pieces.values
          .where((p) => p.isInTray && !p.isFilteredOut)
          .toList();
      final contentWidth =
          trayPieces.length * (_trayPieceWidth + _traySpacing) + 36.0;
      final minScroll = min(
        0.0,
        traySize.x - contentWidth,
      );
      _trayScrollX = _trayScrollX.clamp(minScroll, 0.0);
      _realignTrayPieces(animate: false);
    }

    updatePiecesStateAndPriorities();
  }

  /// Computes smart board maximizing layout and normalized tray metrics.
  /// 桌面散落模式采用动态自适应棋盘：根据窗口尺寸、图片长宽比与碎片数量
  void _computeLayout() {
    // 1. Bottom Tray Height:
    // 拼图碎片凸头（Tab）最大向外延伸 35%，双向凸头时物理总高度达 1.70 * _trayPieceHeight。
    // 托盘高度设置为基础碎片高度的 2.0 倍（约 128px），并在内部垂直居中对齐，
    // 确保任何切片的凸头在顶部与底部均保留约 10px 的安全呼吸空间，绝不溢出托盘边缘。
    final srcPieceW = image.width / cols;
    final srcPieceH = image.height / rows;
    final maxSrcSide = max(srcPieceW, srcPieceH);
    _trayPieceWidth = srcPieceW * (targetTrayPieceBaseSize / maxSrcSide);
    _trayPieceHeight = srcPieceH * (targetTrayPieceBaseSize / maxSrcSide);

    final targetTrayH = _trayPieceHeight * 2.0;
    // 托盘横向 100% 铺满全屏（通栏 Dock 风格），彻底消除碎片滚动至左右两侧时跨越圆角/悬空的视觉突兀感
    traySize = Vector2(size.x, targetTrayH);
    trayPosition = Vector2(0, size.y - targetTrayH - _bottomTrayMargin);

    final imageAspect = image.width / image.height;
    double bW;
    double bH;

    if (isTabletop) {
      // 桌面散落模式：动态预留四周碎片存放空间，最大化棋盘
      // 策略：
      // 1) 以全屏可用区域 (fullW x fullH) 为基准，按比例 S 拟合得到候选棋盘 fit(fullW*S, fullH*S)
      // 2) 候选棋盘下 pieceSize = board/cols, rows，推算四周栅格可容纳散落槽位数 (同 _getTabletopScatterSlots 逻辑)
      // 3) 槽位数 >= 碎片总数 * coverage(0.80) 即视为可满足散落，允许少量碎片轻微覆盖边线(用户已确认可接受)
      // 4) 二分搜索最大可行 S，随后按 3% 视觉收缩留出呼吸感，并保持长宽比
      final double fullW = max(
        100.0,
        size.x - _sideMargin * 2,
      );
      final double fullH = max(
        100.0,
        size.y - _topToolbarHeight - 16.0,
      );

      Vector2 fitBoard(double maxW, double maxH) {
        final areaAspect = maxW / maxH;
        if (imageAspect >= areaAspect) {
          final w = maxW;
          return Vector2(w, w / imageAspect);
        } else {
          final h = maxH;
          return Vector2(h * imageAspect, h);
        }
      }

      int estimateSlots(Vector2 testBoardSize) {
        final testPieceW = testBoardSize.x / cols;
        final testPieceH = testBoardSize.y / rows;
        final testBoardLeft = (size.x - testBoardSize.x) / 2;
        final testBoardTop =
            _topToolbarHeight +
            (size.y - _topToolbarHeight - testBoardSize.y) / 2;
        const pad = 4.0; // 允许贴边/轻微覆盖边线，相比原 16px 更宽松，配合用户反馈
        final safeLeft = testBoardLeft - pad;
        final safeTop = testBoardTop - pad;
        final safeRight = testBoardLeft + testBoardSize.x + pad;
        final safeBottom = testBoardTop + testBoardSize.y + pad;
        final stepX = max(32, testPieceW * tabletopScatterStepRatio);
        final stepY = max(32, testPieceH * tabletopScatterStepRatio);
        final colsCount = max(1, ((size.x - 16.0) / stepX).floor());
        final rowsCount = max(1, ((size.y - 60.0) / stepY).floor());
        const topMargin = 48.0;
        final sideMargin = (size.x - colsCount * stepX) / 2;
        var cnt = 0;
        for (var r = 0; r < rowsCount; r++) {
          final py = topMargin + r * stepY;
          for (var c = 0; c < colsCount; c++) {
            final px = sideMargin + c * stepX;
            final isOverlap =
                !(px + testPieceW <= safeLeft ||
                    px >= safeRight ||
                    py + testPieceH <= safeTop ||
                    py >= safeBottom);
            if (!isOverlap &&
                px >= 8.0 &&
                px + testPieceW <= size.x - 8.0 &&
                py >= 44.0 &&
                py + testPieceH <= size.y - 8.0) {
              cnt++;
            }
          }
        }
        return cnt;
      }

      bool hasBalancedDistribution(Vector2 testBoardSize) {
        final testPieceW = testBoardSize.x / cols;
        final testPieceH = testBoardSize.y / rows;
        final testBoardLeft = (size.x - testBoardSize.x) / 2;
        final testBoardTop =
            _topToolbarHeight +
            (size.y - _topToolbarHeight - testBoardSize.y) / 2;
        const pad = 4.0;
        final safeLeft = testBoardLeft - pad;
        final safeTop = testBoardTop - pad;
        final safeRight = testBoardLeft + testBoardSize.x + pad;
        final safeBottom = testBoardTop + testBoardSize.y + pad;
        final stepX = max(32, testPieceW * tabletopScatterStepRatio);
        final stepY = max(32, testPieceH * tabletopScatterStepRatio);
        final colsCount = max(1, ((size.x - 16.0) / stepX).floor());
        final rowsCount = max(1, ((size.y - 60.0) / stepY).floor());
        const topMargin = 48.0;
        final sideMargin = (size.x - colsCount * stepX) / 2;
        final centerX = testBoardLeft + testBoardSize.x / 2;
        final centerY = testBoardTop + testBoardSize.y / 2;
        var leftRight = 0;
        var topBottom = 0;
        for (var r = 0; r < rowsCount; r++) {
          final py = topMargin + r * stepY;
          for (var c = 0; c < colsCount; c++) {
            final px = sideMargin + c * stepX;
            final isOverlap =
                !(px + testPieceW <= safeLeft ||
                    px >= safeRight ||
                    py + testPieceH <= safeTop ||
                    py >= safeBottom);
            if (!isOverlap &&
                px >= 8.0 &&
                px + testPieceW <= size.x - 8.0 &&
                py >= 44.0 &&
                py + testPieceH <= size.y - 8.0) {
              final pCenterX = px + testPieceW / 2;
              final pCenterY = py + testPieceH / 2;
              final dx = pCenterX - centerX;
              final dy = pCenterY - centerY;
              if (dx.abs() > dy.abs()) {
                leftRight++;
              } else {
                topBottom++;
              }
            }
          }
        }
        // 要求上下左右均有分布，至少各有 1 个槽位，避免全部挤在左右
        return leftRight > 0 && topBottom > 0;
      }

      if (size.x < 10 || size.y < 10) {
        final fallback = fitBoard(fullW * 0.56, fullH * 0.56);
        bW = fallback.x;
        bH = fallback.y;
      } else {
        const coverage = 0.80; // 允许 20% 碎片轻微与棋盘边线重叠
        const minScale = 0.50;
        const maxScale = 0.92;
        var bestScale = 0.56;
        var low = minScale;
        var high = maxScale;
        // 预计算需求
        final need = (rows * cols * coverage).ceil();
        // 若最小尺度仍不满足，沿用最小尺度避免无解（需同时满足槽位与四周均衡分布）
        final minBoard = fitBoard(fullW * minScale, fullH * minScale);
        bool isFeasible(Vector2 b) =>
            estimateSlots(b) >= need && hasBalancedDistribution(b);
        if (isFeasible(minBoard)) {
          for (var i = 0; i < 12; i++) {
            final mid = (low + high) / 2;
            final candBoard = fitBoard(fullW * mid, fullH * mid);
            if (isFeasible(candBoard)) {
              bestScale = mid;
              low = mid;
            } else {
              high = mid;
            }
          }
        } else {
          // 极端小窗口或四周无法均衡，回退到仅按槽位数寻找可行解（允许左右集中）
          if (estimateSlots(minBoard) >= need) {
            for (var i = 0; i < 12; i++) {
              final mid = (low + high) / 2;
              final candBoard = fitBoard(fullW * mid, fullH * mid);
              if (estimateSlots(candBoard) >= need) {
                bestScale = mid;
                low = mid;
              } else {
                high = mid;
              }
            }
          } else {
            bestScale = minScale;
          }
        }
        final bestBoard = fitBoard(fullW * bestScale, fullH * bestScale);
        // 视觉收缩 3% 留出呼吸感，等效用户建议的 10% 收缩的轻量化版本；
        // 若未能找到更大尺度（bestScale 仍为 0.56），则保持原 0.56 基准不收缩，避免回退变小
        const visualShrink = 0.97;
        if (bestScale <= 0.565) {
          bW = bestBoard.x;
          bH = bestBoard.y;
        } else {
          bW = bestBoard.x * visualShrink;
          bH = bestBoard.y * visualShrink;
        }
      }
      boardSize = Vector2(bW, bH);
      boardTopLeft = Vector2(
        (size.x - bW) / 2,
        _topToolbarHeight + (size.y - _topToolbarHeight - bH) / 2,
      );
      pieceSize = Vector2(bW / cols, bH / rows);
    } else {
      final availableBoardW = max(
        100.0,
        size.x - _sideMargin * 2,
      );
      final availableBoardH = max(
        100.0,
        trayPosition.y - _topToolbarHeight - 8.0,
      );
      final areaAspect = availableBoardW / availableBoardH;
      if (imageAspect >= areaAspect) {
        bW = availableBoardW;
        bH = bW / imageAspect;
      } else {
        bH = availableBoardH;
        bW = bH * imageAspect;
      }
      boardSize = Vector2(bW, bH);
      boardTopLeft = Vector2(
        _sideMargin + (availableBoardW - bW) / 2,
        _topToolbarHeight + (availableBoardH - bH) / 2,
      );
      pieceSize = Vector2(bW / cols, bH / rows);
    }

    // 缩放上限：保证至少能放大到 minZoom（大块也能精确贴边），
    // 并让小块（密集拼图）按碎片尺寸放大更多、以 maxPieceZoomPx 封顶。
    final pieceMaxSide = max(pieceSize.x, pieceSize.y);
    _maxZoom = max(minZoom, maxPieceZoomPx / pieceMaxSide);
    AppLogger.game.fine(
      'maxZoom derived from pieceMaxSide=${pieceMaxSide.toStringAsFixed(1)} -> $_maxZoom',
    );

    // 3. Normalized Tray Scaling (Target max side = 64px, preserving piece aspect ratio)
    final maxPieceSide = max(pieceSize.x, pieceSize.y);
    _trayPieceScale = targetTrayPieceBaseSize / maxPieceSide;
    _traySpacing = 14.0;
  }

  List<Vector2>? _tabletopScatterSlots;

  /// 桌面散落模式"碎片 → 散落槽位索引"约束分配缓存（方案B）。
  /// 以碎片 id 为下标、值为槽位索引；仅在初始洗牌（onLoad / resetCurrentGame）时构建，
  /// organizeTray 与读档重散落使用独立的局部约束分配，避免与已固定碎片（已归位/多片集群）冲突。
  List<int>? _scatterAssignmentCache;

  /// Computes the exact screen coordinate for the N-th piece in the bottom tray.
  /// 碎片基础单元格在托盘内垂直居中对齐，上下对称预留 50% 基础高度空间（完全包容 35% 凸头并留白）
  Vector2 _getTrayPositionForIndex(int index) {
    final startX = trayPosition.x + _trayStartXMargin + _trayScrollX;
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
  /// 5. 动态几何避让：棋盘中心保护区保留 8px 呼吸间隙，允许轻微贴边/覆盖边线（已验证用户可接受），配合自适应棋盘放大。
  List<Vector2> _getTabletopScatterSlots(int total) {
    if (_tabletopScatterSlots != null &&
        _tabletopScatterSlots!.length >= total) {
      return _tabletopScatterSlots!;
    }

    const pad = 4.0;
    final safeLeft = boardTopLeft.x - pad;
    final safeTop = boardTopLeft.y - pad;
    final safeRight = boardTopLeft.x + boardSize.x + pad;
    final safeBottom = boardTopLeft.y + boardSize.y + pad;

    // 开阔步长 (tabletopScatterStepRatio=1.45 倍基础格)，保证碎片含凸头后仍有明显视觉间隙
    final stepX = max(32, pieceSize.x * tabletopScatterStepRatio);
    final stepY = max(32, pieceSize.y * tabletopScatterStepRatio);

    final cols = max(1, ((size.x - 16.0) / stepX).floor());
    final rows = max(1, ((size.y - 60.0) / stepY).floor());

    const topMargin = 48.0;
    final sideMargin = (size.x - cols * stepX) / 2;

    final centerX = boardTopLeft.x + boardSize.x / 2;
    final centerY = boardTopLeft.y + boardSize.y / 2;

    final candidates = <({double x, double y, double angle, double dist})>[];

    for (var r = 0; r < rows; r++) {
      final py = topMargin + r * stepY;
      for (var c = 0; c < cols; c++) {
        final px = sideMargin + c * stepX;

        // 碰撞判定：严格避让中央棋盘安全区域
        final isOverlap =
            !(px + pieceSize.x <= safeLeft ||
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
          final dist = Point(
            pCenterX,
            pCenterY,
          ).distanceTo(Point(centerX, centerY));
          candidates.add((x: px, y: py, angle: angle, dist: dist));
        }
      }
    }

    if (candidates.isEmpty) {
      return List.generate(total, _getTrayPositionForIndex);
    }

    // 按围绕棋盘中心的 8 个方位扇区归类
    final sectors = List.generate(
      8,
      (_) => <({double x, double y, double angle, double dist})>[],
    );
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
          slots.add(
            Vector2(
              (item.x + jx).clamp(8.0, size.x - pieceSize.x - 8.0),
              (item.y + jy).clamp(44.0, size.y - pieceSize.y - 8.0),
            ),
          );
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

  /// 原图 4-连通逻辑邻居表：pieceId → 上下左右邻居 id 集合。
  ///
  /// 【用途（方案B）】：桌面散落约束分配时，保证任何一对"原图相邻"的碎片
  /// 不被分配到空间相邻的散落槽位，杜绝洗牌后出现"初始即吸附/拼好"的观感。
  static Map<int, Set<int>> _logicalNeighborMap(int rows, int cols) {
    final map = <int, Set<int>>{};
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final id = r * cols + c;
        final set = <int>{};
        if (r > 0) set.add((r - 1) * cols + c);
        if (r < rows - 1) set.add((r + 1) * cols + c);
        if (c > 0) set.add(r * cols + c - 1);
        if (c < cols - 1) set.add(r * cols + c + 1);
        map[id] = set;
      }
    }
    return map;
  }

  /// 槽位空间邻居表：中心距小于 [threshold] 的槽位互为空间邻居。
  static List<Set<int>> _buildSpatialNeighborSets(
    List<Vector2> slots,
    double threshold,
  ) {
    final sets = List.generate(slots.length, (_) => <int>{});
    for (var i = 0; i < slots.length; i++) {
      for (var j = i + 1; j < slots.length; j++) {
        if ((slots[i] - slots[j]).length < threshold) {
          sets[i].add(j);
          sets[j].add(i);
        }
      }
    }
    return sets;
  }

  /// 约束分配（方案B）：将 [pieceIds] 按序分配到散落 [slots]，返回"碎片 id → 槽位索引"。
  ///
  /// 【算法】：
  /// 1. 洗牌顺序 [pieceIds] 是随机性来源（同 seed 确定性一致）；
  /// 2. 贪心选槽：优先选"与其原图逻辑邻居已占用槽位零空间冲突"的槽位；
  /// 3. **多轮扰动兜底**：单轮贪心无回溯，紧凑槽位下部分种子会失败（原图邻居
  ///    被迫落入空间相邻槽 → 初始"伪吸附"观感 + 测试 flaky）。故扰动顺序至多
  ///    64 轮，命中零冲突解立即返回；全失败则返回冲突最少的轮次（不差于旧行为）。
  List<int> _buildScatterAssignment({
    required List<int> pieceIds,
    required List<Vector2> slots,
  }) {
    final logical = _logicalNeighborMap(rows, cols);
    final threshold =
        max(pieceSize.x, pieceSize.y) * tabletopScatterSpatialNeighborRatio;
    final spatial = _buildSpatialNeighborSets(slots, threshold);

    List<int>? bestAssign;
    var bestConflicts = 1 << 30;
    final baseRng = Random((seed ^ 0x5F3759DF) & 0x7FFFFFFF);
    const maxRounds = 64;
    for (var round = 0; round < maxRounds; round++) {
      final order = List<int>.of(pieceIds);
      if (round > 0) {
        order.shuffle(Random(baseRng.nextInt(0x7FFFFFFF)));
      }

      final assign = List<int>.filled(totalPieces, -1);
      final used = List<bool>.filled(slots.length, false);
      var roundConflicts = 0;

      for (final id in order) {
        // 该碎片原图逻辑邻居中已分配碎片所占用的槽位集合
        final neighborSlots = <int>{};
        for (final nid in logical[id] ?? const <int>{}) {
          final s = assign[nid];
          if (s >= 0) neighborSlots.add(s);
        }

        var bestSlot = -1;
        var bestConflict = 1 << 30;
        for (var s = 0; s < slots.length; s++) {
          if (used[s]) continue;
          var conflict = 0;
          for (final ns in spatial[s]) {
            if (neighborSlots.contains(ns)) conflict++;
          }
          if (conflict == 0) {
            bestSlot = s;
            bestConflict = 0;
            break;
          }
          if (conflict < bestConflict) {
            bestConflict = conflict;
            bestSlot = s;
          }
        }
        if (bestSlot < 0) {
          // 防御兜底：槽位生成保证 slots.length >= totalPieces，正常不可达
          for (var s = 0; s < slots.length; s++) {
            if (!used[s]) {
              bestSlot = s;
              bestConflict = 1; // 无法零冲突（理论不可达），按违规计 1
              break;
            }
          }
        }
        roundConflicts += bestConflict;
        used[bestSlot] = true;
        assign[id] = bestSlot;
      }

      if (roundConflicts == 0) return assign; // 零冲突解
      if (roundConflicts < bestConflicts) {
        bestConflicts = roundConflicts;
        bestAssign = assign;
      }
    }
    return bestAssign!;
  }

  /// 获取指定碎片在桌面发散模式下的坐标（方案B：按约束分配缓存结果取槽位）。
  /// 仅桌面模式调用；托盘模式由调用方直接使用 [_getTrayPositionForIndex]。
  Vector2 _getScatterPositionForPieceId(int id) {
    final slots = _getTabletopScatterSlots(totalPieces);
    return slots[_scatterAssignmentCache![id]];
  }

  @override
  void onScroll(PointerScrollInfo info) {
    super.onScroll(info);
    final mousePos = info.eventPosition.global;
    if (mousePos.y >= trayPosition.y &&
        mousePos.y <= trayPosition.y + traySize.y) {
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

  /// 拖拽交互安全矩形的上下左右（屏幕坐标）——**主片中心**允许停留的范围。
  ///
  /// 【为什么是"中心"而不是"整簇包围盒"】
  /// 旧实现（提交 `a5deb7b` 引入）要求整个集群的外接包围盒都塞进屏幕，
  /// 边界形如 `size - margin - clusterOffset`，其中 `clusterOffset` 含 `× _zoom`。
  /// 当 `_zoom >= 2`（本项目各难度 `maxZoom` 恒为 2.0）且集群投影尺寸超过可用空间时，
  /// 会出现 `safeMin > safeMax`，被 `min/max` 兜底退化成**一个点**：
  /// 碎片组完全拖不动、松手即被钉死（实测 4×4 盘 2×2 集群在 1200×800 下 Y 轴行程为 0）。
  ///
  /// 改为约束**单点（主片中心）**后：区间恒为正，数学上不可能退化；
  /// 集群其余部分（乃至主片的大半）允许伸出视口，从而支持放大状态下把已拼合的
  /// 碎片组推出可视区暂存——这正是本次修复的核心诉求。
  /// 同时"主片中心恒在视口内"仍保证碎片**永不完全消失**、随时可再次抓取。
  ({double left, double top, double right, double bottom})
  get _dragCenterSafeBounds => (
    left: _sideMargin,
    top: _topToolbarHeight,
    right: max(_sideMargin, size.x - _sideMargin),
    bottom: max(_topToolbarHeight, size.y - _bottomTrayMargin),
  );

  /// 拖拽限位的**唯一入口**：先按光标与归一化锚点算出主片左上角，
  /// 再把主片中心夹入 [_dragCenterSafeBounds]。拖拽期与松手期共用，杜绝两处公式漂移。
  ///
  /// - [cursorCanvasPos]：当前光标（= 抓取点）的画布坐标；
  /// - [pieceSizeRef]：主片基础尺寸；[scale]：当前拖拽缩放；
  /// - [anchorX]/[anchorY]：归一化抓取锚点（0~1）。
  Vector2 _clampDragTarget({
    required Vector2 cursorCanvasPos,
    required Vector2 pieceSizeRef,
    required double scale,
    required double anchorX,
    required double anchorY,
  }) {
    final safe = _dragCenterSafeBounds;
    final visualW = pieceSizeRef.x * scale;
    final visualH = pieceSizeRef.y * scale;
    final rawLeft = cursorCanvasPos.x - anchorX * visualW;
    final rawTop = cursorCanvasPos.y - anchorY * visualH;
    final centerX = (rawLeft + visualW / 2).clamp(safe.left, safe.right);
    final centerY = (rawTop + visualH / 2).clamp(safe.top, safe.bottom);
    return Vector2(centerX - visualW / 2, centerY - visualH / 2);
  }

  /// 根据鼠标光标位置 [cursorCanvasPos]，精确更新被吸附碎片（及其集群）的位置与平滑缩放
  void updateHoldingPiecePosition(Vector2 cursorCanvasPos) {
    final primary = _holdingPiece;
    if (primary == null || _isSolved) return;

    // 0. 计算同集群内其他碎片（后续缩放、位置联动与托盘脱离判定共用）
    final clusterPieces = _pieces.values.where(
      (p) => p.clusterId == primary.clusterId && p != primary,
    );
    final isMultiCluster = clusterPieces.isNotEmpty;

    // 1. 计算碎片在当前 Y 坐标下的平滑过渡缩放。
    //    [多块集群] 桌面散落模式 或 已吸附拼合的多块集群：全程锁定棋盘尺寸 _zoom。
    //    原因：多块集群永远无法放回托盘（handlePieceDragEnd 仅单块允许回托盘），
    //    拖入托盘区域时缩小到 _trayPieceScale 是误导性反馈，会造成"缩小-松手弹回"。
    //    [单块碎片] 非桌面模式按光标 Y 在托盘尺寸与棋盘尺寸间平滑过渡（放回托盘的视觉暗示）。
    double currentScale;
    if (isTabletop || isMultiCluster) {
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

    // 2. 根据归一化锚点精确计算主碎片的新左上角坐标（无论缩放多少，光标永远对准抓取点），
    //    并把主片中心夹入交互安全区。限位只作用于"单点（中心）"，区间恒为正、
    //    永不退化为单点锁死；集群其余部分允许伸出视口（详见 [_clampDragTarget]）。
    final target = _clampDragTarget(
      cursorCanvasPos: cursorCanvasPos,
      pieceSizeRef: primary.size,
      scale: currentScale,
      anchorX: _holdingAnchorX,
      anchorY: _holdingAnchorY,
    );
    final targetX = target.x;
    final targetY = target.y;

    primary.clearActiveEffects();
    primary.scale.setAll(currentScale);
    primary.position.setValues(targetX, targetY);

    for (final p in clusterPieces) {
      p.clearActiveEffects();
      p.scale.setAll(currentScale);
      final relCol = p.c - primary.c;
      final relRow = p.r - primary.r;
      final px = targetX + relCol * primary.size.x * currentScale;
      final py = targetY + relRow * primary.size.y * currentScale;
      p.position.setValues(px, py);
    }

    // 3. 托盘碎片脱离判定：若碎片原先在托盘中，当且仅当玩家将其真正向上拖出托盘区域时，才正式脱离托盘并平滑闭合托盘空隙
    if (!isTabletop &&
        primary.isInTray &&
        cursorCanvasPos.y < trayPosition.y - 20.0) {
      primary.isInTray = false;
      for (final p in clusterPieces) {
        p.isInTray = false;
      }
      _realignTrayPieces();
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

  // 空白区域单指平移已由 GamePage 的 Listener (_onPointerMove) 统一处理，
  // 此处不再覆写 onPanUpdate，以避免：
  // 1) 与 DragCallbacks 的 MultiDragScaleGestureRecognizer 手势竞技场冲突
  //    （存在 DragCallbacks 时 PanGestureRecognizer 会被抢占，导致空白拖动失效）
  // 2) 与 Listener 双重调用导致的 2 倍速平移

  /// Scrolls the bottom tray horizontally.
  void scrollTray(double deltaX) {
    final trayPieces = _pieces.values
        .where((p) => p.isInTray && !p.isFilteredOut)
        .toList();
    if (trayPieces.isEmpty) return;

    final contentWidth =
        trayPieces.length * (_trayPieceWidth + _traySpacing) + 36.0;
    final minScroll = min(
      0.0,
      traySize.x - contentWidth,
    );
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
        .where(
          (id) =>
              _pieces[id]?.isInTray == true &&
              _pieces[id]?.isFilteredOut == false,
        )
        .toList();

    if (currentTrayIds.isEmpty) {
      _trayOrder.insert(0, piece.id);
      return;
    }

    // 3. 计算就近插入索引（与 _getTrayPositionForIndex 严格共享同一 _trayStartXMargin 基准）
    final startX = trayPosition.x + _trayStartXMargin + _trayScrollX;
    final step = _trayPieceWidth + _traySpacing;
    final slotOffset = dropScreenX - startX;
    final targetIdx = ((slotOffset + step * 0.5) / step).floor().clamp(
      0,
      currentTrayIds.length,
    );

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

  /// 判断指定屏幕坐标是否落在托盘物理交互区域内（含微容差）
  bool isPointInTrayArea(Vector2 pos) {
    if (isTabletop) return false;
    return pos.y >= trayPosition.y - 20.0;
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
  Vector2 normalizedToScreen(double nx, double ny) =>
      _normalizedToScreen(nx, ny);

  @visibleForTesting
  void screenToNormalized(Vector2 screenPos, List<double> out) =>
      _screenToNormalized(screenPos, out);

  @visibleForTesting
  set boardState(PuzzleBoardState state) => _boardState = state;

  /// 计算“缩放无关、带硬上限”的吸附容差（归一化空间）。
  ///
  /// 【问题】：原 `calculateSnapThreshold` 是归一化常量 `0.40 * min(1/cols, 1/rows)`，
  /// 但在**屏幕像素**上随缩放成正比放大——放大后吸附半径暴涨，导致碎片在离槽位较远时
  /// 就被吸过去并锁定，出现“离槽位还有距离却被吸附/锁定”的 bug。
  ///
  /// 【修复】：屏幕像素吸附半径恒定并设硬上限 48px，缩放越大归一化阈值越小，
  /// 使吸附手感不再随放大而走样；1× 缩放、且单元格像素×0.40 < 48px 时与原始行为一致，无手感回退。
  double effectiveSnapDistance() {
    const ratio = PuzzleEngine.defaultSnapRatio; // 0.40，见 PuzzleEngine
    const maxScreenPx = 48; // 吸附半径屏幕像素硬上限
    final minBoardPx = min(boardSize.x, boardSize.y);
    final minCellPx = minBoardPx * min(1.0 / cols, 1.0 / rows);
    final cellPx = minCellPx * _zoom; // 当前缩放下单格最小边屏幕像素
    final screenPx = min(cellPx * ratio, maxScreenPx);
    return screenPx / (minBoardPx * _zoom);
  }

  /// 视口贴边包裹模型 (Viewport Containment - v1.1 终版)：
  /// 1. 彻底移除 setZero() 早退：1.0x 及以下完全由几何约束自动收敛居中，根治未松手弹跳；
  /// 2. 坐标系基准统一：双模式均对齐 _sideMargin 与 _topToolbarHeight，杜绝钻入 AppBar；
  /// 3. 单点退化与浮点防御：content < view 时自然收缩为 min==max==center，并用 min/max 防御 ArgumentError。
  void _clampPanOffset() {
    const eps = 1e-6;

    // 视口矩形：双模式统一对齐 _computeLayout 基准坐标系
    const viewLeft = _sideMargin;
    final viewRight = size.x - _sideMargin;
    const viewTop = _topToolbarHeight;
    final viewBottom = isTabletop
        ? size.y - _bottomTrayMargin
        : trayPosition.y - _bottomTrayMargin;

    // 归一化合法域：与 [_legalDomain] 单一权威定义同源（桌面模式基于大桌面全景动态推导，
    // 彻底废除硬编码 [-0.35, 1.35]）
    final domain = _legalDomain();
    final normMinX = domain.minX;
    final normMaxX = domain.maxX;
    final normMinY = domain.minY;
    final normMaxY = domain.maxY;

    final viewW = max(0, viewRight - viewLeft);
    final viewH = max(0, viewBottom - viewTop);

    final contentW = (normMaxX - normMinX) * boardSize.x * _zoom;
    final contentH = (normMaxY - normMinY) * boardSize.y * _zoom;

    // 水平维度 (X)：内容超视口则贴边 clamp；内容窄于视口则退化为单点居中
    double minPanX;
    double maxPanX;
    if (contentW + eps >= viewW) {
      maxPanX = viewLeft - boardTopLeft.x - normMinX * boardSize.x * _zoom;
      minPanX =
          viewRight -
          boardTopLeft.x -
          normMinX * boardSize.x * _zoom -
          contentW;
    } else {
      final centerX =
          viewLeft +
          (viewW - contentW) / 2 -
          boardTopLeft.x -
          normMinX * boardSize.x * _zoom;
      minPanX = maxPanX = centerX;
    }
    _panOffset.x = _panOffset.x.clamp(
      min(minPanX, maxPanX),
      max(minPanX, maxPanX),
    );

    // 垂直维度 (Y)：内容超视口则贴边 clamp；内容矮于视口则退化为单点居中
    double minPanY;
    double maxPanY;
    if (contentH + eps >= viewH) {
      maxPanY = viewTop - boardTopLeft.y - normMinY * boardSize.y * _zoom;
      minPanY =
          viewBottom -
          boardTopLeft.y -
          normMinY * boardSize.y * _zoom -
          contentH;
    } else {
      final centerY =
          viewTop +
          (viewH - contentH) / 2 -
          boardTopLeft.y -
          normMinY * boardSize.y * _zoom;
      minPanY = maxPanY = centerY;
    }
    _panOffset.y = _panOffset.y.clamp(
      min(minPanY, maxPanY),
      max(minPanY, maxPanY),
    );
  }

  /// 合法摆放域（归一化世界坐标）——[_clampPanOffset]、[_legalDomainScreenRect] 与
  /// [_isNormalizedInDomain] 共用的**唯一权威定义**，杜绝多处定义漂移。
  ///
  /// - 托盘模式：棋盘域 `nx, ny ∈ [0, 1]`；
  /// - 桌面模式：由视口反算的大桌面域（1.0x 时恰好等于视口，放大后随 zoom 扩展）。
  ({double minX, double maxX, double minY, double maxY}) _legalDomain() {
    if (!isTabletop) {
      return (minX: 0.0, maxX: 1.0, minY: 0.0, maxY: 1.0);
    }
    const viewLeft = _sideMargin;
    final viewRight = size.x - _sideMargin;
    const viewTop = _topToolbarHeight;
    final viewBottom = size.y - _bottomTrayMargin;
    return (
      minX: (viewLeft - boardTopLeft.x) / boardSize.x,
      maxX: (viewRight - boardTopLeft.x) / boardSize.x,
      minY: (viewTop - boardTopLeft.y) / boardSize.y,
      maxY: (viewBottom - boardTopLeft.y) / boardSize.y,
    );
  }

  /// 归一化坐标是否仍落在合法摆放域内（含 [_boardBoundsTolerance] 微容差）。
  ///
  /// 与 [_isNormalizedOnBoard] 的区别：后者**恒以棋盘 `[0,1]` 为界**，服务于
  /// "碎片是否在棋盘上"这类业务判定；本方法以**当前模式的合法域**为界
  /// （桌面模式下大于 `[0,1]`），服务于窗口尺寸变化时的越界收拢判据——
  /// 避免把桌面散落的碎片、以及放大后合法停在视口外的碎片误判为"越界"而反复搬动。
  bool _isNormalizedInDomain(double nx, double ny) {
    final d = _legalDomain();
    const tol = _boardBoundsTolerance;
    return nx >= d.minX - tol &&
        nx <= d.maxX + tol &&
        ny >= d.minY - tol &&
        ny <= d.maxY + tol;
  }

  /// 合法摆放域的**屏幕投影**矩形（与 [_clampPanOffset] 的归一化域同源，杜绝两处定义漂移）。
  ///
  /// 【用途】窗口尺寸变化时，只收拢"真正越过合法域"的游离碎片；
  /// 因为放大后碎片可以合法地停在**当前视口之外**的域内（这正是本次修复新增的能力），
  /// 若沿用旧的"屏幕视口"判据会在每次改窗口时把玩家摆好的碎片再次拽回，问题复发。
  ({double left, double top, double right, double bottom})
  _legalDomainScreenRect() {
    final d = _legalDomain();
    final topLeft = boardTopLeft + _panOffset;
    final eff = boardSize * _zoom;
    return (
      left: topLeft.x + d.minX * eff.x,
      top: topLeft.y + d.minY * eff.y,
      right: topLeft.x + d.maxX * eff.x,
      bottom: topLeft.y + d.maxY * eff.y,
    );
  }

  /// 单一 zoom 写入入口：同步字段与对外通知，保证所有内部重置路径（窗口尺寸变化、
  /// 重开游戏）都收敛到徽标刷新，避免页面侧逐个手势点补写 notifier。
  void _setZoom(double v) {
    if (_zoom == v) return;
    _zoom = v;
    // onGameResize 在 Flame build 阶段（LayoutBuilder）调用 _syncResizeTransform，
    // 此时同步写 ValueNotifier 会触发 "setState() called during build" 断言（debug 红屏）。
    // idle 阶段（手势路径）同步通知无感知延迟；非 idle 阶段推迟到帧末。
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      zoomNotifier.value = v;
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        zoomNotifier.value = _zoom;
      });
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

    _setZoom(newZoom);
    _panOffset.setFrom(newTopLeft - boardTopLeft);
    _clampPanOffset();

    _updateBoardTransform();
    AppLogger.game.fine(
      'zoomAt focal=${focalPoint.x.toStringAsFixed(1)},${focalPoint.y.toStringAsFixed(1)} delta=$deltaScale zoom $oldZoom->$newZoom pan=$_panOffset',
    );
  }

  /// Sets zoom and pan directly (e.g. from pinch-to-zoom).
  void setZoomAndPan(double newZoom, Vector2 newPan) {
    final oldZoom = _zoom;
    _setZoom(newZoom.clamp(1.0, _maxZoom));
    _panOffset.setFrom(newPan);
    _clampPanOffset();
    _updateBoardTransform();
    AppLogger.game.fine('setZoomAndPan $oldZoom->$newZoom pan=$newPan');
  }

  /// Pans the board by [delta].
  void panBy(Vector2 delta) {
    if (_zoom <= 1.0) return;
    _panOffset.add(delta);
    _clampPanOffset();
    _updateBoardTransform();
    AppLogger.game.fine(
      'panBy delta=${delta.x.toStringAsFixed(1)},${delta.y.toStringAsFixed(1)} pan=$_panOffset zoom=$_zoom',
    );
  }

  /// Resets zoom to 1.0 and centers the board.
  void resetZoom() {
    AppLogger.game.info('resetZoom from $_zoom pan=$_panOffset');
    _setZoom(1);
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
      if (comp == null || (!isTabletop && comp.isInTray) || comp.isDragging) {
        continue;
      }

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
    AppLogger.game.info('resetCurrentGame rows=$rows cols=$cols seed=$seed');
    cancelHoldingPiece();
    cancelAllPieceDragging();
    _holdingPiece = null;

    _tabletopScatterSlots = null;
    _isSolved = false;
    _borderFilterActive = false;
    _setZoom(1);
    _panOffset.setZero();
    _trayScrollX = 0.0;
    undoManager.clear();

    _boardGhostOpacity = 0.0;
    _boardGhostComp.opacity = 0.0;
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
    // [方案B] 桌面散落模式：重置后同样按约束分配散落槽位（新洗牌顺序）
    if (isTabletop) {
      _scatterAssignmentCache = _buildScatterAssignment(
        pieceIds: _trayOrder,
        slots: _getTabletopScatterSlots(totalPieces),
      );
    }
    final normOut = [0.0, 0.0];
    final initialPieces = <PieceState>[];
    var trayIndex = 0;

    for (final id in _trayOrder) {
      final r = id ~/ cols;
      final c = id % cols;
      final pPos = isTabletop
          ? _getScatterPositionForPieceId(id)
          : _getTrayPositionForIndex(trayIndex);
      _screenToNormalized(pPos, normOut);

      final pState = PieceState(
        id: id,
        r: r,
        c: c,
        nx: normOut[0],
        ny: normOut[1],
        clusterId: id,
      );
      initialPieces.add(pState);

      final comp = _pieces[id];
      if (comp != null) {
        comp.clearActiveEffects();
        comp
          ..isDragging = false
          ..isInTray = !isTabletop
          ..hideBorders = false
          ..isFilteredOut = false
          ..clusterId = id
          ..rot = 0;
        comp.scale.setAll(isTabletop ? _zoom : _trayPieceScale);
        comp.position.setFrom(pPos);
        comp.priority = isTabletop
            ? _boardUnsolvedPriority
            : _trayPiecePriority;
        comp.isLocked = false;
      }
      trayIndex++;
    }

    _boardState = _boardState.copyWith(pieces: initialPieces);
    _realignTrayPieces();
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
  void updatePiecesStateAndPriorities({bool triggerGlow = false}) {
    // [连通规则] 计算“已就位装配体（连通到边缘）”的碎片集合，仅这些碎片允许锁定不可移动。
    final planted = PuzzleEngine.computePlantedPieceIds(_boardState);
    // [一致性] 锁定所用的“吸附就位”判定与 resolveSnap 完全相同（到槽位的欧氏距离 ≤ 当前吸附阈值）。
    // 原用 isSolved（逐轴 0.035），与欧氏吸附阈值不一致，导致“锁定了却没被吸过去、没绿框、视觉没贴边”
    // 的状态/视觉脱节。统一后：锁定 ⟺ 真正被吸附就位，且锁定时强制对齐到槽位。
    final snapDistLock = effectiveSnapDistance();
    for (final pState in _boardState.pieces) {
      final comp = _pieces[pState.id];
      if (comp == null) continue;

      if (comp.isDragging || comp == _holdingPiece) {
        comp.priority = _topPriority;
        comp.isLocked = false;
        continue;
      }

      // [连通规则] 仅当“邻槽位欧氏距离在吸附阈值内 且 属于边缘长出装配体”时才锁定。
      final snappedDist = Point(
        pState.nx,
        pState.ny,
      ).distanceTo(Point(pState.targetNx(cols), pState.targetNy(rows)));
      final isPieceSolved =
          planted.contains(pState.id) && snappedDist <= snapDistLock;
      final wasLocked = comp.isLocked;
      if (isPieceSolved) {
        comp.isLocked = true;
        comp
          ..priority = _solvedPiecePriority
          ..isInTray = false;
        comp.scale.setAll(_zoom);
        // [一致性] 锁定即强制把视觉对齐到正确槽位，确保“锁定 ⟺ 已吸到槽位”。
        comp.position.setFrom(_normalizedToScreen(pState.nx, pState.ny));
        if (!wasLocked && triggerGlow) {
          comp.triggerSnapGlow(); // 仅显式请求时补绿框（避免读档恢复误闪）
        }
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
    if (piece.isLocked || _isSolved) {
      AppLogger.game.fine(
        'dragStart blocked piece=${piece.id} locked=${piece.isLocked} solved=$_isSolved',
      );
      return;
    }

    _topPriority += 2;

    for (final p in _pieces.values) {
      if (p.clusterId == piece.clusterId) {
        p.priority = _topPriority;
        p.clearActiveEffects();
      }
    }
    AppLogger.game.fine(
      'dragStart piece=${piece.id} cluster=${piece.clusterId} topPriority=$_topPriority',
    );
  }

  /// 取消当前所有碎片的拖拽状态，平滑恢复其原有位置
  void cancelAllPieceDragging() {
    _holdingPiece = null;
    for (final p in _pieces.values) {
      if (p.isDragging) {
        cancelPieceDrag(p);
      }
    }
  }

  /// 取消指定碎片集群的拖拽并恢复原位
  void cancelPieceDrag(PuzzlePieceComponent piece) {
    if (_holdingPiece == piece) {
      _holdingPiece = null;
    }
    piece.isDragging = false;
    final clusterPieces = _pieces.values
        .where((p) => p.clusterId == piece.clusterId)
        .toList();

    // 检查集群在被拖拽前的状态：若集群包含多块碎片或任一碎片在棋盘上，则集群整体归位于棋盘（严禁拆解集群）
    final isMultiCluster = clusterPieces.length > 1;
    final primaryState = _boardState.pieceById(piece.id);
    final isPrimaryOnBoard = _isNormalizedOnBoard(
      primaryState.nx,
      primaryState.ny,
    );
    final shouldStayOnBoard = isTabletop || isMultiCluster || isPrimaryOnBoard;

    for (final p in clusterPieces) {
      p.isDragging = false;
      p.clearActiveEffects();
      final statePiece = _boardState.pieceById(p.id);

      if (shouldStayOnBoard) {
        p.isInTray = false;
        p.scale.setAll(_zoom);
        final targetPos = _normalizedToScreen(statePiece.nx, statePiece.ny);
        p.animateTo(targetPos);
      } else {
        p.isInTray = true;
        p.scale.setAll(_trayPieceScale);
      }
    }
    if (!isTabletop) {
      _realignTrayPieces();
    }
    updatePieceVisibility();
    updatePiecesStateAndPriorities();
  }

  /// 吸附结算共用管线（H3 重构：消除 dragEnd / hint 两处逐行重复）。
  ///
  /// [handlePieceDragEnd] 与 hint 在各自算出 [BoardTransitionResult] 后，都要执行
  /// 完全相同的五段收尾：**同步 clusterId/rot → 动画受影响的碎片 → 刷新可见性与
  /// 托盘状态 → 派发四个回调 → 胜负判定**。此前这两段各自复制了一份（约 90 行），
  /// 任何一侧漏改都会造成「吸附判定与动画/回调静默分叉」，是全项目维护风险最高的
  /// 重复块。现收敛到本方法，两侧只传差异参数。
  ///
  /// 差异参数（唯一真正不同的地方）：
  /// - [animateDuration]：dragEnd 用默认（null），hint 用 0.25s 平滑归位；
  /// - [affectedPieceIds]：affectedPieceIds 为空时的兜底动画目标（hint 需兜底到提示片）；
  /// - [affectsTopPriority]：hint 需显式提升层级（`_topPriority += 2`）确保提示片置顶；
  /// - [logTag]：日志区分来源（dragEnd / hint）。
  ///
  /// 调用方负责：设置 `_boardState`、`undoManager.record`、以及 play(Sfx.snap)
  /// （hint 的音效时机与 undo 语义不同，不并入本方法）。
  void _applySnapSettlement({
    required BoardTransitionResult result,
    required List<int> affectedPieceIds,
    required String logTag,
    double? animateDuration,
    bool affectsTopPriority = false,
  }) {
    final finalAffectedIds = affectedPieceIds.isNotEmpty
        ? affectedPieceIds
        : const <int>[];

    if (affectsTopPriority) {
      _topPriority += 2;
    }

    // 全量同步 clusterId / rot：确保级联合并后的状态一致
    for (final p in _boardState.pieces) {
      final comp = _pieces[p.id];
      if (comp != null) {
        comp.clusterId = p.clusterId;
        comp.rot = p.rot;
      }
    }

    for (final affectedId in finalAffectedIds) {
      final statePiece = _boardState.pieceById(affectedId);
      final comp = _pieces[affectedId];
      if (comp == null) continue; // 防御：跳过 _pieces 中不存在的碎片
      if (affectsTopPriority) comp.priority = _topPriority;
      comp.isInTray = false;
      comp.scale.setFrom(Vector2.all(_zoom));
      comp.clusterId = statePiece.clusterId;
      comp.rot = statePiece.rot;
      final targetScreenPos = _normalizedToScreen(
        statePiece.nx,
        statePiece.ny,
      );
      if (animateDuration == null) {
        comp.animateTo(targetScreenPos);
      } else {
        comp.animateTo(targetScreenPos, duration: animateDuration);
      }
      comp.triggerSnapGlow();
    }

    updatePieceVisibility();
    updatePiecesStateAndPriorities();
    _checkEdgeCompleteAutoDismiss();
    missingPieceCheck();

    onPieceSnapped?.call();
    onProgressChanged?.call(solvedCount);
    onStateUpdated?.call();

    if ((result.isCompleted || _boardState.isSolved) && !_isSolved) {
      _isSolved = true;
      AppLogger.game.info(
        '$logTag solved! pieces=$totalPieces solved=$solvedCount trigger onSolved',
      );
      onSolved();
    }
  }

  /// Called when user releases drag. Executes snap resolution & cluster merge.
  void handlePieceDragEnd(PuzzlePieceComponent piece) {
    final inTrayArea = piece.position.y >= trayPosition.y - pieceSize.y * 0.25;
    final clusterPieces = _pieces.values
        .where((p) => p.clusterId == piece.clusterId)
        .toList();
    AppLogger.game.info(
      'dragEnd piece=${piece.id} cluster=${piece.clusterId} size=${clusterPieces.length} inTrayArea=$inTrayArea pos=${piece.position.x.toStringAsFixed(1)},${piece.position.y.toStringAsFixed(1)} isTabletop=$isTabletop',
    );

    // 1. 如果拖回托盘区域且为单块碎片 -> 就近插入托盘槽位并平滑吸附就位，不触发棋盘吸附
    if (!isTabletop && inTrayArea && clusterPieces.length == 1) {
      _insertPieceIntoTrayAt(piece, piece.position.x);
      piece.isInTray = true;
      piece.animateScaleTo(Vector2.all(_trayPieceScale));
      updatePieceVisibility();
      updatePiecesStateAndPriorities();
      onStateUpdated?.call();
      AppLogger.game.fine('dragEnd inserted to tray piece=${piece.id}');
      return;
    }

    // 2. 如果留在棋盘区域（或者是由多块拼好的集群留在棋盘）
    for (final p in clusterPieces) {
      p.isInTray = false;
    }

    // 防御性二次限位：与拖拽期共用同一入口 [_clampDragTarget]（保证"主片中心在安全区内"），
    // 仅用于防御手势被系统中断等边缘路径；正常拖拽时此处已是空操作。
    // 旧实现此处重复了一遍"整簇包围盒 clamp"公式，在放大后会把碎片组强行拽回/钉死。
    final anchorCursor = Vector2(
      piece.position.x + _holdingAnchorX * piece.size.x * piece.scale.x,
      piece.position.y + _holdingAnchorY * piece.size.y * piece.scale.y,
    );
    final clampedTarget = _clampDragTarget(
      cursorCanvasPos: anchorCursor,
      pieceSizeRef: piece.size,
      scale: piece.scale.x,
      anchorX: _holdingAnchorX,
      anchorY: _holdingAnchorY,
    );

    final dx = clampedTarget.x - piece.position.x;
    final dy = clampedTarget.y - piece.position.y;

    if (dx.abs() > 1e-6 || dy.abs() > 1e-6) {
      piece.position.setValues(clampedTarget.x, clampedTarget.y);
      for (final p in clusterPieces) {
        if (p != piece) {
          p.position.add(Vector2(dx, dy));
        }
      }
    }

    // 棋盘上所有非托盘碎片的 ID 集合
    final onBoardPieceIds = _pieces.values
        .where((p) => !p.isInTray)
        .map((p) => p.id)
        .toSet();

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
      return p.copyWith(clusterId: comp.clusterId, rot: comp.rot);
    }).toList();

    _boardState = _boardState.copyWith(pieces: updatedPieces);

    final prevState = _boardState;
    AppLogger.game.fine(
      'dragEnd resolveSnap entry piece=${piece.id} onBoard=${onBoardPieceIds.length}',
    );
    final result = PuzzleEngine.resolveSnap(
      state: _boardState,
      draggedPieceId: piece.id,
      onBoardPieceIds: onBoardPieceIds,
      customSnapDistance: effectiveSnapDistance(),
    );
    AppLogger.game.info(
      'dragEnd resolveSnap result piece=${piece.id} didSnap=${result.didSnap} didMerge=${result.didMerge} completed=${result.isCompleted} solved=${result.state.isSolved} affected=${result.affectedPieceIds.length}',
    );

    if (result.didSnap ||
        result.didMerge ||
        result.isCompleted ||
        _boardState.isSolved) {
      // 音效前置：在重计算之前立即入队平台通道调用，避免同步逻辑阻塞导致超时丢音
      SoundService.I.play(Sfx.snap);
      _boardState = result.state;
      undoManager.record(prevState);

      // 共用结算管线（H3：与 hint 消除 90 行重复）
      _applySnapSettlement(
        result: result,
        affectedPieceIds: result.affectedPieceIds,
        logTag: 'dragEnd',
      );
    } else {
      // 未吸附 -> 轻落位音 + 保持棋盘当前 _zoom 尺寸
      SoundService.I.play(Sfx.place);
      for (final p in clusterPieces) {
        p.isInTray = false;
        p.animateScaleTo(Vector2.all(_zoom));
      }
      updatePieceVisibility();
      updatePiecesStateAndPriorities();
      onStateUpdated?.call();
      AppLogger.game.fine(
        'dragEnd no snap piece=${piece.id} cluster=${piece.clusterId}',
      );
    }
  }

  /// 根据当前边缘筛选状态 [_borderFilterActive]，更新所有碎片的可见性并重排托盘
  void updatePieceVisibility({bool animateTray = true}) {
    // 边缘筛选：预计算"含边缘或已归位碎片"的集群集合，避免对每片 O(n) 全量扫描
    final borderOrSolvedClusters = <int>{};
    if (_borderFilterActive) {
      for (final o in _pieces.values) {
        if (edgeLayout.edgesFor(o.r, o.c).isBorder ||
            _boardState.pieceById(o.id).isSolved(rows, cols)) {
          borderOrSolvedClusters.add(o.clusterId);
        }
      }
    }
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
        final clusterHasBorderOrSolved = borderOrSolvedClusters.contains(
          p.clusterId,
        );
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
      final minScroll = min(
        0.0,
        traySize.x - contentWidth,
      );
      _trayScrollX = _trayScrollX.clamp(minScroll, 0.0);
      _realignTrayPieces(animate: animateTray);
    }
  }

  /// 检查外边缘是否全部归位闭环：若已拼完外框且当前处于边缘筛选模式，自动合拢并淡入复原内部碎片
  void _checkEdgeCompleteAutoDismiss() {
    if (!_borderFilterActive) return;
    if (_boardState.isEdgeComplete) {
      _borderFilterActive = false;
      updatePieceVisibility();
      onStateUpdated?.call();
    }
  }

  /// Toggles border pieces filter (only shows border pieces when active).
  void toggleBorderFilter() {
    _borderFilterActive = !_borderFilterActive;
    AppLogger.game.info('toggleBorderFilter active=$_borderFilterActive');
    updatePieceVisibility();
    onStateUpdated?.call();
  }

  /// 视口越界收拢（Domain Clamp & Pullback）：
  /// 检查全场所有不在托盘内、未锁定的游离单片与多片拼合集群，
  /// 若超出当前模式的屏幕安全可视区域（托盘模式避让顶部栏与托盘；桌面模式避让全屏四周），
  /// 按外接包围盒整体原子平移拉回到安全可视区域内（绝不拆散拼合集群）。
  void _pullbackOutOfBoundsClustersAndPieces({bool animate = false}) {
    const safeLeft = _sideMargin;
    final safeRight = max(safeLeft, size.x - _sideMargin);
    const safeTop = _topToolbarHeight;
    final safeBottom = max(
      safeTop,
      isTabletop ? size.y - _bottomTrayMargin : trayPosition.y - 8.0,
    );

    // 收集全场不在托盘中、未被锁定的碎片，按 clusterId 分组
    final clusters = <int, List<PuzzlePieceComponent>>{};
    for (final comp in _pieces.values) {
      if (comp.isInTray ||
          comp.isLocked ||
          comp.isDragging ||
          comp == _holdingPiece) {
        continue;
      }
      clusters.putIfAbsent(comp.clusterId, () => []).add(comp);
    }

    final normOut = [0.0, 0.0];
    final updatedPiecesMap = <int, PieceState>{};

    for (final cluster in clusters.values) {
      if (cluster.isEmpty) continue;

      var minX = double.infinity;
      var maxX = -double.infinity;
      var minY = double.infinity;
      var maxY = -double.infinity;

      for (final comp in cluster) {
        final w = comp.size.x * comp.scale.x;
        final h = comp.size.y * comp.scale.y;
        minX = min(minX, comp.position.x);
        maxX = max(maxX, comp.position.x + w);
        minY = min(minY, comp.position.y);
        maxY = max(maxY, comp.position.y + h);
      }

      var shiftX = 0.0;
      var shiftY = 0.0;

      final clusterW = maxX - minX;
      final viewW = safeRight - safeLeft;
      if (clusterW <= viewW) {
        if (minX < safeLeft) {
          shiftX = safeLeft - minX;
        } else if (maxX > safeRight) {
          shiftX = safeRight - maxX;
        }
      } else {
        // 超大集群：保证至少有 48px 在可视区内可供抓取
        if (maxX < safeLeft + 48.0) {
          shiftX = (safeLeft + 48.0) - maxX;
        } else if (minX > safeRight - 48.0) {
          shiftX = (safeRight - 48.0) - minX;
        }
      }

      final clusterH = maxY - minY;
      final viewH = safeBottom - safeTop;
      if (clusterH <= viewH) {
        if (minY < safeTop) {
          shiftY = safeTop - minY;
        } else if (maxY > safeBottom) {
          shiftY = safeBottom - maxY;
        }
      } else {
        if (maxY < safeTop + 48.0) {
          shiftY = (safeTop + 48.0) - maxY;
        } else if (minY > safeBottom - 48.0) {
          shiftY = (safeBottom - 48.0) - minY;
        }
      }

      if (shiftX.abs() > 1e-4 || shiftY.abs() > 1e-4) {
        final shift = Vector2(shiftX, shiftY);
        for (final comp in cluster) {
          final target = comp.position + shift;
          if (animate) {
            comp.animateTo(target, duration: 0.25);
          } else {
            comp.position.setFrom(target);
          }
          _screenToNormalized(target, normOut);
          final pState = _boardState.pieceById(comp.id);
          updatedPiecesMap[comp.id] = pState.copyWith(
            nx: normOut[0],
            ny: normOut[1],
          );
        }
      }
    }

    if (updatedPiecesMap.isNotEmpty) {
      final newPieces = _boardState.pieces.map((p) {
        return updatedPiecesMap[p.id] ?? p;
      }).toList();
      _boardState = _boardState.copyWith(pieces: newPieces);
    }
  }

  /// Organizes all unlinked/unplaced floating pieces cleanly back into the tray or scattered table.
  void organizeTray() {
    AppLogger.game.info(
      'organizeTray isTabletop=$isTabletop solved=$solvedCount zoom=${_zoom.toStringAsFixed(2)} pan=$_panOffset board=${boardSize.x.toStringAsFixed(1)}x${boardSize.y.toStringAsFixed(1)}',
    );
    if (isTabletop) {
      if (_zoom > 1.0) {
        resetZoom();
      }
      final slots = _getTabletopScatterSlots(totalPieces);
      // [方案B] 先收集本次需要重新散落的游离单片，再约束分配槽位（不污染初始分配缓存）
      final scatterIds = <int>[];
      for (final p in _pieces.values) {
        final statePiece = _boardState.pieceById(p.id);
        final isSolved = statePiece.isSolved(rows, cols);
        final clusterSize = _pieces.values
            .where((o) => o.clusterId == p.clusterId)
            .length;
        if (!isSolved && clusterSize == 1) scatterIds.add(p.id);
      }
      final assignment = _buildScatterAssignment(
        pieceIds: scatterIds,
        slots: slots,
      );
      final updatedPieces = <PieceState>[];

      for (final p in _pieces.values) {
        final statePiece = _boardState.pieceById(p.id);
        final isSolved = statePiece.isSolved(rows, cols);
        final clusterSize = _pieces.values
            .where((o) => o.clusterId == p.clusterId)
            .length;
        if (!isSolved && clusterSize == 1) {
          final slotPos = slots[assignment[p.id]];
          // slotPos 是基于基准未缩放棋盘 (1.0x) 的世界槽位
          final baseNx = (slotPos.x - boardTopLeft.x) / boardSize.x;
          final baseNy = (slotPos.y - boardTopLeft.y) / boardSize.y;

          p.isInTray = false;
          p.scale.setAll(_zoom);
          final targetPos = _normalizedToScreen(baseNx, baseNy);
          p.animateTo(targetPos, duration: 0.25);
          updatedPieces.add(statePiece.copyWith(nx: baseNx, ny: baseNy));
        } else {
          updatedPieces.add(statePiece);
        }
      }
      _boardState = _boardState.copyWith(pieces: updatedPieces);
      // 扫把收拢越界的多片拼合集群
      _pullbackOutOfBoundsClustersAndPieces(animate: true);
      updatePieceVisibility();
      updatePiecesStateAndPriorities();
      onStateUpdated?.call();
      return;
    }

    // 托盘模式下：
    // 1. 全量扫描所有碎片，未吸附的游离单片（!isSolved && clusterSize == 1）无论此前在棋盘还是托盘全部收回托盘
    final singlePiecesToTray = <PuzzlePieceComponent>[];
    for (final p in _pieces.values) {
      final statePiece = _boardState.pieceById(p.id);
      final isSolved = statePiece.isSolved(rows, cols);
      final clusterSize = _pieces.values
          .where((o) => o.clusterId == p.clusterId)
          .length;
      if (!isSolved && clusterSize == 1) {
        singlePiecesToTray.add(p);
      }
    }

    // 重建 _trayOrder：保留原托盘中仍为未拼单片的相对顺序，并追加新收回的单片
    final singlePieceIds = singlePiecesToTray.map((p) => p.id).toSet();
    final newTrayOrder = _trayOrder.where(singlePieceIds.contains).toList();
    for (final p in singlePiecesToTray) {
      if (!newTrayOrder.contains(p.id)) {
        newTrayOrder.add(p.id);
      }
    }
    _trayOrder = newTrayOrder;

    _trayScrollX = 0.0;
    final normOut = [0.0, 0.0];
    final updatedPiecesMap = <int, PieceState>{};
    var idx = 0;

    for (final id in _trayOrder) {
      final p = _pieces[id];
      if (p == null) continue;
      final statePiece = _boardState.pieceById(p.id);

      p.isInTray = true;
      p.clearActiveEffects();
      p.animateScaleTo(Vector2.all(_trayPieceScale), duration: 0.25);

      final targetPos = _getTrayPositionForIndex(idx);
      p.animateTo(targetPos, duration: 0.25);
      _screenToNormalized(targetPos, normOut);
      updatedPiecesMap[p.id] = statePiece.copyWith(
        nx: normOut[0],
        ny: normOut[1],
      );
      idx++;
    }

    if (updatedPiecesMap.isNotEmpty) {
      final newPieces = _boardState.pieces.map((p) {
        return updatedPiecesMap[p.id] ?? p;
      }).toList();
      _boardState = _boardState.copyWith(pieces: newPieces);
    }

    // 2. 对留在棋盘上的多片拼合集群（clusterSize > 1），执行视口越界安全拉回！
    _pullbackOutOfBoundsClustersAndPieces(animate: true);

    updatePieceVisibility();
    updatePiecesStateAndPriorities();
    onStateUpdated?.call();
  }

  /// Serializes current board state into Snapshot JSON string.
  String exportSnapshotJson({int? elapsedSeconds}) {
    final out = [0.0, 0.0];
    final updated = _boardState.pieces.map((p) {
      final comp = _pieces[p.id];
      if (comp != null) {
        // 若组件正在被拖拽，保留原权威状态坐标，避免将拖拽中途临时位置写入存档
        if (comp.isDragging || comp == _holdingPiece) {
          return p;
        }
        // 若已锁定就位，直接使用理论精确槽位坐标
        if (comp.isLocked) {
          return p.copyWith(
            nx: p.c / cols,
            ny: p.r / rows,
            clusterId: comp.clusterId,
            rot: comp.rot,
          );
        }
        _screenToNormalized(comp.position, out);
        return p.copyWith(
          nx: out[0],
          ny: out[1],
          clusterId: comp.clusterId,
          rot: comp.rot,
        );
      }
      return p;
    }).toList();
    return jsonEncode(
      _boardState
          .copyWith(
            pieces: updated,
            elapsedSeconds: elapsedSeconds ?? _boardState.elapsedSeconds,
            extra: {
              ..._boardState.extra,
              'scatterMode': isTabletop ? 'tabletop' : 'tray',
            },
          )
          .toJson(),
    );
  }

  /// Restores previous snapshot from undo history.
  void undo() {
    cancelHoldingPiece();
    cancelAllPieceDragging();
    final prev = undoManager.undo(_boardState);
    if (prev != null) {
      _applyBoardState(prev);
      onStateUpdated?.call();
    }
  }

  /// Restores next snapshot from redo history.
  void redo() {
    cancelHoldingPiece();
    cancelAllPieceDragging();
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
      AppLogger.game.warning(
        'Snapshot apply skipped due to size mismatch: snapshot ${newState.rows}x${newState.cols} len=${newState.pieces.length} vs game $rows x $cols len=${_pieces.length} dkey=${newState.difficultyKey} canonical=${newState.canonicalId}',
      );
      return;
    }

    // 1. 检测是否为旧存档（未记录 scatterMode）或发生了模式切换（桌面 ⟷ 托盘）
    final currentMode = isTabletop ? 'tabletop' : 'tray';
    final savedMode = newState.extra['scatterMode'] as String?;
    // 旧存档或模式切换时，直接将所有未吸附/未拼合的游离单片按当前模式初始化归位（相当于自动执行一次扫把整理）
    final needsRealign = savedMode == null || savedMode != currentMode;
    if (needsRealign) {
      AppLogger.game.info(
        'Snapshot realign savedMode=${savedMode ?? '(none)'} currentMode=$currentMode dkey=${newState.difficultyKey} canonical=${newState.canonicalId}',
      );
    }

    // 2. 统计所有 cluster 尺寸，保全已拼合多片组合
    final clusterSizes = <int, int>{};
    for (final p in newState.pieces) {
      clusterSizes[p.clusterId] = (clusterSizes[p.clusterId] ?? 0) + 1;
    }

    final updatedPiecesMap = <int, PieceState>{};
    final normOut = [0.0, 0.0];

    if (isTabletop) {
      // 当前为桌面模式：
      // 无论快照来自何种模式，全场所有碎片均属于桌面系统，严禁标记 isInTray = true，统一缩放为 _zoom
      final slots = _getTabletopScatterSlots(totalPieces);
      // [方案B] 旧存档/模式切换需重散落的游离单片：先收集再约束分配槽位
      final scatterIds = <int>[];
      if (needsRealign) {
        for (final p in newState.pieces) {
          final isSolved = p.isSolved(rows, cols);
          final inMultiCluster = (clusterSizes[p.clusterId] ?? 1) > 1;
          if (!isSolved && !inMultiCluster) scatterIds.add(p.id);
        }
      }
      final assignment = _buildScatterAssignment(
        pieceIds: scatterIds,
        slots: slots,
      );

      for (final p in newState.pieces) {
        final comp = _pieces[p.id];
        if (comp == null) continue;
        comp.clusterId = p.clusterId;
        comp
          ..rot = p.rot
          ..isInTray = false;
        comp.scale.setAll(_zoom);
        comp.clearActiveEffects();

        final isSolved = p.isSolved(rows, cols);
        final inMultiCluster = (clusterSizes[p.clusterId] ?? 1) > 1;
        // 核心资产保全：已吸附归位碎片、已拼合多片集群
        final isAdsorbedOrClustered = isSolved || inMultiCluster;

        if (needsRealign && !isAdsorbedOrClustered) {
          // 旧存档或模式切换：未吸附游离单片直接初始化归位到桌面四周槽位（相当于自动扫把）
          final slotPos = slots[assignment[p.id]];
          final baseNx = (slotPos.x - boardTopLeft.x) / boardSize.x;
          final baseNy = (slotPos.y - boardTopLeft.y) / boardSize.y;
          final targetScreenPos = _normalizedToScreen(baseNx, baseNy);
          comp.position.setFrom(targetScreenPos);
          updatedPiecesMap[p.id] = p.copyWith(nx: baseNx, ny: baseNy);
        } else {
          // 正常同模式继续，或已归位/拼合碎片：精准保留原坐标
          final targetScreenPos = _normalizedToScreen(p.nx, p.ny);
          comp.position.setFrom(targetScreenPos);
          updatedPiecesMap[p.id] = p;
        }
      }
    } else {
      // 当前为托盘模式：
      // 已归位碎片、多片拼合集群、放置在棋盘上的单片保留在棋盘上；其余游离单片归入托盘
      final trayPieces = <PieceState>[];

      for (final p in newState.pieces) {
        final comp = _pieces[p.id];
        if (comp == null) continue;
        comp.clusterId = p.clusterId;
        comp
          ..rot = p.rot
          ..clearActiveEffects();

        final isSolved = p.isSolved(rows, cols);
        final inMultiCluster = (clusterSizes[p.clusterId] ?? 1) > 1;
        final isAdsorbedOrClustered = isSolved || inMultiCluster;

        // 同模式继续时若单片原本放置在棋盘有效范围内，保持在棋盘上
        final isLegacyOnBoardSingle =
            !needsRealign && _isNormalizedOnBoard(p.nx, p.ny);

        if (isAdsorbedOrClustered || isLegacyOnBoardSingle) {
          comp.isInTray = false;
          comp.scale.setAll(_zoom);
          final targetScreenPos = _normalizedToScreen(p.nx, p.ny);
          comp.position.setFrom(targetScreenPos);
          updatedPiecesMap[p.id] = p;
        } else {
          comp.isInTray = true;
          comp.scale.setAll(_trayPieceScale);
          trayPieces.add(p);
        }
      }

      // 维护托盘顺序
      final traySet = trayPieces.map((p) => p.id).toSet();
      final orderedTrayIds = _trayOrder.where(traySet.contains).toList();
      for (final p in trayPieces) {
        if (!orderedTrayIds.contains(p.id)) {
          orderedTrayIds.add(p.id);
        }
      }
      _trayOrder = orderedTrayIds;

      var trayIdx = 0;
      for (final id in _trayOrder) {
        final p = newState.pieceById(id);
        final comp = _pieces[id];
        // 关键修复：托盘内碎片严格根据 _getTrayPositionForIndex 排布
        // 绝不使用 _normalizedToScreen（避免因棋盘世界矩阵在视口/缩放变动后把托盘碎片甩出屏幕）
        final targetPos = _getTrayPositionForIndex(trayIdx);
        comp?.position.setFrom(targetPos);
        _screenToNormalized(targetPos, normOut);
        updatedPiecesMap[id] = p.copyWith(nx: normOut[0], ny: normOut[1]);
        trayIdx++;
      }
    }

    // 严格保全快照中的原始碎片排序（与 piece.id 及洗牌状态一致）
    final updatedPieces = newState.pieces
        .map((p) => updatedPiecesMap[p.id] ?? p)
        .toList();

    _boardState = newState.copyWith(
      pieces: updatedPieces,
      extra: {...newState.extra, 'scatterMode': currentMode},
    );

    // 关键修复：恢复快照后，统一执行视口越界安全收拢（Domain Clamp & Pullback），
    // 确保任何因跨模式切换、分辨率改变或视口变动导致卡在屏幕边缘/托盘背后的拼合集群或棋盘碎片，
    // 均被完整原子平移拉回到安全可视区域！
    _pullbackOutOfBoundsClustersAndPieces();

    updatePieceVisibility(animateTray: false);
    updatePiecesStateAndPriorities();
    _checkEdgeCompleteAutoDismiss();
    onProgressChanged?.call(solvedCount);
    onStateUpdated?.call();

    final wasSolved = _isSolved;
    _isSolved = _boardState.isSolved;
    if (_isSolved && !wasSolved) {
      onSolved();
    }
  }

  /// Automatically snaps one unsolved piece into place.
  void hint() {
    cancelHoldingPiece();
    cancelAllPieceDragging();

    final hint = PuzzleEngine.hintFor(_boardState);
    final targetPieceId = hint.pieceId;
    final targetComp = _pieces[targetPieceId];
    if (targetComp == null) {
      AppLogger.game.warning(
        'hint skipped: target comp missing pieceId=$targetPieceId',
      );
      return;
    }
    AppLogger.game.info('hint used pieceId=$targetPieceId');

    final prevState = _boardState;
    final updated = _boardState.pieces.map((p) {
      if (p.id == targetPieceId) {
        return p.copyWith(nx: hint.targetNx, ny: hint.targetNy, rot: 0);
      }
      return p;
    }).toList();

    _boardState = _boardState.copyWith(
      pieces: updated,
      hintsUsed: _boardState.hintsUsed + 1,
    );

    final onBoardPieceIds = _pieces.values
        .where((p) => !p.isInTray && !p.isFilteredOut)
        .map((p) => p.id)
        .toSet();
    onBoardPieceIds.add(targetPieceId);

    final result = PuzzleEngine.resolveSnap(
      state: _boardState,
      draggedPieceId: targetPieceId,
      onBoardPieceIds: onBoardPieceIds,
      customSnapDistance: effectiveSnapDistance(),
    );

    _boardState = result.state;
    undoManager.record(prevState.copyWith(hintsUsed: _boardState.hintsUsed));

    // 音效前置：在重计算之前立即入队平台通道调用，避免同步逻辑阻塞导致超时丢音
    SoundService.I.play(Sfx.snap);

    // 共用结算管线（H3：与 handlePieceDragEnd 消除 90 行重复）。
    // diff：0.25s 平滑归位 + 层级提升 + 空结果兜底动画提示片。
    _applySnapSettlement(
      result: result,
      affectedPieceIds: result.affectedPieceIds.isNotEmpty
          ? result.affectedPieceIds
          : [targetPieceId],
      animateDuration: 0.25,
      affectsTopPriority: true,
      logTag: 'hint',
    );
  }

  /// “失踪碎片”防丢自检与自愈机制：
  /// 当整幅拼图剩余未拼碎片 <= 2 块时，若检测到未归位碎片因平移/缩放被甩出可视视口，
  /// 自动将其平滑弹回屏幕可视区域，彻底解决“找不到最后一块碎片”的挫败体验。
  void missingPieceCheck() {
    if (_isSolved) return;
    final unsolved = _boardState.pieces
        .where((p) => !p.isSolved(rows, cols))
        .toList();
    if (unsolved.isEmpty || unsolved.length > 2) return;

    final holdingClusterId = _holdingPiece?.clusterId;

    for (final pState in unsolved) {
      final comp = _pieces[pState.id];
      if (comp == null ||
          comp.isDragging ||
          comp == _holdingPiece ||
          (!isTabletop && comp.isInTray)) {
        continue;
      }
      if (holdingClusterId != null && comp.clusterId == holdingClusterId) {
        continue;
      }

      final visualW = comp.size.x * comp.scale.x;
      final visualH = comp.size.y * comp.scale.y;
      final isOutOfBounds =
          comp.position.x < -visualW * 0.5 ||
          comp.position.x > size.x - visualW * 0.5 ||
          comp.position.y < -visualH * 0.5 ||
          comp.position.y > size.y - visualH * 0.5;

      if (isOutOfBounds) {
        // 就近落在视口内的"完整可见"位置（保留 44px 顶部操作栏避让），
        // 而不是无条件搬到屏幕正中——避免玩家刚刚推到视野边的碎片被瞬移回中央。
        final horizontalLimit = max(
          _sideMargin,
          size.x - _sideMargin - visualW,
        );
        final verticalLimit = max(
          44.0,
          (isTabletop ? size.y : trayPosition.y) - _sideMargin - visualH,
        );
        final safeTarget = Vector2(
          comp.position.x.clamp(_sideMargin, horizontalLimit),
          comp.position.y.clamp(44.0, verticalLimit),
        );
        comp.position.setFrom(safeTarget);
        comp.triggerSnapGlow();
        final normOut = [0.0, 0.0];
        _screenToNormalized(safeTarget, normOut);
        _boardState = _boardState.copyWith(
          pieces: _boardState.pieces
              .map(
                (p) => p.id == pState.id
                    ? p.copyWith(nx: normOut[0], ny: normOut[1])
                    : p,
              )
              .toList(),
        );
      }
    }
  }
}
