import 'dart:typed_data';
import 'package:flutter/painting.dart' show Color, PaintingStyle;
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/game/puzzle_piece_component.dart';
import 'package:jigsawpuzzle/logic/rendering/image_tone_extractor.dart';

void main() {
  group('ImageToneExtractor 测试', () {
    test('空字节流或无效数据安全返回 null', () async {
      expect(
        await ImageToneExtractor.extractAverageColor(Uint8List(0)),
        isNull,
      );
      expect(
        await ImageToneExtractor.extractAverageColor(
          Uint8List.fromList([1, 2, 3, 4]),
        ),
        isNull,
      );
    });

    test('resolveSeamColor 在 null 色温下返回默认弱化浅灰', () {
      final color = ImageToneExtractor.resolveSeamColor(null);
      expect(color, equals(ImageToneExtractor.defaultSeamColor));
      expect(color.a, closeTo(0.42, 0.05));
    });

    test('resolveSeamColor 在纯黑或深色色温下保持高明度弱化浅灰，不退化为深黑', () {
      const darkTone = Color(0xFF000000);
      final seamColor = ImageToneExtractor.resolveSeamColor(darkTone);

      // 验证透明度保持在 0.42 左右
      expect(seamColor.a, closeTo(0.42, 0.02));

      // 计算混合后的 RGB 亮度分量，确保没有被纯黑拉低到深黑色
      final r = (seamColor.r * 255).round();
      final g = (seamColor.g * 255).round();
      final b = (seamColor.b * 255).round();

      expect(r, greaterThanOrEqualTo(160));
      expect(g, greaterThanOrEqualTo(160));
      expect(b, greaterThanOrEqualTo(160));
    });

    test('resolveSeamColor 在暖色调（金黄）和冷色调（蓝色）下呈现适度色温倾向', () {
      const warmTone = Color(0xFFFF9900);
      const coldTone = Color(0xFF0066FF);

      final warmSeam = ImageToneExtractor.resolveSeamColor(warmTone);
      final coldSeam = ImageToneExtractor.resolveSeamColor(coldTone);

      // 暖色系应呈现 R > B
      expect(warmSeam.r, greaterThan(warmSeam.b));

      // 冷色系应呈现 B > R
      expect(coldSeam.b, greaterThan(coldSeam.r));

      // 透明度统一为 42%
      expect(warmSeam.a, closeTo(0.42, 0.02));
      expect(coldSeam.a, closeTo(0.42, 0.02));
    });
  });

  group('PuzzlePieceComponent 接缝画笔与屏幕恒定契约', () {
    test('testLockedSeamPaint 配置符合描边规范', () {
      final paint = PuzzlePieceComponent.testLockedSeamPaint;
      expect(paint.style, equals(PaintingStyle.stroke));
      expect(paint.isAntiAlias, isTrue);
    });

    test('接缝线 0.8px 逆缩放保证放大时不增粗', () {
      const baseline = 0.8;
      for (final s in [1.5, 2.0, 3.0, 4.0]) {
        final local = PuzzlePieceComponent.screenInvariantValue(baseline, s);
        expect(local * s, closeTo(baseline, 1e-9));
      }
    });
  });
}
