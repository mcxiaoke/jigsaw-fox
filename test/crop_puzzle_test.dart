import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/pages/crop_puzzle_page.dart';

Future<Uint8List> createTestImageBytes(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.blue);
  final picture = recorder.endRecording();
  final img = await picture.toImage(width, height);
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CropRatio definitions cover 5 standard aspect ratios with positive target resolutions', () {
    expect(CropRatio.values.length, 5);
    for (final ratio in CropRatio.values) {
      expect(ratio.targetWidth, greaterThan(0));
      expect(ratio.targetHeight, greaterThan(0));
      expect((ratio.targetWidth / ratio.targetHeight - ratio.ratio).abs(), lessThan(1e-4));
      expect(ratio.aspectRatio.tiers.isNotEmpty, isTrue);
    }
  });

  testWidgets('CropPuzzlePage renders header, aspect ratios and gesture instructions', (tester) async {
    late Uint8List imageBytes;
    await tester.runAsync(() async {
      imageBytes = await createTestImageBytes(400, 200);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: CropPuzzlePage(rawBytes: imageBytes),
      ),
    );

    await tester.runAsync(() async {
      await Future.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(find.text('裁剪与自制拼图'), findsOneWidget);
    expect(find.text('按住拖动调整裁切位置 · 双指或滚轮缩放'), findsOneWidget);
    expect(find.text('1:1 正方形'), findsOneWidget);
    expect(find.text('3:2 横屏'), findsOneWidget);
    expect(find.text('2:3 竖屏'), findsOneWidget);
    expect(find.text('4:3 横屏'), findsOneWidget);
    expect(find.text('3:4 竖屏'), findsOneWidget);

    final ivFinder = find.byType(InteractiveViewer);
    expect(ivFinder, findsOneWidget);
    final iv = tester.widget<InteractiveViewer>(ivFinder);
    expect(iv.constrained, isFalse);
    expect(iv.minScale, 1.0);
    expect(iv.maxScale, greaterThanOrEqualTo(1.0));

    // Switch ratio to 2:3 Portrait
    await tester.tap(find.text('2:3 竖屏'));
    await tester.pump();

    // Switch ratio to 4:3 Landscape
    await tester.tap(find.text('4:3 横屏'));
    await tester.pump();

    // Verify reset zoom percentage pill exists
    expect(find.text('100%'), findsOneWidget);

    // Verify real-time crop resolution label exists
    expect(find.textContaining('裁切区域:'), findsOneWidget);

    // Verify save button exists
    expect(find.text('保存自制关卡'), findsOneWidget);
  });
}
