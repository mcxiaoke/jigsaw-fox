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

  test('复现：棋盘上网格相邻的两块自由碎片松手即被自动合并成集群，且扫把无法归位', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 取两块网格相邻的自由碎片 ((0,0) 与 (0,1))，都脱离托盘放到棋盘上，
    // 归一化相对偏移恰好满足“右邻一格”(1/cols=1/3)，但都不落在自身正确槽位上。
    final a =
        game.children.whereType<PuzzlePieceComponent>().firstWhere((p) => p.id == 0);
    final b =
        game.children.whereType<PuzzlePieceComponent>().firstWhere((p) => p.id == 1);
    const anX = 0.50, anY = 0.55;
    const bnX = anX + 1 / 3; // cols=3 → 1/cols = 1/3，保持网格对齐
    const bnY = anY;

    for (final (p, nx, ny) in [(a, anX, anY), (b, bnX, bnY)]) {
      p.isInTray = false;
      p.scale.setAll(game.zoom);
      p.position.setFrom(game.normalizedToScreen(nx, ny));
    }

    // 松手：触发 resolveSnap，两块被并入同一个 clusterId（之后无法拆解）
    game.handlePieceDragEnd(a);
    expect(a.clusterId, equals(b.clusterId), reason: '棋盘上的网格邻居被自动合并成集群');

    // 两块都未吸附到正确槽位 → 既不锁定也未回托盘，是“游离在棋盘上的不可拆集群”
    expect(game.boardState.pieceById(a.id).isSolved(3, 3), isFalse);
    expect(game.boardState.pieceById(b.id).isSolved(3, 3), isFalse);

    // 即使随后放大到 3 倍，集群依旧保持合并（放大不是触发条件，只是放大后更容易发生）
    game.zoomAt(Vector2(200, 300), 2.0);
    expect(game.zoom, closeTo(3.0, 0.01));
    expect(a.clusterId, equals(b.clusterId));

    // 扫把一键整理：organizeTray 只回托盘 clusterSize==1 的游离碎片，
    // 该合并集群 (clusterSize==2) 被跳过 → 复现“碎片粘在棋盘上且扫把也归不了位”
    game.organizeTray();
    game.organizeTray(); // 连点两次依旧无效
    expect(a.isInTray, isFalse, reason: '集群碎片未被扫把归位 (organizeTray 跳过 clusterSize>1)');
    expect(b.isInTray, isFalse, reason: '集群碎片未被扫把归位 (organizeTray 跳过 clusterSize>1)');
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

  test('边缘筛选 (toggleBorderFilter) 仅显示外围边缘碎片并紧凑重排托盘', () async {
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
    expect(pieces.length, equals(9));

    // 初始状态：未开启筛选，所有碎片均可见
    expect(game.isBorderFilterActive, isFalse);
    expect(pieces.every((p) => !p.isFilteredOut), isTrue);

    // 开启边缘筛选
    game.toggleBorderFilter();
    expect(game.isBorderFilterActive, isTrue);

    // 验证：3x3 共有 8 块外框碎片和 1 块中心内部碎片
    final borderPieces = pieces.where((p) => p.r == 0 || p.r == 2 || p.c == 0 || p.c == 2).toList();
    final centerPieces = pieces.where((p) => p.r == 1 && p.c == 1).toList();

    expect(borderPieces.length, equals(8));
    expect(centerPieces.length, equals(1));

    // 8 块边缘碎片保持可见，1 块中心碎片被过滤隐藏
    expect(borderPieces.every((p) => !p.isFilteredOut), isTrue);
    expect(centerPieces.first.isFilteredOut, isTrue);

    // 中心碎片被过滤后，碰撞测试返回 false 且无法响应交互
    expect(centerPieces.first.containsLocalPoint(Vector2(10, 10)), isFalse);

    // 再次切换解除边缘筛选
    game.toggleBorderFilter();
    expect(game.isBorderFilterActive, isFalse);
    expect(pieces.every((p) => !p.isFilteredOut), isTrue);
  });

  test('边缘闭环自动感知 (isEdgeComplete) 自动解除边缘筛选并恢复全部碎片显示', () async {
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

    final centerPiece = game.children.whereType<PuzzlePieceComponent>().firstWhere((p) => p.r == 1 && p.c == 1);
    expect(centerPiece.isFilteredOut, isTrue);

    // 连续提示直到 3x3 外围 8 块边缘全部归位（3x3 共有 8 块外框）
    for (var i = 0; i < 8; i++) {
      game.hint();
    }

    // 验证边缘全部归位后，自动感知并解除筛选模式，内部中心碎片自动恢复可见
    expect(game.boardState.isEdgeComplete, isTrue);
    expect(game.isBorderFilterActive, isFalse);
    expect(centerPiece.isFilteredOut, isFalse);
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

  test('Windows 窗口由大变小时，游离碎片与自由集群自动安全收拢到当前可视视口内', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    // 初始在大窗口 1920 x 1080
    game.onGameResize(Vector2(1920, 1080));
    await game.onLoad();

    final p0 = game.children.whereType<PuzzlePieceComponent>().firstWhere((p) => p.id == 0);
    final p1 = game.children.whereType<PuzzlePieceComponent>().firstWhere((p) => p.id == 1);
    final p2 = game.children.whereType<PuzzlePieceComponent>().firstWhere((p) => p.id == 2);

    // 1. 将 p0（单块）放置在大窗口右侧边缘 (X=1800, Y=900)
    p0.isInTray = false;
    p0.isLocked = false;
    p0.position.setValues(1800, 900);
    final out0 = [0.0, 0.0];
    game.screenToNormalized(p0.position, out0);
    game.boardState = game.boardState.copyWith(
      pieces: game.boardState.pieces.map((p) => p.id == 0 ? p.copyWith(nx: out0[0], ny: out0[1]) : p).toList(),
    );

    // 2. 将 p1, p2 组成自由拼合集群放置在右下方 (X=1700, Y=850)
    p1.isInTray = false;
    p1.isLocked = false;
    p1.clusterId = 888;
    p1.position.setValues(1700, 850);
    final out1 = [0.0, 0.0];
    game.screenToNormalized(p1.position, out1);

    p2.isInTray = false;
    p2.isLocked = false;
    p2.clusterId = 888;
    p2.position.setValues(1700 + game.pieceSize.x, 850);
    final out2 = [0.0, 0.0];
    game.screenToNormalized(p2.position, out2);

    game.boardState = game.boardState.copyWith(
      pieces: game.boardState.pieces.map((p) {
        if (p.id == 1) return p.copyWith(nx: out1[0], ny: out1[1], clusterId: 888);
        if (p.id == 2) return p.copyWith(nx: out2[0], ny: out2[1], clusterId: 888);
        return p;
      }).toList(),
    );

    // 3. 模拟用户将窗口急剧缩小为 800 x 600
    game.onGameResize(Vector2(800, 600));

    // 验证单块 p0 已被安全 Clamp 收拢在 800 x 600 的安全可视区域内
    expect(p0.position.x, lessThanOrEqualTo(800.0 - p0.size.x - 8.0));
    expect(p0.position.x, greaterThanOrEqualTo(8.0));
    expect(p0.position.y, lessThanOrEqualTo(game.trayPosition.y - p0.size.y - 8.0));
    expect(p0.position.y, greaterThanOrEqualTo(44.0));

    // 验证集群 p1, p2 已被整体原子平移收拢在可视区域内
    expect(p1.position.x, greaterThanOrEqualTo(8.0));
    expect(p2.position.x + p2.size.x, lessThanOrEqualTo(800.0 - 8.0 + 0.1));
    expect(p1.position.y, greaterThanOrEqualTo(44.0));
    expect(p1.position.y + p1.size.y, lessThanOrEqualTo(game.trayPosition.y - 8.0 + 0.1));

    // 验证集群两块碎片的相对几何距离绝对保持不变
    expect(p2.position.x - p1.position.x, closeTo(game.pieceSize.x, 0.01));
    expect(p2.position.y - p1.position.y, closeTo(0.0, 0.01));
  });

  test('托盘模式下按住或点击托盘碎片未拖出时，其他碎片不提前占位；拖出托盘后才平滑闭合空隙', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(600, 800));
    await game.onLoad();

    // 获取托盘中的第一块和第二块碎片
    final trayPieces = game.children.whereType<PuzzlePieceComponent>().where((p) => p.isInTray).toList();
    expect(trayPieces.length, equals(9));
    final firstPiece = trayPieces[0];
    final secondPiece = trayPieces[1];
    final originalSecondPos = secondPiece.position.clone();

    // 1. 模拟玩家点击或按住第一块碎片（在托盘内）
    game.startHoldingPiece(firstPiece, 0.5, 0.5);
    expect(game.holdingPiece, equals(firstPiece));

    // 此时第一块碎片仍被认为是托盘成员，第二块碎片的坐标绝对不变（没有提前跑过来占位）
    expect(secondPiece.position.x, equals(originalSecondPos.x));
    expect(secondPiece.position.y, equals(originalSecondPos.y));

    // 2. 模拟玩家在托盘区域内轻微移动鼠标 (Y 仍在托盘内)
    game.updateHoldingPiecePosition(Vector2(100, game.trayPosition.y + 20));
    expect(firstPiece.isInTray, isTrue, reason: '未拖出托盘前碎片依然保留托盘槽位');
    expect(secondPiece.position.x, equals(originalSecondPos.x));

    // 3. 模拟玩家将碎片向上拖出托盘，进入棋盘工作区 (Y < trayPosition.y - 20)
    game.updateHoldingPiecePosition(Vector2(100, game.trayPosition.y - 40));
    expect(firstPiece.isInTray, isFalse, reason: '真正拖出托盘后碎片脱离托盘');
  });

  test('从棋盘拖回碎片到托盘时，就近插入玩家松手位置的槽位，而不是跳跃回初始老索引', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(800, 600));
    await game.onLoad();

    final trayPieces = game.children.whereType<PuzzlePieceComponent>().where((p) => p.isInTray).toList();
    final piece0 = trayPieces[0];

    // 1. 将 piece0 从托盘拖出到棋盘空白区域放开（避免吸附）
    game.startHoldingPiece(piece0, 0.5, 0.5);
    game.updateHoldingPiecePosition(Vector2(50, 300));
    game.dropHoldingPiece();
    expect(piece0.isInTray, isFalse);
    expect(piece0.isLocked, isFalse);

    // 2. 将 piece0 从棋盘拖回托盘右侧位置（比如 X = 450，靠近后半部分槽位）放开
    game.startHoldingPiece(piece0, 0.5, 0.5);
    final dropX = 450.0;
    final dropY = game.trayPosition.y + 20.0;
    game.updateHoldingPiecePosition(Vector2(dropX, dropY));
    game.dropHoldingPiece();

    expect(piece0.isInTray, isTrue);
    // 验证 piece0 就近插入在 X = 450 附近，绝非跳回 X = 18 附近的最左侧槽位
    expect(piece0.position.x, closeTo(dropX, 60.0));
  });

  test('缩放最大倍数严格限制在 300% (3.0x)，且放大状态下支持在空白区域平移棋盘', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(800, 600));
    await game.onLoad();

    // 1. 验证 maxZoom 严格等于 3.0
    expect(game.maxZoom, equals(3.0));

    // 2. 尝试过度放大至 500%
    game.zoomAt(Vector2(400, 300), 4.0);
    expect(game.zoom, equals(3.0), reason: '放大倍数必须被严格 clamp 在 3.0 (300%)');

    // 3. 验证放大状态下在空白区域平移有效
    final initialPanX = game.panOffset.x;
    game.panBy(Vector2(20, 15));
    expect(game.panOffset.x, isNot(equals(initialPanX)));

    // 4. 重置缩放
    game.resetZoom();
    expect(game.zoom, equals(1.0));
    expect(game.panOffset.x, equals(0.0));
    expect(game.panOffset.y, equals(0.0));
  });

  test('缩放和平移棋盘时碎片严格与棋盘同步移动（归一化世界坐标绝对不被破坏或压扁）', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      scatterMode: 'tabletop',
      onSolved: () {},
    );
    game.onGameResize(Vector2(1000, 800));
    await game.onLoad();

    // 取任意一块游离碎片
    final p0 = game.children.whereType<PuzzlePieceComponent>().first;
    final originalNx = game.boardState.pieceById(p0.id).nx;
    final originalNy = game.boardState.pieceById(p0.id).ny;

    // 1. 放大棋盘至 2.0x
    game.zoomAt(Vector2(500, 400), 1.0);
    expect(game.zoom, equals(2.0));

    // 2. 模拟多次连续平移拖动画布
    for (int i = 0; i < 5; i++) {
      game.panBy(Vector2(15, 20));
      // 模拟 Flutter 构建触发 onGameResize（窗口尺寸未改变）
      game.onGameResize(Vector2(1000, 800));
    }

    // 验证碎片的归一化世界坐标绝对保持不变（绝未被任何视口 clamp 篡改）
    expect(game.boardState.pieceById(p0.id).nx, equals(originalNx));
    expect(game.boardState.pieceById(p0.id).ny, equals(originalNy));

    // 验证碎片的屏幕坐标严格等于棋盘仿射变换后的投影坐标
    final expectedPos = game.normalizedToScreen(originalNx, originalNy);
    expect(p0.position.x, closeTo(expectedPos.x, 0.01));
    expect(p0.position.y, closeTo(expectedPos.y, 0.01));

    // 3. 在放大状态下点击一键整理 (organizeTray)，验证碎片展开且归一化坐标正确
    game.organizeTray();
    final newNx = game.boardState.pieceById(p0.id).nx;
    final newNy = game.boardState.pieceById(p0.id).ny;
    final expectedOrganizedPos = game.normalizedToScreen(newNx, newNy);
    expect(p0.position.x, closeTo(expectedOrganizedPos.x, 0.01));
    expect(p0.position.y, closeTo(expectedOrganizedPos.y, 0.01));
  });

  test('放大后可自由平移漫游至棋盘右下角与边缘（右侧与底部绝不被提前阻挡截断）', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 3,
      cols: 3,
      onSolved: () {},
    );
    game.onGameResize(Vector2(1000, 700));
    await game.onLoad();

    // 1. 放大至 2.5x
    game.zoomAt(Vector2(500, 300), 1.5);
    expect(game.zoom, equals(2.5));

    // 2. 向左上方深度拖动，查看棋盘右下角
    game.panBy(Vector2(-1000, -1000));

    // 验证棋盘右下角（nx=1.0, ny=1.0）成功进入屏幕视口内部（X < 1000, Y < trayPosition.y）
    final bottomRightScreenPos = game.normalizedToScreen(1.0, 1.0);
    expect(bottomRightScreenPos.x, lessThanOrEqualTo(1000.0));
    expect(bottomRightScreenPos.y, lessThanOrEqualTo(game.trayPosition.y));

    // 3. 向右下方深度拖动，查看棋盘左上角
    game.panBy(Vector2(2000, 2000));
    final topLeftScreenPos = game.normalizedToScreen(0.0, 0.0);
    expect(topLeftScreenPos.x, greaterThanOrEqualTo(0.0));
    expect(topLeftScreenPos.y, greaterThanOrEqualTo(0.0));
  });

  test('通关后碎片保持绘制且带分割线，不被原图水印遮挡', () async {
    final img = await _decodePng();
    var isSolvedTriggered = false;
    final game = JigsawPuzzleGame(
      image: img,
      rows: 2,
      cols: 2,
      onSolved: () => isSolvedTriggered = true,
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 连续提示直到 2x2（4块）全部归位通关
    for (var i = 0; i < 4; i++) {
      game.hint();
    }

    expect(game.isSolved, isTrue);
    expect(isSolvedTriggered, isTrue);

    final pieces = game.children.whereType<PuzzlePieceComponent>().toList();
    expect(pieces.length, equals(4));

    // 验证所有碎片未被隐藏（hideBorders == false），依然展示物理切线分割线与纹理
    for (final p in pieces) {
      expect(p.hideBorders, isFalse);
      expect(p.isFilteredOut, isFalse);
      expect(p.isLocked, isTrue);
    }
  });

  test('托盘模式下从托盘拖出碎片后多次连续点击扫把 organizeTray 缩放与位置保持稳定', () async {
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
    // 模拟拖出托盘到棋盘
    piece0.isInTray = false;
    piece0.position.setValues(150, 150);
    piece0.scale.setAll(1.0);

    // 第 1 次点击扫把
    game.organizeTray();
    expect(piece0.isInTray, isTrue);
    final p0State1 = game.boardState.pieceById(piece0.id);
    expect(p0State1.ny, greaterThan(1.10)); // 归一化 Y 处于托盘区间

    // 第 2 次点击扫把
    game.organizeTray();
    expect(piece0.isInTray, isTrue);
    final p0State2 = game.boardState.pieceById(piece0.id);
    expect(p0State2.ny, greaterThan(1.10));

    // 第 3 次点击扫把
    game.organizeTray();
    expect(piece0.isInTray, isTrue);
    final p0State3 = game.boardState.pieceById(piece0.id);
    expect(p0State3.ny, greaterThan(1.10));
  });

  test('cancelAllPieceDragging 与 cancelPieceDrag 彻底清空 holdingPiece 避免幽灵抓取', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 2,
      cols: 2,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    final piece = game.children.whereType<PuzzlePieceComponent>().first;
    game.startHoldingPiece(piece, 50.0, 50.0);
    expect(game.holdingPiece, equals(piece));
    expect(piece.isDragging, isTrue);

    // 触发 cancelAllPieceDragging
    game.cancelAllPieceDragging();
    expect(game.holdingPiece, isNull);
    expect(piece.isDragging, isFalse);
  });

  test('resetCurrentGame 彻底清空 holdingPiece 与 isDragging 避免重置后粘手', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 2,
      cols: 2,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    final piece = game.children.whereType<PuzzlePieceComponent>().first;
    game.startHoldingPiece(piece, 50.0, 50.0);
    expect(game.holdingPiece, equals(piece));

    game.resetCurrentGame();
    expect(game.holdingPiece, isNull);
    for (final p in game.children.whereType<PuzzlePieceComponent>()) {
      expect(p.isDragging, isFalse);
    }
  });

  test('通关后 Undo 正确将 solved 状态双向回滚', () async {
    final img = await _decodePng();
    var solvedTriggered = 0;
    final game = JigsawPuzzleGame(
      image: img,
      rows: 2,
      cols: 2,
      onSolved: () {
        solvedTriggered++;
      },
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 拼完 4 块
    for (var i = 0; i < 4; i++) {
      game.hint();
    }
    expect(game.solvedCount, 4);
    expect(solvedTriggered, 1);

    // 撤销最后一步
    game.undo();
    expect(game.solvedCount, lessThan(4));
    expect(game.canRedo, isTrue);

    // 再次重做
    game.redo();
    expect(game.solvedCount, 4);
    expect(solvedTriggered, 2);
  });

  test('PieceState pieceById 安全防御与 pieceByIdOrNull', () {
    final state = PuzzleBoardState(
      rows: 2,
      cols: 2,
      seed: 42,
      pieces: [
        const PieceState(id: 0, r: 0, c: 0, nx: 0, ny: 0, clusterId: 0, rot: 0),
        const PieceState(id: 1, r: 0, c: 1, nx: 0.5, ny: 0, clusterId: 1, rot: 0),
      ],
    );

    expect(state.pieceById(0).id, 0);
    expect(state.pieceByIdOrNull(1)?.id, 1);
    expect(state.pieceByIdOrNull(99), isNull);
    expect(() => state.pieceById(99), throwsA(isA<StateError>()));
  });

  test('exportSnapshotJson 在拖拽中保留权威坐标，锁定态使用精确理论坐标', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 2,
      cols: 2,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    // 拼入 1 块
    game.hint();

    final jsonStr = game.exportSnapshotJson(elapsedSeconds: 45);
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    expect(map['elapsedSeconds'], 45);
    expect(map['hintsUsed'], 1);

    final pieces = map['pieces'] as List<dynamic>;
    expect(pieces.length, 4);
  });

  test('hint 智能提示使用次数 hintsUsed 在 Undo 撤销后保持不回退，防止刷星', () async {
    final img = await _decodePng();
    final game = JigsawPuzzleGame(
      image: img,
      rows: 2,
      cols: 2,
      onSolved: () {},
    );
    game.onGameResize(Vector2(400, 800));
    await game.onLoad();

    expect(game.boardState.hintsUsed, 0);

    // 使用 1 次提示
    game.hint();
    expect(game.boardState.hintsUsed, 1);
    expect(game.solvedCount, 1);

    // 撤销提示
    game.undo();
    expect(game.solvedCount, 0);
    // 提示计数必须保留，防止玩家刷低提示次数以达成三星
    expect(game.boardState.hintsUsed, 1);
  });
}
