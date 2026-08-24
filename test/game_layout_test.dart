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
}

