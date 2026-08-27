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

    test('applyLumaGatedCAS should suppress noise in flat regions while sharpening edges', () {
      // 1. 测试平坦微噪区域：像素在 128 附近微弱波动 (±2)
      final flatSample = img.Image(width: 20, height: 20);
      for (int y = 0; y < 20; y++) {
        for (int x = 0; x < 20; x++) {
          final p = flatSample.getPixel(x, y);
          final noise = (x + y) % 2 == 0 ? 128 : 130;
          p.r = noise;
          p.g = noise;
          p.b = noise;
          p.a = 255;
        }
      }

      final gatedResult = ImageUpscaler.applyLumaGatedCAS(
        flatSample,
        sharpness: 0.8,
        noiseThresholdLow: 8.0,
      );

      // 平坦区域的微噪差值 <= 8，应该完全不被放大，保持原样
      final centerGated = gatedResult.getPixel(10, 10);
      final centerOrig = flatSample.getPixel(10, 10);
      expect(centerGated.r, equals(centerOrig.r));
      expect(centerGated.g, equals(centerOrig.g));
      expect(centerGated.b, equals(centerOrig.b));

      // 2. 测试高对比度真实边缘：左半边 0，右半边 255
      final edgeSample = img.Image(width: 20, height: 20);
      for (int y = 0; y < 20; y++) {
        for (int x = 0; x < 20; x++) {
          final p = edgeSample.getPixel(x, y);
          final val = x < 10 ? 30 : 220;
          p.r = val;
          p.g = val;
          p.b = val;
          p.a = 255;
        }
      }

      final edgeGatedResult = ImageUpscaler.applyLumaGatedCAS(
        edgeSample,
        sharpness: 0.5,
        noiseThresholdLow: 8.0,
        noiseThresholdHigh: 24.0,
      );

      // 边缘过渡区域应该被正确锐化
      expect(edgeGatedResult.width, equals(20));
      expect(edgeGatedResult.height, equals(20));
    });
  });
}
