import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';

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
}
