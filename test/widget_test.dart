import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flame/game.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/models/level_item.dart';
import 'package:jigsawpuzzle/game/jigsaw_puzzle_game.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/pages/game_page.dart';
import 'package:jigsawpuzzle/widgets/choose_background_sheet.dart';
import 'package:jigsawpuzzle/widgets/choose_difficulty_sheet.dart';
import 'package:jigsawpuzzle/widgets/victory_dialog.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

void main() {
  testWidgets('GamePage builds properly with top bar actions and canvas', (
    tester,
  ) async {
    final kTransparentImage = Uint8List.fromList([
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0A,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9C,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0D,
      0x0A,
      0x2D,
      0xB4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: GamePage(
          imageBytes: kTransparentImage,
          difficulty: PuzzleDifficulty.presets.first,
          levelIndex: 1,
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // 验证 AppBar 上的 6 个操作图标存在
    expect(find.byIcon(PhosphorIconsBold.cornersOut), findsOneWidget);
    expect(find.byIcon(PhosphorIconsFill.lightbulb), findsOneWidget);
    expect(find.byIcon(PhosphorIconsBold.stack), findsOneWidget);
    expect(find.byIcon(PhosphorIconsBold.eye), findsOneWidget);
    expect(find.byIcon(PhosphorIconsBold.broom), findsOneWidget);
    expect(find.byIcon(PhosphorIconsBold.image), findsOneWidget);

    // 验证进度条与 GameWidget 正常挂载在树中
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(GameWidget<JigsawPuzzleGame>), findsOneWidget);
  });

  test('difficulty preset configuration', () {
    expect(PuzzleDifficulty.presets.first.pieceCount, 24);
    expect(PuzzleDifficulty.presets.last.pieceCount, 400);
  });

  test(
    'PuzzleAspectRatio detects standard image ratios correctly using crop loss',
    () {
      // 1:1
      expect(
        PuzzleAspectRatio.fromSize(1000, 1000),
        PuzzleAspectRatio.square1x1,
      );
      expect(
        PuzzleAspectRatio.fromSize(1024, 1024),
        PuzzleAspectRatio.square1x1,
      );

      // 2:3 (Portrait)
      expect(
        PuzzleAspectRatio.fromSize(800, 1200),
        PuzzleAspectRatio.portrait2x3,
      );
      expect(
        PuzzleAspectRatio.fromSize(960, 1440),
        PuzzleAspectRatio.portrait2x3,
      );

      // 3:2 (Landscape)
      expect(
        PuzzleAspectRatio.fromSize(1200, 800),
        PuzzleAspectRatio.landscape3x2,
      );
      expect(
        PuzzleAspectRatio.fromSize(1440, 960),
        PuzzleAspectRatio.landscape3x2,
      );

      // 3:4 (Portrait) -> closest crop is 2:3
      expect(
        PuzzleAspectRatio.fromSize(900, 1200),
        PuzzleAspectRatio.portrait2x3,
      );
      expect(
        PuzzleAspectRatio.fromSize(1080, 1440),
        PuzzleAspectRatio.portrait2x3,
      );

      // 4:3 (Landscape) -> closest crop is 3:2
      expect(
        PuzzleAspectRatio.fromSize(1200, 900),
        PuzzleAspectRatio.landscape3x2,
      );
      expect(
        PuzzleAspectRatio.fromSize(1440, 1080),
        PuzzleAspectRatio.landscape3x2,
      );
    },
  );

  test(
    'Every difficulty tier for each aspect ratio produces 100% square base cells',
    () {
      for (final aspect in PuzzleAspectRatio.values) {
        for (final tier in aspect.tiers) {
          final diff = tier.difficulty;
          // Check cols : rows == aspectCols : aspectRows
          // meaning (aspectCols / cols) == (aspectRows / rows) => pure square cell!
          final cellW = aspect.aspectCols / diff.cols;
          final cellH = aspect.aspectRows / diff.rows;
          expect(
            (cellW - cellH).abs() < 1e-6,
            isTrue,
            reason:
                'Tier ${diff.label} in ${aspect.label} must have equal cell width and height, but got W=$cellW, H=$cellH',
          );
        }
      }
    },
  );

  testWidgets(
    'Victory dialog renders with finite constraints without RenderIntrinsicWidth exception',
    (tester) async {
      final kTransparentImage = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
        0x00,
        0x00,
        0x00,
        0x0A,
        0x49,
        0x44,
        0x41,
        0x54,
        0x78,
        0x9C,
        0x63,
        0x00,
        0x01,
        0x00,
        0x00,
        0x05,
        0x00,
        0x01,
        0x0D,
        0x0A,
        0x2D,
        0xB4,
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  VictoryDialog.show(
                    context: context,
                    imageBytes: kTransparentImage,
                    stars: 3,
                    elapsedSeconds: 83,
                    pieceCount: 64,
                    rewardCoins: 25,
                    onNextLevel: () {},
                    onShare: () {},
                  );
                },
                child: const Text('Open Dialog'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.text('拼图完成！'), findsOneWidget);
      expect(find.text('下一关'), findsOneWidget);
      expect(find.text('保存壁纸'), findsOneWidget);
      expect(find.text('分享成绩'), findsOneWidget);
    },
  );

  test(
    'LevelItem serialization and backward compatibility with completedPieceCounts',
    () {
      // 1. New data with explicit completedPieceCounts
      final item = LevelItem(
        id: 'level_1',
        index: 1,
        title: '第 1 关',
        assetPath: 'assets/images/sample_01.jpg',
        difficulty: const PuzzleDifficulty(
          label: '3 × 3 (9 块)',
          rows: 3,
          cols: 3,
        ),
        isUnlocked: true,
        completedPieceCounts: const [9, 16],
      );

      final json = item.toJson();
      expect(json['completedPieceCounts'], [9, 16]);
      expect(json['isCompleted'], true);

      final fromJson = LevelItem.fromJson(json);
      expect(fromJson.completedPieceCounts, [9, 16]);
      expect(fromJson.isCompleted, true);

      // 2. Legacy data without completedPieceCounts but isCompleted == true
      final legacyJson = {
        'id': 'level_2',
        'index': 2,
        'title': '第 2 关',
        'assetPath': 'assets/images/sample_02.jpg',
        'rows': 4,
        'cols': 4,
        'isUnlocked': true,
        'isCompleted': true,
        'progressPercent': 100,
      };
      final legacyItem = LevelItem.fromJson(legacyJson);
      expect(
        legacyItem.completedPieceCounts,
        [16],
        reason: 'Legacy completed item should fallback to default pieceCount',
      );
      expect(legacyItem.isCompleted, true);
    },
  );

  testWidgets(
    'ChooseDifficultySheet renders passed badge and differentiated appearance for completed difficulties',
    (tester) async {
      final kTransparentImage = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
        0x00,
        0x00,
        0x00,
        0x0A,
        0x49,
        0x44,
        0x41,
        0x54,
        0x78,
        0x9C,
        0x63,
        0x00,
        0x01,
        0x00,
        0x00,
        0x05,
        0x00,
        0x01,
        0x0D,
        0x0A,
        0x2D,
        0xB4,
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => ChooseDifficultySheet(
                      imageBytes: kTransparentImage,
                      initialDifficulty: const PuzzleDifficulty(
                        label: '6 × 6 (36 块)',
                        rows: 6,
                        cols: 6,
                      ),
                      completedPieceCounts: const {36, 64},
                      title: '第 1 关 · 难度选择',
                      onStart: (_) {},
                    ),
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

      // 1. Check title and header indicator
      expect(find.text('选择难度'), findsOneWidget);
      expect(
        find.text('已通关'),
        findsOneWidget,
      ); // Header badge for currently selected 36-piece diff
      expect(find.text('重玩此难度'), findsOneWidget);

      // 2. Check check_circle icons rendered for passed difficulties (36 and 64 + 1 header badge = at least 3 check_circle icons)
      expect(find.byIcon(PhosphorIconsFill.checkCircle), findsNWidgets(3));

      // 3. Tap on unpassed difficulty 25 (5x5)
      await tester.tap(find.text('25'));
      await tester.pumpAndSettle();

      expect(find.text('开始'), findsOneWidget); // Button switches to '开始'
    },
  );

  test('GameRepository background assets configuration and defaults', () {
    expect(GameRepository.kBackgroundAssets.first, 'assets/bg/tile_000.webp');
  });

  testWidgets(
    'ChooseBackgroundSheet displays 10 wallpaper options and invokes callback',
    (tester) async {
      String selectedBg = 'assets/bg/tile_000.webp';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  ChooseBackgroundSheet.show(
                    context: context,
                    selectedBackground: selectedBg,
                    onBackgroundSelected: (bg) {
                      selectedBg = bg;
                    },
                  );
                },
                child: const Text('Open Wallpaper Sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Wallpaper Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('更换拼图背景'), findsOneWidget);
      expect(find.text('桌板 1'), findsOneWidget);
      expect(find.text('桌板 2'), findsOneWidget);
      expect(find.text('桌板 3'), findsOneWidget);

      // Tap on Table 3
      await tester.tap(find.text('桌板 3'));
      await tester.pumpAndSettle();

      expect(selectedBg, 'assets/bg/tile_002.webp');
    },
  );
}
