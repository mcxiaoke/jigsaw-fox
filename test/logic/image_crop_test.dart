import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jigsawpuzzle/logic/cache/thumbnail_generator.dart';
import 'package:jigsawpuzzle/logic/image_crop.dart';

void main() {
  group('cropLossFor', () {
    test('4:3 to 3:2 is 11.1% area loss (design §2.2 table)', () {
      final loss = cropLossFor(4 / 3, 3 / 2);
      expect(loss, closeTo(0.1111, 0.001));
    });

    test('3:4 to 2:3 is 11.1% area loss', () {
      final loss = cropLossFor(3 / 4, 2 / 3);
      expect(loss, closeTo(0.1111, 0.001));
    });

    test('16:9 to 3:2 is 15.6% area loss (crop width)', () {
      final loss = cropLossFor(16 / 9, 3 / 2);
      expect(loss, closeTo(0.1556, 0.001));
    });

    test('4:5 to 2:3 loses 16.7% - less than 1:1 20%, must pick 2:3', () {
      final loss23 = cropLossFor(4 / 5, 2 / 3);
      final loss11 = cropLossFor(4 / 5, 1.0);
      expect(loss23, closeTo(0.1667, 0.001));
      expect(loss23, lessThan(loss11));
    });

    test('exact match has zero loss', () {
      expect(cropLossFor(1.5, 1.5), 0.0);
    });
  });

  group('centerCropRect', () {
    test('4:3 (4032x3024) to 3:2 crops height, keeps full width', () {
      final rect = centerCropRect(
        imageWidth: 4032,
        imageHeight: 3024,
        targetRatio: 1.5,
      );
      expect(rect.left, 0);
      expect(rect.top, closeTo(168, 1)); // (3024 - 2688) / 2
      expect(rect.width, 4032);
      expect(rect.height, closeTo(2688, 1));
    });

    test('3:4 portrait to 2:3 crops width, keeps full height', () {
      final rect = centerCropRect(
        imageWidth: 3024,
        imageHeight: 4032,
        targetRatio: 2 / 3,
      );
      expect(rect.left, closeTo(168, 1)); // (3024 - 2688) / 2
      expect(rect.top, 0);
      expect(rect.width, closeTo(2688, 1));
      expect(rect.height, 4032);
    });

    test('16:9 (1920x1080) to 3:2 crops width', () {
      final rect = centerCropRect(
        imageWidth: 1920,
        imageHeight: 1080,
        targetRatio: 1.5,
      );
      expect(rect.top, 0);
      expect(rect.height, 1080);
      expect(rect.width, closeTo(1620, 1)); // 1080 * 1.5
      expect(rect.left, closeTo(150, 1));
    });

    test('1:1 image to 1:1 crops nothing', () {
      final rect = centerCropRect(
        imageWidth: 1024,
        imageHeight: 1024,
        targetRatio: 1.0,
      );
      expect(rect.left, 0);
      expect(rect.top, 0);
      expect(rect.width, 1024);
      expect(rect.height, 1024);
    });
  });

  group('needsCenterCropFor', () {
    test('matches ratio within tolerance -> no crop', () {
      expect(
        needsCenterCropFor(width: 1500, height: 1000, targetRatio: 1.5),
        isFalse,
      );
    });

    test('4:3 vs 3:2 -> crop needed', () {
      expect(
        needsCenterCropFor(width: 4032, height: 3024, targetRatio: 1.5),
        isTrue,
      );
    });

    test('tiny deviation within 1% tolerance -> no crop', () {
      // 1.49 vs 1.5: loss = 0.67% < 1%
      expect(
        needsCenterCropFor(width: 1490, height: 1000, targetRatio: 1.5),
        isFalse,
      );
    });
  });

  group('nearestStandardRatio', () {
    test('4:3 (1.333) picks 3:2 (loss 11.1%) over 1:1 (25%)', () {
      expect(
        nearestStandardRatio(width: 4032, height: 3024),
        closeTo(1.5, 0.001),
      );
    });

    test('3:4 (0.75) picks 2:3 (loss 11.1%)', () {
      expect(
        nearestStandardRatio(width: 3024, height: 4032),
        closeTo(2 / 3, 0.001),
      );
    });

    test('16:9 (1.778) picks 3:2 (loss 15.6%)', () {
      expect(
        nearestStandardRatio(width: 1920, height: 1080),
        closeTo(1.5, 0.001),
      );
    });

    test('1:1 picks 1:1', () {
      expect(
        nearestStandardRatio(width: 1024, height: 1024),
        closeTo(1.0, 0.001),
      );
    });

    test('4:5 (0.8) picks 2:3 over 1:1 (16.7% < 20%)', () {
      expect(
        nearestStandardRatio(width: 800, height: 1000),
        closeTo(2 / 3, 0.001),
      );
    });
  });

  group('findSmartCropRect', () {
    test('pure monochrome image smoothly falls back to centerCropRect', () {
      final imgObj = img.Image(width: 1600, height: 900);
      img.fill(imgObj, color: img.ColorRgb8(200, 200, 200));

      final smartRect = findSmartCropRect(imgObj, targetRatio: 1.0);
      final centerRect = centerCropRect(
        imageWidth: 1600,
        imageHeight: 900,
        targetRatio: 1.0,
      );

      expect(smartRect.left, centerRect.left);
      expect(smartRect.top, centerRect.top);
      expect(smartRect.width, centerRect.width);
      expect(smartRect.height, centerRect.height);
    });

    test('left-biased high-contrast subject pulls crop window to the left', () {
      final imgObj = img.Image(width: 1600, height: 900);
      img.fill(imgObj, color: img.ColorRgb8(240, 240, 240));

      // 在左侧 [50, 450] 绘制高对比度细节纹理
      for (var y = 100; y < 800; y++) {
        for (var x = 50; x < 450; x++) {
          final c = ((x * 17 + y * 31) % 200);
          imgObj.setPixelRgb(x, y, c, 255 - c, (c * 2) % 255);
        }
      }

      final smartRect = findSmartCropRect(imgObj, targetRatio: 1.0);
      final centerRect = centerCropRect(
        imageWidth: 1600,
        imageHeight: 900,
        targetRatio: 1.0,
      );

      // 普通居中会从 (1600 - 900)/2 = 350 开始，裁掉左边大部分主体
      expect(centerRect.left, 350.0);
      // 智能裁切窗口必须自动向左靠拢 (left <= 100)，完全覆盖主体
      expect(smartRect.left, lessThan(100.0));
      expect(smartRect.width, 900.0);
      expect(smartRect.height, 900.0);
    });

    test(
      'right-biased high-contrast subject pulls crop window to the right',
      () {
        final imgObj = img.Image(width: 1600, height: 900);
        img.fill(imgObj, color: img.ColorRgb8(240, 240, 240));

        // 在右侧 [1150, 1550] 绘制高对比度细节纹理
        for (var y = 100; y < 800; y++) {
          for (var x = 1150; x < 1550; x++) {
            final c = ((x * 19 + y * 23) % 200);
            imgObj.setPixelRgb(x, y, 255 - c, c, (c * 3) % 255);
          }
        }

        final smartRect = findSmartCropRect(imgObj, targetRatio: 1.0);
        final centerRect = centerCropRect(
          imageWidth: 1600,
          imageHeight: 900,
          targetRatio: 1.0,
        );

        expect(centerRect.left, 350.0);
        // 智能裁切窗口必须自动向右靠拢 (left >= 600)
        expect(smartRect.left, greaterThan(600.0));
        expect(smartRect.width, 900.0);
        expect(smartRect.height, 900.0);
      },
    );

    test(
      'top-biased subject on tall vertical image pulls crop window to the top',
      () {
        final imgObj = img.Image(width: 900, height: 1600);
        img.fill(imgObj, color: img.ColorRgb8(240, 240, 240));

        // 在顶部 [50, 450] 绘制主体
        for (var y = 50; y < 450; y++) {
          for (var x = 100; x < 800; x++) {
            final c = ((x * 13 + y * 29) % 200);
            imgObj.setPixelRgb(x, y, c, c, 255 - c);
          }
        }

        final smartRect = findSmartCropRect(imgObj, targetRatio: 1.0);
        final centerRect = centerCropRect(
          imageWidth: 900,
          imageHeight: 1600,
          targetRatio: 1.0,
        );

        // 普通居中 top = (1600 - 900) / 2 = 350
        expect(centerRect.top, 350.0);
        // 智能裁切必须向顶部靠拢 (top <= 100)
        expect(smartRect.top, lessThan(100.0));
        expect(smartRect.width, 900.0);
        expect(smartRect.height, 900.0);
      },
    );

    test('already matching target ratio returns full image rect', () {
      final imgObj = img.Image(width: 1200, height: 800); // 3:2
      final smartRect = findSmartCropRect(imgObj, targetRatio: 1.5);
      expect(smartRect.left, 0.0);
      expect(smartRect.top, 0.0);
      expect(smartRect.width, 1200.0);
      expect(smartRect.height, 800.0);
    });
  });

  group('ThumbnailGenerator.generateCroppedBytesFromBytes', () {
    test(
      'crops image to target ratio with smartCrop: true by default',
      () async {
        final imgObj = img.Image(width: 400, height: 200); // 2:1
        img.fill(imgObj, color: img.ColorRgb8(100, 150, 200));
        for (var y = 20; y < 180; y++) {
          for (var x = 20; x < 180; x++) {
            imgObj.setPixelRgb(x, y, 255, 0, 0);
          }
        }
        final rawBytes = Uint8List.fromList(img.encodeJpg(imgObj));

        final croppedBytes =
            await ThumbnailGenerator.generateCroppedBytesFromBytes(
              rawBytes: rawBytes,
              targetRatio: 1.0,
            );
        expect(croppedBytes, isNotNull);

        final resultImg = img.decodeImage(croppedBytes!)!;
        expect(resultImg.width, 200);
        expect(resultImg.height, 200);
      },
    );

    test('supports smartCrop: false for center crop fallback', () async {
      final imgObj = img.Image(width: 400, height: 200); // 2:1
      img.fill(imgObj, color: img.ColorRgb8(100, 150, 200));
      final rawBytes = Uint8List.fromList(img.encodeJpg(imgObj));

      final croppedBytes =
          await ThumbnailGenerator.generateCroppedBytesFromBytes(
            rawBytes: rawBytes,
            targetRatio: 1.0,
            smartCrop: false,
          );
      expect(croppedBytes, isNotNull);

      final resultImg = img.decodeImage(croppedBytes!)!;
      expect(resultImg.width, 200);
      expect(resultImg.height, 200);
    });
  });
}
