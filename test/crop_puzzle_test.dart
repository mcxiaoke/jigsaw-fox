import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/pages/crop_puzzle_page.dart';

Future<Uint8List> createTestImageBytes(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(
    recorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.blue,
  );
  final picture = recorder.endRecording();
  final img = await picture.toImage(width, height);
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'supportedCropOptions dynamically derives 5 standard aspect ratios with consistent properties',
    () {
      expect(supportedCropOptions.length, 5);
      for (final option in supportedCropOptions) {
        expect(option.label, isNotEmpty);
        expect(option.ratio, greaterThan(0));
        expect(
          (option.aspectRatio.aspectCols / option.aspectRatio.aspectRows -
                  option.ratio)
              .abs(),
          lessThan(1e-4),
        );
        expect(option.aspectRatio.tiers.isNotEmpty, isTrue);
      }
    },
  );

  testWidgets(
    'CropPuzzlePage renders header, aspect ratios and gesture instructions',
    (tester) async {
      late Uint8List imageBytes;
      await tester.runAsync(() async {
        imageBytes = await createTestImageBytes(400, 200);
      });

      await tester.pumpWidget(
        MaterialApp(home: CropPuzzlePage(rawBytes: imageBytes)),
      );

      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(find.text('裁剪与自制拼图'), findsOneWidget);
      expect(find.text('按住拖动调整裁切位置 · 双指或滚轮缩放'), findsOneWidget);
      expect(find.text('1:1'), findsOneWidget);
      expect(find.text('3:2'), findsOneWidget);
      expect(find.text('2:3'), findsOneWidget);
      expect(find.text('3:4'), findsOneWidget);
      expect(find.text('4:3'), findsOneWidget);

      final ivFinder = find.byType(InteractiveViewer);
      expect(ivFinder, findsOneWidget);
      final iv = tester.widget<InteractiveViewer>(ivFinder);
      expect(iv.constrained, isFalse);
      expect(iv.minScale, 1.0);
      expect(iv.maxScale, greaterThanOrEqualTo(1.0));

      // Switch ratio to 2:3 Portrait
      await tester.tap(find.text('2:3'));
      await tester.pump();

      // Switch ratio to 3:2 Landscape
      await tester.tap(find.text('3:2'));
      await tester.pump();

      // Verify reset zoom percentage pill exists
      expect(find.text('100%'), findsOneWidget);

      // Verify real-time crop resolution label exists
      expect(find.textContaining('裁切区域:'), findsOneWidget);

      // Verify save button exists
      expect(find.text('保存自制关卡'), findsOneWidget);
    },
  );

  group('CropPuzzlePage.calculateMaxCropScaleFromDimensions', () {
    test(
      '4000x3000 image with matching 4:3 viewport yields maxScale ~2.778',
      () {
        final scale = CropPuzzlePage.calculateMaxCropScaleFromDimensions(
          viewportSize: const Size(400, 300),
          imageWidth: 4000,
          imageHeight: 3000,
        );
        expect(scale, closeTo(3000 / 1080, 1e-4));
        // 验证在 scale 上限时，真实裁切短边像素恰好为 1080px
        const baseScale = 400 / 4000;
        final cropShort = 300 / (baseScale * scale);
        expect(cropShort, closeTo(1080.0, 0.1));
      },
    );

    test(
      '3000x4000 portrait image cropped to 4:3 landscape limits scale to 2.083 to guarantee 1080px short side',
      () {
        final scale = CropPuzzlePage.calculateMaxCropScaleFromDimensions(
          viewportSize: const Size(400, 300),
          imageWidth: 3000,
          imageHeight: 4000,
        );
        // baseScale = max(400/3000, 300/4000) = 400/3000
        // physMax = 300 / ((400/3000) * 1080) = 300 / 144 = 2.08333
        expect(scale, closeTo(2.08333, 1e-4));

        const baseScale = 400.0 / 3000.0;
        final realCropW = 400.0 / (baseScale * scale);
        final realCropH = 300.0 / (baseScale * scale);
        expect(realCropW, closeTo(1440.0, 0.1));
        expect(realCropH, closeTo(1080.0, 0.1));
        expect(realCropH, greaterThanOrEqualTo(1080.0 - 1e-4));
      },
    );

    test(
      '1440x1440 square image cropped to 3:2 landscape locks to 1.0 (prevents digital upscale)',
      () {
        final scale = CropPuzzlePage.calculateMaxCropScaleFromDimensions(
          viewportSize: const Size(300, 200),
          imageWidth: 1440,
          imageHeight: 1440,
        );
        // baseScale = 300/1440, physMax = 200 / ((300/1440) * 1080) = 0.8888 <= 1.0
        expect(scale, 1.0);
      },
    );

    test('1080x1080 image on 1:1 viewport locks to 1.0', () {
      final scale = CropPuzzlePage.calculateMaxCropScaleFromDimensions(
        viewportSize: const Size(300, 300),
        imageWidth: 1080,
        imageHeight: 1080,
      );
      expect(scale, 1.0);
    });

    test('800x600 small image locks to 1.0', () {
      final scale = CropPuzzlePage.calculateMaxCropScaleFromDimensions(
        viewportSize: const Size(400, 300),
        imageWidth: 800,
        imageHeight: 600,
      );
      expect(scale, 1.0);
    });

    test('zero or negative dimensions safely fallback to 1.0', () {
      expect(
        CropPuzzlePage.calculateMaxCropScaleFromDimensions(
          viewportSize: Size.zero,
          imageWidth: 4000,
          imageHeight: 3000,
        ),
        1.0,
      );
      expect(
        CropPuzzlePage.calculateMaxCropScaleFromDimensions(
          viewportSize: const Size(400, 300),
          imageWidth: 0,
          imageHeight: 3000,
        ),
        1.0,
      );
    });
  });
}
