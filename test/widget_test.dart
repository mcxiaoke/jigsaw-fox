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
    expect(PuzzleDifficulty.presets.first.pieceCount, 9);
    expect(PuzzleDifficulty.presets.last.pieceCount, 400);
  });

  test('PuzzleDifficulty.adaptiveForSize automatically aligns with image orientation', () {
    const diff3x4 = PuzzleDifficulty(label: '3 × 4 (12 块)', rows: 3, cols: 4);

    // 1. Portrait image (3:4 aspect, e.g. W=300, H=400)
    final portraitAdaptive = diff3x4.adaptiveForSize(300, 400);
    expect(portraitAdaptive.rows, 4, reason: 'Height should have 4 rows for 3:4 portrait image');
    expect(portraitAdaptive.cols, 3, reason: 'Width should have 3 cols for 3:4 portrait image');
    // Resulting single piece aspect ratio = (300/3) / (400/4) = 100 / 100 = 1.0 (Square!)

    // 2. Landscape image (4:3 aspect, e.g. W=400, H=300)
    final landscapeAdaptive = diff3x4.adaptiveForSize(400, 300);
    expect(landscapeAdaptive.rows, 3, reason: 'Height should have 3 rows for 4:3 landscape image');
    expect(landscapeAdaptive.cols, 4, reason: 'Width should have 4 cols for 4:3 landscape image');
    // Resulting single piece aspect ratio = (400/4) / (300/3) = 100 / 100 = 1.0 (Square!)
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
                    initialDifficulty: const PuzzleDifficulty(label: '3 × 3 (9 块)', rows: 3, cols: 3),
                    completedPieceCounts: const {9, 36},
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
    expect(find.text('已通关'), findsOneWidget); // Header badge for currently selected 9-piece diff
    expect(find.text('重玩此难度'), findsOneWidget);

    // 2. Check check_circle icons rendered for passed difficulties (9 and 36 + 1 header badge = at least 3 check_circle icons)
    expect(find.byIcon(Icons.check_circle), findsNWidgets(3));

    // 3. Tap on unpassed difficulty 16 (4x4)
    await tester.tap(find.text('16'));
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
