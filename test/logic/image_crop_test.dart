import 'package:flutter_test/flutter_test.dart';
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
}
