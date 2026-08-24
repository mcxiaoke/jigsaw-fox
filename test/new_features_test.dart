import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/game/jigsaw_puzzle_game.dart';
import 'package:jigsawpuzzle/pages/tabs/daily_tab_view.dart';
import 'package:jigsawpuzzle/pages/tabs/home_tab_view.dart';
import 'package:jigsawpuzzle/widgets/achievements_dialog.dart';
import 'package:jigsawpuzzle/widgets/how_to_play_dialog.dart';
import 'package:jigsawpuzzle/widgets/settings_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ui.Image> createTestImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = const Color(0xFF4CAF50));
  final picture = recorder.endRecording();
  return picture.toImage(width, height);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await GameRepository.instance.init();
  });

  group('New UI/UX Features & Mechanics Tests', () {
    test('BoardGhostComponent opacity cycling and transform synchrony', () async {
      final img = await createTestImage(400, 300);
      final game = JigsawPuzzleGame(
        image: img,
        rows: 3,
        cols: 3,
        onSolved: () {},
      );

      game.onGameResize(Vector2(400, 800));
      await game.onLoad();

      expect(game.boardGhostOpacity, 0.0);

      // Cycle 1: 0.0 -> 0.20
      game.toggleGhostOpacity();
      expect(game.boardGhostOpacity, 0.20);

      // Cycle 2: 0.20 -> 0.45
      game.toggleGhostOpacity();
      expect(game.boardGhostOpacity, 0.45);

      // Cycle 3: 0.45 -> 0.0
      game.toggleGhostOpacity();
      expect(game.boardGhostOpacity, 0.0);

      // Direct set
      game.setGhostOpacity(0.35);
      expect(game.boardGhostOpacity, 0.35);
    });

    test('Undo / Redo state tracking and level reset', () async {
      final img = await createTestImage(400, 300);
      final game = JigsawPuzzleGame(
        image: img,
        rows: 3,
        cols: 3,
        onSolved: () {},
      );

      game.onGameResize(Vector2(400, 800));
      await game.onLoad();

      expect(game.canUndo, isFalse);
      expect(game.canRedo, isFalse);

      // Execute a hint to record state in undoManager
      game.hint();
      expect(game.canUndo, isTrue);

      // Undo
      game.undo();
      expect(game.canRedo, isTrue);

      // Redo
      game.redo();
      expect(game.canUndo, isTrue);

      // Reset game
      game.resetCurrentGame();
      expect(game.solvedCount, 0);
      expect(game.canUndo, isFalse);
    });

    testWidgets('HowToPlayDialog renders instructions properly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HowToPlayDialog(),
          ),
        ),
      );

      expect(find.text('玩法与操作技巧'), findsOneWidget);
      expect(find.text('拖拽与磁吸'), findsOneWidget);
      expect(find.text('双指缩放与平移'), findsOneWidget);
      expect(find.text('底图透视参考 (Ghost)'), findsOneWidget);
      expect(find.text('一键整理托盘'), findsOneWidget);
    });

    testWidgets('AchievementsDialog renders statistics and 12 badges', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AchievementsDialog(),
          ),
        ),
      );

      expect(find.text('成就与统计'), findsOneWidget);
      expect(find.text('完成局数'), findsOneWidget);
      expect(find.text('已拼碎片'), findsOneWidget);
      expect(find.text('总游玩时长'), findsOneWidget);
      expect(find.text('初入拼界'), findsOneWidget);
      expect(find.text('拼图学徒'), findsOneWidget);
      expect(find.text('拼图大师'), findsOneWidget);
    });

    testWidgets('SettingsDialog renders switches and options', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsDialog(),
          ),
        ),
      );

      expect(find.text('游戏设置'), findsOneWidget);
      expect(find.text('拼图吸附音效'), findsOneWidget);
      expect(find.text('触感震动反馈'), findsOneWidget);
      expect(find.text('选关切图网格预览'), findsOneWidget);
      expect(find.text('玩法技巧与操作指引'), findsOneWidget);
    });

    testWidgets('HomeTabView renders category filters and reacts to taps', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeTabView(onSwitchToDaily: () {}),
          ),
        ),
      );

      expect(find.text('全部关卡'), findsOneWidget);
      expect(find.text('新手 (9-16)'), findsOneWidget);
      expect(find.text('进阶 (24-36)'), findsOneWidget);
      expect(find.text('大师 (48-100+)'), findsOneWidget);

      // Tap on '新手 (9-16)' filter
      await tester.tap(find.text('新手 (9-16)'));
      await tester.pumpAndSettle();

      expect(find.text('今日推荐挑战'), findsOneWidget);
    });

    testWidgets('DailyTabView renders streak stats and header', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DailyTabView(),
          ),
        ),
      );

      expect(find.text('TODAY'), findsOneWidget);
      expect(find.textContaining('连胜'), findsOneWidget);
    });
  });
}
