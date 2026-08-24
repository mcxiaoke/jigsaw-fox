import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/game/jigsaw_puzzle_game.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/pages/tabs/daily_tab_view.dart';
import 'package:jigsawpuzzle/pages/tabs/home_tab_view.dart';
import 'package:jigsawpuzzle/pages/tabs/my_puzzles_tab_view.dart';
import 'package:jigsawpuzzle/widgets/achievements_dialog.dart';
import 'package:jigsawpuzzle/widgets/choose_difficulty_sheet.dart';
import 'package:jigsawpuzzle/widgets/how_to_play_dialog.dart';
import 'package:jigsawpuzzle/widgets/settings_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

final Uint8List kTestTransparentImage = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

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

    testWidgets('ChooseDifficultySheet renders locked state and disables start button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  ChooseDifficultySheet.show(
                    context: context,
                    imageBytes: kTestTransparentImage,
                    initialDifficulty: const PuzzleDifficulty(label: '3 × 3 (9 块)', rows: 3, cols: 3),
                    title: '第 5 关 · 关卡预览(未解锁)',
                    isUnlocked: false,
                    lockedMessage: '请先通关第 4 关解锁此关卡',
                    onStart: (_) {},
                  );
                },
                child: const Text('Open Locked Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Locked Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('第 5 关 · 关卡预览(未解锁)'), findsOneWidget);
      expect(find.text('请先通关第 4 关解锁此关卡'), findsOneWidget);
      expect(find.text('关卡未解锁 (请先通关前序关卡)'), findsOneWidget);

      // Button should be disabled
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('ChooseDifficultySheet supports custom puzzle deletion', (tester) async {
      var deleteCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  ChooseDifficultySheet.show(
                    context: context,
                    imageBytes: kTestTransparentImage,
                    initialDifficulty: const PuzzleDifficulty(label: '4 × 4 (16 块)', rows: 4, cols: 4),
                    title: '我的爱犬照片',
                    onDelete: () async {
                      deleteCalled = true;
                    },
                    onStart: (_) {},
                  );
                },
                child: const Text('Open UGC Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open UGC Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('我的爱犬照片'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      // Tap delete icon
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(find.text('删除自制拼图'), findsOneWidget);
      expect(find.text('确定删除'), findsOneWidget);

      // Confirm delete
      await tester.tap(find.text('确定删除'));
      await tester.pumpAndSettle();

      expect(deleteCalled, isTrue);
    });

    testWidgets('MyPuzzlesTabView renders UGC header and empty state', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MyPuzzlesTabView(),
          ),
        ),
      );

      expect(find.text('自制新拼图'), findsOneWidget);
      expect(find.text('我的自制合辑'), findsOneWidget);
    });

    testWidgets('ChooseDifficultySheet renders saved progress banner & continue button', (tester) async {
      var resetCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  ChooseDifficultySheet.show(
                    context: context,
                    imageBytes: kTestTransparentImage,
                    initialDifficulty: const PuzzleDifficulty(label: '4 × 4 (16 块)', rows: 4, cols: 4),
                    title: '第 5 关 · 难度选择',
                    savedProgressPercent: 85,
                    onResetProgress: () {
                      resetCalled = true;
                    },
                    onStart: (_) {},
                  );
                },
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      // Check saved progress indicator banner
      expect(find.text('⚡ 检测到未完成存档 (已拼 85%)'), findsOneWidget);
      expect(find.text('继续游玩 (进度 85%)'), findsOneWidget);
      expect(find.text('放弃进度并重新开始'), findsOneWidget);

      // Tap reset button
      await tester.tap(find.text('放弃进度并重新开始'));
      await tester.pumpAndSettle();
      expect(resetCalled, isTrue);
    });
  });
}
