import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/models/level_item.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/widgets/choose_background_sheet.dart';
import 'package:jigsawpuzzle/widgets/choose_difficulty_sheet.dart';

void main() {
  test('difficulty preset configuration', () {
    expect(PuzzleDifficulty.presets.first.pieceCount, 16);
    expect(PuzzleDifficulty.presets.last.pieceCount, 300);
  });

  test('PuzzleAspectRatio detects all 5 standard image ratios correctly', () {
    // 1:1
    expect(PuzzleAspectRatio.fromSize(1000, 1000), PuzzleAspectRatio.square1x1);
    expect(PuzzleAspectRatio.fromSize(1024, 1024), PuzzleAspectRatio.square1x1);

    // 2:3 (Portrait)
    expect(PuzzleAspectRatio.fromSize(800, 1200), PuzzleAspectRatio.portrait2x3);
    expect(PuzzleAspectRatio.fromSize(960, 1440), PuzzleAspectRatio.portrait2x3);

    // 3:2 (Landscape)
    expect(PuzzleAspectRatio.fromSize(1200, 800), PuzzleAspectRatio.landscape3x2);
    expect(PuzzleAspectRatio.fromSize(1440, 960), PuzzleAspectRatio.landscape3x2);

    // 3:4 (Portrait)
    expect(PuzzleAspectRatio.fromSize(900, 1200), PuzzleAspectRatio.portrait3x4);
    expect(PuzzleAspectRatio.fromSize(1080, 1440), PuzzleAspectRatio.portrait3x4);

    // 4:3 (Landscape)
    expect(PuzzleAspectRatio.fromSize(1200, 900), PuzzleAspectRatio.landscape4x3);
    expect(PuzzleAspectRatio.fromSize(1440, 1080), PuzzleAspectRatio.landscape4x3);
  });

  test('Every difficulty tier for each aspect ratio produces 100% square base cells', () {
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
          reason: 'Tier ${diff.label} in ${aspect.label} must have equal cell width and height, but got W=$cellW, H=$cellH',
        );
      }
    }
  });

  testWidgets('Victory dialog renders with finite constraints without RenderIntrinsicWidth exception', (tester) async {
    final kTransparentImage = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    title: const Row(
                      children: [
                        Text('🎉 ', style: TextStyle(fontSize: 24)),
                        Text('恭喜通关！', style: TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    content: SizedBox(
                      width: 300,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(
                              kTransparentImage,
                              height: 160,
                              width: 300,
                              fit: BoxFit.cover,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text('总用时：01:23', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                          const SizedBox(height: 4),
                          const Text(
                            '规格：3 × 3 (9 块)',
                            style: TextStyle(fontSize: 14, color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('查看拼图'),
                      ),
                    ],
                  ),
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

    expect(find.text('恭喜通关！'), findsOneWidget);
    expect(find.text('总用时：01:23'), findsOneWidget);
  });

  test('LevelItem serialization and backward compatibility with completedPieceCounts', () {
    // 1. New data with explicit completedPieceCounts
    final item = LevelItem(
      id: 'level_1',
      index: 1,
      title: '第 1 关',
      assetPath: 'assets/images/sample_01.jpg',
      difficulty: const PuzzleDifficulty(label: '3 × 3 (9 块)', rows: 3, cols: 3),
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
    expect(legacyItem.completedPieceCounts, [16], reason: 'Legacy completed item should fallback to default pieceCount');
    expect(legacyItem.isCompleted, true);
  });

  testWidgets('ChooseDifficultySheet renders passed badge and differentiated appearance for completed difficulties', (tester) async {
    final kTransparentImage = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
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
                    initialDifficulty: const PuzzleDifficulty(label: '4 × 4 (16 块)', rows: 4, cols: 4),
                    completedPieceCounts: const {16, 36},
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
    expect(find.text('第 1 关 · 难度选择'), findsOneWidget);
    expect(find.text('已通关'), findsOneWidget); // Header badge for currently selected 16-piece diff
    expect(find.text('重玩此难度'), findsOneWidget);

    // 2. Check check_circle icons rendered for passed difficulties (16 and 36 + 1 header badge = at least 3 check_circle icons)
    expect(find.byIcon(Icons.check_circle), findsNWidgets(3));

    // 3. Tap on unpassed difficulty 25 (5x5)
    await tester.tap(find.text('25'));
    await tester.pumpAndSettle();

    expect(find.text('开始'), findsOneWidget); // Button switches to '开始'
  });

  test('GameRepository background assets configuration and defaults', () {
    expect(GameRepository.kBackgroundAssets.length, 9);
    expect(GameRepository.kBackgroundAssets.first, 'assets/images/bg_000.webp');
    expect(GameRepository.kBackgroundAssets.last, 'assets/images/bg_008.webp');
  });

  testWidgets('ChooseBackgroundSheet displays 9 wallpaper options and invokes callback', (tester) async {
    String selectedBg = 'assets/images/bg_000.webp';

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
    expect(find.text('背景 1'), findsOneWidget);
    expect(find.text('背景 2'), findsOneWidget);
    expect(find.text('背景 3'), findsOneWidget);

    // Tap on Background 3
    await tester.tap(find.text('背景 3'));
    await tester.pumpAndSettle();

    expect(selectedBg, 'assets/images/bg_002.webp');
  });
}
