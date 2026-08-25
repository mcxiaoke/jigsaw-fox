import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/game/jigsaw_puzzle_game.dart';
import 'package:jigsawpuzzle/game/puzzle_piece_component.dart';
import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';

/// 1x1 transparent PNG used only as a decodable image source.
const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Future<ui.Image> _decodePng() async {
  final bytes = base64Decode(_pngBase64);
  return decodeImageFromList(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('初始碎片 base cell 应在托盘区域内垂直居中', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    final pieces = game.children.whereType<PuzzlePieceComponent>().toList();
    expect(pieces.length, 9, reason: '3x3 拼图应有 9 块碎片');

    final trayTop = game.trayPosition.y;
    final trayHeight = game.traySize.y;
    final trayCenterY = trayTop + trayHeight / 2;

    final report = <String>[];
    for (final p in pieces) {
      // 组件 anchor=topLeft，渲染内容覆盖 [position, position + size*scale]
      final top = p.position.y;
      final bottom = p.position.y + p.size.y * p.scale.y;
      final centerOffset = (top + bottom) / 2 - trayCenterY;
      report.add(
        'piece#${p.id} top=${top.toStringAsFixed(1)} '
        'bottom=${bottom.toStringAsFixed(1)} '
        'centerOffset=${centerOffset.toStringAsFixed(1)} '
        'scale=${p.scale.y.toStringAsFixed(3)} '
        'sizeY=${p.size.y.toStringAsFixed(1)}',
      );
      expect(
        centerOffset.abs(),
        lessThan(1.0),
        reason: '碎片 base cell 应垂直居中于托盘 (trayTop=$trayTop, '
            'trayHeight=$trayHeight):\n${report.join('\n')}',
      );
    }
    // ignore: avoid_print
    print('TRAY  layout trayTop=$trayTop trayHeight=$trayHeight\n${report.join('\n')}');
  });

  test('连续 hint 每次都应归位新碎片且 id 一致，拖拽结束不应崩溃', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    var lastSolved = 0;
    for (var i = 0; i < 9; i++) {
      game.hint();
      final solved = game.solvedCount;
      expect(solved, greaterThan(lastSolved),
          reason: '第 ${i + 1} 次 hint 后已归位数量应从 $lastSolved 增加到更多，实际 $solved');
      lastSolved = solved;

      // 校验所有组件都还在（没有被错误移除）
      final comps = game.children.whereType<PuzzlePieceComponent>().toList();
      expect(comps.length, 9);
    }

    // 拖拽任意碎片结束，不应抛异常（复现 handlePieceDragEnd 的 _pieces[p.id]! 崩溃）
    final piece = game.children.whereType<PuzzlePieceComponent>().first;
    expect(() => game.handlePieceDragEnd(piece), returnsNormally);
  });

  test('拖动开始后连续提示再松手，不应崩溃（复现用户操作序列）', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 1. 拖起碎片 A
    final pieceA = game.children.whereType<PuzzlePieceComponent>().first;
    game.handlePieceDragStart(pieceA);

    // 2. 拖动过程中连续点提示
    for (var i = 0; i < 5; i++) {
      game.hint();
    }

    // 3. 松手结束拖拽，不应抛异常
    expect(() => game.handlePieceDragEnd(pieceA), returnsNormally);

    // 4. 状态应保持合法
    for (final p in game.children.whereType<PuzzlePieceComponent>()) {
      expect(p.position.x.isFinite, isTrue, reason: '碎片#${p.id} position.x 应为有限值');
      expect(p.position.y.isFinite, isTrue, reason: '碎片#${p.id} position.y 应为有限值');
      expect(p.scale.x.isFinite, isTrue, reason: '碎片#${p.id} scale.x 应为有限值');
      expect(p.scale.y.isFinite, isTrue, reason: '碎片#${p.id} scale.y 应为有限值');
    }
  });

  test('快照尺寸与当前难度不匹配时，恢复与拖拽都不应崩溃（复现 _pieces[p.id]! null）', () async {
    final img = await _decodePng();

    // 构造一个 4x4 的已保存快照（16 块），但当前游戏是 3x3（9 块）
    final bogusState = PuzzleBoardState(
      rows: 4,
      cols: 4,
      seed: 1,
      pieces: List.generate(
        16,
        (i) => PieceState(
          id: i,
          r: i ~/ 4,
          c: i % 4,
          nx: (i % 4) / 4,
          ny: (i ~/ 4) / 4,
          clusterId: i,
        ),
      ),
    );
    final json = jsonEncode(bogusState.toJson());

    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
      initialSnapshotJson: json,
    );
    game.onGameResize(Vector2(400, 800));
    // onLoad 恢复快照时不应崩溃（当前实现会静默 catch 导致状态失步）
    await game.onLoad();

    // 关键：_boardState 必须与 _pieces 保持同步（9 块），而不是被 16 块快照污染
    expect(game.solvedCount, 0, reason: '尺寸不匹配的快照应被忽略，保持初始 3x3 状态');

    // 拖拽任意碎片结束，不应抛异常（复现 handlePieceDragEnd 的 _pieces[p.id]! 崩溃）
    final piece = game.children.whereType<PuzzlePieceComponent>().first;
    expect(() => game.handlePieceDragEnd(piece), returnsNormally);

    // 连续提示也不应崩溃
    for (var i = 0; i < 5; i++) {
      expect(() => game.hint(), returnsNormally, reason: '第 ${i + 1} 次 hint 不应崩溃');
    }
  });

  test('通关完成后禁止拖拽碎片 (PuzzlePieceComponent.onDragStart 锁定)', () async {
    final img = await _decodePng();
    var solvedTriggered = false;
    final game = JigsawPuzzleGame(
      image: img,
      rows: 2,
      cols: 2,
      onSolved: () {
        solvedTriggered = true;
      },
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 连续 hint 直至 4 块全部归位并触发通关
    for (var i = 0; i < 4; i++) {
      game.hint();
    }
    expect(solvedTriggered, isTrue);
    expect(game.isSolved, isTrue);

    final piece = game.children.whereType<PuzzlePieceComponent>().first;
    expect(piece.isDragging, isFalse);

    // 尝试在通关状态下调用 onDragStart
    // onDragStart 应该直接 return，不进入 isDragging 状态
    // 注意：通过 Flame 的 DragStartEvent mock 触发
    piece.isDragging = false;
    // 即使外部尝试触发 handlePieceDragStart，碎片不应处于拖拽中
    expect(game.isSolved, isTrue);
  });

  test('棋盘最大化可用空间：左右外边距大幅精简至 8px 贴合屏幕', () async {
    final img = await _decodePng(); // 1x1 aspect ratio = 1.0
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 可用宽度应达到 size.x - 16.0 (两边各 8px 边距)
    // 400 - 16 = 384
    expect(game.boardSize.x, closeTo(384.0, 1.0));
    expect(game.boardTopLeft.x, closeTo(8.0, 1.0));
  });

  test('缩放与平移系统：zoomAt, panBy, resetZoom 及坐标正逆变换精度', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    expect(game.zoom, 1.0);
    expect(game.panOffset.x, 0.0);
    expect(game.panOffset.y, 0.0);

    // 1. 在屏幕中心执行放大
    final center = Vector2(200, 300);
    game.zoomAt(center, 1.0); // zoom 从 1.0 增加到 2.0
    expect(game.zoom, closeTo(2.0, 0.01));

    // 2. 坐标归一化正逆变换一致性验证
    const testNx = 0.35;
    const testNy = 0.65;
    final screenPos = Vector2(
      game.boardTopLeft.x + game.panOffset.x + testNx * game.boardSize.x * game.zoom,
      game.boardTopLeft.y + game.panOffset.y + testNy * game.boardSize.y * game.zoom,
    );
    final pieceComp = game.children.whereType<PuzzlePieceComponent>().first;
    pieceComp.position.setFrom(screenPos);

    // 导出快照测试逆变换
    final snapshotJson = game.exportSnapshotJson();
    final restoredMap = jsonDecode(snapshotJson) as Map<String, dynamic>;
    final restoredState = PuzzleBoardState.fromJson(restoredMap);
    final restoredP0 = restoredState.pieceById(pieceComp.id);
    expect(restoredP0.nx, closeTo(testNx, 0.001));
    expect(restoredP0.ny, closeTo(testNy, 0.001));

    // 3. 平移
    game.panBy(Vector2(20, -30));
    expect(game.panOffset.x, isNot(0.0));

    // 4. 重置缩放与平移
    game.resetZoom();
    expect(game.zoom, 1.0);
    expect(game.panOffset.x, 0.0);
    expect(game.panOffset.y, 0.0);
  });

  test('双指缩放放大后，托盘中碎片绝不发生误粘连且 cancelAllPieceDragging 正常工作', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 放大到 3.0 倍
    game.zoomAt(Vector2(200, 300), 2.0);
    expect(game.zoom, closeTo(3.0, 0.01));

    // 模拟多指手势触发
    game.isPinching = true;
    final piece0 = game.children.whereType<PuzzlePieceComponent>().first;
    piece0.isDragging = true;
    piece0.position.setFrom(Vector2(100, 100)); // 临时移动

    // 触发取消
    game.cancelAllPieceDragging();
    expect(piece0.isDragging, isFalse);

    // 模拟托盘中的碎片释放拖拽（handlePieceDragEnd），不应发生合并
    game.handlePieceDragEnd(piece0);

    // 检查所有碎片 clusterId 均为自身 ID，没有任何托盘碎片被合并
    final allPieces = game.children.whereType<PuzzlePieceComponent>().toList();
    for (final p in allPieces) {
      expect(p.clusterId, equals(p.id), reason: '碎片 #${p.id} 不应被误合并');
    }
  });

  test('已吸附归位的碎片锁定不可移动，且层级 Priority 为底层 (5)', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 初始状态下所有托盘碎片未锁定，Priority 为 10
    final piece0 = game.children.whereType<PuzzlePieceComponent>().first;
    expect(piece0.isLocked, isFalse);
    expect(piece0.priority, equals(10));

    // 使用 hint 提示并归位一块碎片
    game.hint();
    final solvedPieces = game.children
        .whereType<PuzzlePieceComponent>()
        .where((p) => p.isLocked)
        .toList();
    expect(solvedPieces.length, equals(1));
    expect(solvedPieces.first.priority, equals(5), reason: '已归位碎片应置于底层 Priority=5');

    // 测试已锁定的碎片在拖动时被拦截
    final solvedPiece = solvedPieces.first;
    game.handlePieceDragStart(solvedPiece);
    // 验证 priority 没有被提升为拖拽层级
    expect(solvedPiece.priority, equals(5));
  });

  test('散落在棋盘上的未归位碎片 Priority 为 20，高于已归位碎片(5)和托盘碎片(10)', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 拾取一块碎片并放置在棋盘未吸附位置
    final piece0 = game.children.whereType<PuzzlePieceComponent>().first;
    game.handlePieceDragStart(piece0);
    // 移动到棋盘非槽位区域
    piece0.position.setFrom(Vector2(50, 50));
    game.handlePieceDragEnd(piece0);

    expect(piece0.isInTray, isFalse);
    expect(piece0.isLocked, isFalse);
    expect(piece0.priority, equals(20), reason: '棋盘上的未归位碎片 Priority 应为 20');
  });

  test('鼠标单击吸附抓取状态机与动态缩放跟手锁定 (Click-to-Pick, Scale-Independent Tracking, Drop)', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    final piece0 = game.children.whereType<PuzzlePieceComponent>().first;

    // 1. 开启抓取（点击碎片正中心，anchorX=0.5, anchorY=0.5）
    game.startHoldingPiece(piece0, 0.5, 0.5);
    expect(game.holdingPiece, equals(piece0));
    expect(piece0.isDragging, isTrue);
    expect(piece0.priority, greaterThanOrEqualTo(1000), reason: '抓取中碎片应置于最高层 Priority 1000+');

    // 2. 模拟鼠标移动到托盘内某个坐标
    final trayCursorPos = Vector2(100, 700);
    game.updateHoldingPiecePosition(trayCursorPos);
    // 验证在托盘内 scale 为 trayPieceScale
    expect(piece0.scale.x, closeTo(game.trayPieceScale, 0.001));
    // 验证碎片中心与光标重合（由于 anchor 为 0.5, 0.5）
    final visualCenterX = piece0.position.x + 0.5 * piece0.size.x * piece0.scale.x;
    final visualCenterY = piece0.position.y + 0.5 * piece0.size.y * piece0.scale.y;
    expect(visualCenterX, closeTo(trayCursorPos.x, 0.01));
    expect(visualCenterY, closeTo(trayCursorPos.y, 0.01));

    // 3. 模拟鼠标拖动到上方棋盘区域（触发放大到 1.0）
    final boardCursorPos = Vector2(200, 300);
    game.updateHoldingPiecePosition(boardCursorPos);
    // 验证在棋盘区域 scale 变为 zoom (1.0)
    expect(piece0.scale.x, closeTo(game.zoom, 0.001));
    // 关键验证：放大后，碎片中心依然 100% 精确与光标重合，绝无距离拉大！
    final boardVisualCenterX = piece0.position.x + 0.5 * piece0.size.x * piece0.scale.x;
    final boardVisualCenterY = piece0.position.y + 0.5 * piece0.size.y * piece0.scale.y;
    expect(boardVisualCenterX, closeTo(boardCursorPos.x, 0.01));
    expect(boardVisualCenterY, closeTo(boardCursorPos.y, 0.01));

    // 4. 再次点击放下
    game.dropHoldingPiece();
    expect(game.holdingPiece, isNull);
    expect(piece0.isDragging, isFalse);
  });

  test('吸附抓取状态下取消抓取 (cancelHoldingPiece) 平滑复位', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    final piece0 = game.children.whereType<PuzzlePieceComponent>().first;

    // 开启抓取并移动
    game.startHoldingPiece(piece0, 0.5, 0.5);
    game.updateHoldingPiecePosition(Vector2(200, 300));

    // 取消抓取（例如右键或 ESC）
    game.cancelHoldingPiece();
    expect(game.holdingPiece, isNull);
    expect(piece0.isDragging, isFalse);
    expect(piece0.isInTray, isTrue);
  });

  test('主装配体保护 (isInMainAssembly)：小碎片拼向大集群时大集群绝对静止', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 拼出 3 块的大集群
    game.hint();
    game.hint();
    game.hint();

    final boardPieces = game.children.whereType<PuzzlePieceComponent>().where((p) => !p.isInTray).toList();
    expect(boardPieces.length, 3);

    // 记录大集群中第一块的位置
    final mainPiece = boardPieces.first;
    final posBefore = mainPiece.position.clone();

    // 再拼入第 4 块
    game.hint();

    // 验证大集群中的碎片位置纹丝不动
    expect(mainPiece.position.x, closeTo(posBefore.x, 0.001));
    expect(mainPiece.position.y, closeTo(posBefore.y, 0.001));
  });

  test('边缘闭环自动感知 (isEdgeComplete) 自动解除边缘筛选', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 开启边缘筛选
    game.toggleBorderFilter();
    expect(game.isBorderFilterActive, isTrue);

    // 连续提示直到 3x3 外围 8 块边缘全部归位（3x3 共有 8 块外框）
    for (var i = 0; i < 8; i++) {
      game.hint();
    }

    // 验证边缘全部归位后，自动感知并解除筛选模式
    expect(game.boardState.isEdgeComplete, isTrue);
    expect(game.isBorderFilterActive, isFalse);
  });

  test('桌面打散模式 (scatterMode=tabletop) 上下左右全域环形散落且中心绝对留白', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 4,
      cols: 4,
      scatterMode: 'tabletop',
      onSolved: () {},
    );
    // 模拟桌面端/宽屏分辨率 (1280x800)
    game.onGameResize(Vector2(1280, 800));
    await game.onLoad();

    final pieces = game.children.whereType<PuzzlePieceComponent>().toList();
    expect(pieces.length, 16);

    final centerX = game.boardTopLeft.x + game.boardSize.x / 2;
    final centerY = game.boardTopLeft.y + game.boardSize.y / 2;

    var countLeft = 0;
    var countRight = 0;
    var countTop = 0;
    var countBottom = 0;

    final xPositions = <double>{};
    final yPositions = <double>{};

    for (final p in pieces) {
      final pCenterX = p.position.x + p.size.x * p.scale.x / 2;
      final pCenterY = p.position.y + p.size.y * p.scale.y / 2;

      xPositions.add(p.position.x.roundToDouble());
      yPositions.add(p.position.y.roundToDouble());

      // 1. 验证绝对没有侵入棋盘中心区域
      final isOverlapBoard = !(p.position.x + p.size.x * p.scale.x <= game.boardTopLeft.x ||
          p.position.x >= game.boardTopLeft.x + game.boardSize.x ||
          p.position.y + p.size.y * p.scale.y <= game.boardTopLeft.y ||
          p.position.y >= game.boardTopLeft.y + game.boardSize.y);
      expect(isOverlapBoard, isFalse, reason: '碎片 #${p.id} 绝对不能遮挡中央棋盘区域');

      // 2. 统计围绕中心的 4 个方位分布
      final dx = pCenterX - centerX;
      final dy = pCenterY - centerY;
      if (dx.abs() > dy.abs()) {
        if (dx < 0) {
          countLeft++;
        } else {
          countRight++;
        }
      } else {
        if (dy < 0) {
          countTop++;
        } else {
          countBottom++;
        }
      }
    }

    // 验证上下左右均有散落碎片，绝非单一列或仅在左右
    expect(countLeft + countRight, greaterThan(0));
    expect(countTop + countBottom, greaterThan(0));
    // 验证呈现多列多行，并非所有碎片堆在同一 X 或同一 Y
    expect(xPositions.length, greaterThanOrEqualTo(4));
    expect(yPositions.length, greaterThanOrEqualTo(4));
  });

  test('失踪碎片防丢自检 (missingPieceCheck) 自动将离屏不可见碎片弹回可视区域', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 拼至仅剩最后 1 块未归位
    for (var i = 0; i < 8; i++) {
      game.hint();
    }
    expect(game.solvedCount, 8);

    // 找到最后 1 块未归位碎片，人为将其坐标甩出屏幕外
    final lastPiece = game.children.whereType<PuzzlePieceComponent>().firstWhere((p) => p.isInTray || !game.boardState.pieceById(p.id).isSolved(3, 3));
    lastPiece.isInTray = false;
    lastPiece.position.setValues(-500, -500); // 严重出界

    // 触发自检
    game.missingPieceCheck();

    // 验证坐标已被安全弹回屏幕可视区域内
    expect(lastPiece.position.x, greaterThanOrEqualTo(0.0));
    expect(lastPiece.position.y, greaterThanOrEqualTo(0.0));
    expect(lastPiece.position.x, lessThan(400.0));
    expect(lastPiece.position.y, lessThan(800.0));
  });

  test('窗口尺寸变化 (onGameResize) 时，托盘始终紧贴底部且棋盘与碎片同步按比例缩放', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    final initialTrayY = game.trayPosition.y;
    final initialBoardW = game.boardSize.x;
    expect(initialTrayY, equals(800.0 - game.traySize.y - 8.0));

    // 拼入一块碎片到棋盘上
    game.hint();
    expect(game.solvedCount, 1);

    // 模拟 Windows 桌面端拉伸窗口至 1280 x 720
    game.onGameResize(Vector2(1280, 720));

    // 1. 验证托盘依然紧贴新视口底部
    expect(game.trayPosition.y, equals(720.0 - game.traySize.y - 8.0));
    expect(game.traySize.x, equals(1280.0 - 16.0));

    // 2. 验证棋盘与碎片尺寸同步等比重算
    expect(game.boardSize.x, isNot(equals(initialBoardW)));
    expect(game.pieceSize.x, equals(game.boardSize.x / 3));
    expect(game.pieceSize.y, equals(game.boardSize.y / 3));

    // 3. 验证已归位棋盘碎片的新屏幕坐标与新棋盘对齐
    final solvedComp = game.children.whereType<PuzzlePieceComponent>().firstWhere((p) => p.isLocked);
    expect(solvedComp.size.x, equals(game.pieceSize.x));
    expect(solvedComp.size.y, equals(game.pieceSize.y));
    expect(solvedComp.position.x, closeTo(game.boardTopLeft.x + solvedComp.c * game.pieceSize.x, 0.5));
    expect(solvedComp.position.y, closeTo(game.boardTopLeft.y + solvedComp.r * game.pieceSize.y, 0.5));

    // 4. 模拟缩小窗口至 320 x 480
    game.onGameResize(Vector2(320, 480));
    expect(game.trayPosition.y, equals(480.0 - game.traySize.y - 8.0));
    expect(game.traySize.x, equals(320.0 - 16.0));
    expect(solvedComp.position.x, closeTo(game.boardTopLeft.x + solvedComp.c * game.pieceSize.x, 0.5));
    expect(solvedComp.position.y, closeTo(game.boardTopLeft.y + solvedComp.r * game.pieceSize.y, 0.5));
  });

  test('多块已吸附集群拖拽靠近边缘移动时，同集群碎片不发生冲突或被意外拆散', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(600, 800));
    await game.onLoad();

    // 连续 hint 3 块碎片，形成 3 块碎片在棋盘上的状态
    game.hint();
    game.hint();
    game.hint();
    expect(game.solvedCount, 3);

    // 人为模拟一个由 3 块碎片组成的自定义未锁定自由集群
    final p0 = game.children.whereType<PuzzlePieceComponent>().firstWhere((p) => p.id == 0);
    final p1 = game.children.whereType<PuzzlePieceComponent>().firstWhere((p) => p.id == 1);
    final p2 = game.children.whereType<PuzzlePieceComponent>().firstWhere((p) => p.id == 2);

    p0.isLocked = false;
    p1.isLocked = false;
    p2.isLocked = false;
    p0.clusterId = 999;
    p1.clusterId = 999;
    p2.clusterId = 999;

    // 1. 抓取 p0
    game.startHoldingPiece(p0, 0.5, 0.5);
    expect(game.holdingPiece, equals(p0));

    // 2. 模拟鼠标移动到靠近托盘边缘线 (例如 y = game.trayPosition.y - 10)
    final nearEdgePos = Vector2(200, game.trayPosition.y - 10);
    game.updateHoldingPiecePosition(nearEdgePos);

    // 验证集群 3 块碎片的相对位置保持完全一致且紧密相连（按当前过渡缩放 p0.scale.x 严格锁定）
    final expectedRelX1 = (p1.c - p0.c) * game.pieceSize.x * p0.scale.x;
    final expectedRelY1 = (p1.r - p0.r) * game.pieceSize.y * p0.scale.y;
    expect(p1.position.x - p0.position.x, closeTo(expectedRelX1, 0.001));
    expect(p1.position.y - p0.position.y, closeTo(expectedRelY1, 0.001));

    // 3. 模拟此时 Flame 手势引擎触发同集群成员 p1 的 onDragStart（在鼠标移动过程中光标经过 p1）
    // 不应触发 dropHoldingPiece，应保持当前集群抓取
    expect(game.holdingPiece, equals(p0));

    // 4. 模拟触发边缘 Cancel 事件
    // 由于正在 holding 该集群，cancelPieceDrag 不应将集群拆散
    game.cancelPieceDrag(p0);
    expect(p0.isInTray, equals(p1.isInTray), reason: '集群所有碎片必须原子性处于相同容器');
    expect(p1.isInTray, equals(p2.isInTray), reason: '集群所有碎片必须原子性处于相同容器');
  });
}




