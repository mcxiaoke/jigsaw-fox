import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jigsawpuzzle/logic/image_upscaler.dart';

void main() {
  group('ImageUpscaler Engine Tests', () {
    test('shouldUpscale condition check', () {
      // 满足任意一个短边<=750 或 长边<=1000 即需要放大
      expect(ImageUpscaler.shouldUpscale(width: 600, height: 800), isTrue); // 短边600<=750, 长边800<=1000
      expect(ImageUpscaler.shouldUpscale(width: 700, height: 1200), isTrue); // 短边700<=750
      expect(ImageUpscaler.shouldUpscale(width: 1000, height: 1000), isTrue); // 长边1000<=1000
      expect(ImageUpscaler.shouldUpscale(width: 750, height: 1100), isTrue); // 短边750<=750

      // 都不满足时不放大
      expect(ImageUpscaler.shouldUpscale(width: 800, height: 1200), isFalse); // 短边800>750, 长边1200>1000
      expect(ImageUpscaler.shouldUpscale(width: 1920, height: 1080), isFalse);
    });

    test('processPipeline should correctly upscale 2x and enhance image', () {
      final sample = img.Image(width: 100, height: 80);
      // 填充渐变与测试条纹
      for (int y = 0; y < 80; y++) {
        for (int x = 0; x < 100; x++) {
          final p = sample.getPixel(x, y);
          p.r = (x * 2) % 256;
          p.g = (y * 3) % 256;
          p.b = 128;
          p.a = 255;
        }
      }

      final result = ImageUpscaler.processPipeline(
        sample,
        scale: 2.0,
        enableDenoise: true,
        denoiseStrength: 0.25,
        sharpness: 0.45,
      );

      expect(result.width, equals(200));
      expect(result.height, equals(160));
    });

    test('upscaleBytes in Isolate should process PNG bytes', () async {
      final sample = img.Image(width: 50, height: 50);
      img.fill(sample, color: img.ColorRgba8(255, 100, 50, 255));
      final pngBytes = Uint8List.fromList(img.encodePng(sample));

      final upscaledBytes = await ImageUpscaler.upscaleBytes(
        bytes: pngBytes,
        scale: 2.0,
        denoiseStrength: 0.2,
        sharpness: 0.4,
      );

      final decoded = img.decodeImage(upscaledBytes);
      expect(decoded, isNotNull);
      if (decoded != null) {
        expect(decoded.width, equals(100));
        expect(decoded.height, equals(100));
      }
    });
  });
}
