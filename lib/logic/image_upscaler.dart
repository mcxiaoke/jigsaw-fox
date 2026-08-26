import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// 高性能非 AI 图像保边降噪、空间插值与自适应超分辨率引擎
class ImageUpscaler {
  /// 判断图片是否属于低分辨率，需要进行 2x 画质增强
  /// 条件：短边 <= [minShortSide] (默认 750) 或 长边 <= [minLongSide] (默认 1000)
  static bool shouldUpscale({
    required int width,
    required int height,
    int minShortSide = 750,
    int minLongSide = 1000,
  }) {
    if (width <= 0 || height <= 0) return false;
    final shortSide = math.min(width, height);
    final longSide = math.max(width, height);
    return shortSide <= minShortSide || longSide <= minLongSide;
  }

  /// 异步在后台 Isolate 运行图片放大与增强管线，防止主 UI 线程丢帧
  /// [bytes]: 原始图片字节数据 (支持 PNG, JPEG, WebP 等格式)
  /// [scale]: 放大倍率 (默认 2.0)
  /// [enableDenoise]: 是否开启保边降噪 (默认 true)
  /// [denoiseStrength]: 降噪平滑度 0.0 ~ 1.0 (感知线性，推荐 0.2 ~ 0.35)
  /// [enableSharpen]: 是否开启 CAS 锐化 (默认 true)
  /// [sharpness]: 锐化强度 0.0 ~ 1.0 (感知线性，推荐 0.4 ~ 0.55)
  static Future<Uint8List> upscaleBytes({
    required Uint8List bytes,
    double scale = 2.0,
    bool enableDenoise = true,
    double denoiseStrength = 0.25,
    bool enableSharpen = true,
    double sharpness = 0.45,
    bool outputPng = true,
  }) async {
    return Isolate.run(() {
      final src = img.decodeImage(bytes);
      if (src == null) {
        throw Exception('图片解码失败，无法进行超分辨率放大');
      }

      final processed = processPipeline(
        src,
        scale: scale,
        enableDenoise: enableDenoise,
        denoiseStrength: denoiseStrength,
        enableSharpen: enableSharpen,
        sharpness: sharpness,
      );

      if (outputPng) {
        return Uint8List.fromList(img.encodePng(processed));
      } else {
        return Uint8List.fromList(img.encodeJpg(processed, quality: 95));
      }
    });
  }

  /// 图像处理管线：[温和保边降噪] -> [高质量 Cubic 空间插值] -> [线性 CAS 锐化]
  static img.Image processPipeline(
    img.Image src, {
    double scale = 2.0,
    bool enableDenoise = true,
    double denoiseStrength = 0.25,
    img.Interpolation interpolation = img.Interpolation.cubic,
    bool enableSharpen = true,
    double sharpness = 0.45,
  }) {
    // 1. 保边降噪：只抹除杂色与微弱底噪，保护发丝与轮廓
    img.Image denoised = src;
    if (enableDenoise && denoiseStrength > 0.001) {
      denoised = applyGentleGuidedFilter(src, strength: denoiseStrength);
    }

    // 2. 高质量双三次空间插值
    final targetWidth = (src.width * scale).round();
    final targetHeight = (src.height * scale).round();
    final upscaled = img.copyResize(
      denoised,
      width: targetWidth,
      height: targetHeight,
      interpolation: interpolation,
    );

    // 3. 对比度自适应锐化 (CAS)：恢复边缘与毛发的高频细节
    if (enableSharpen && sharpness > 0.001) {
      return applyLinearCAS(upscaled, sharpness: sharpness);
    }

    return upscaled;
  }

  /// 温和型导向滤波 (Guided Filter) - O(1) 盒状均值加速
  static img.Image applyGentleGuidedFilter(
    img.Image src, {
    double strength = 0.25,
    int radius = 2,
  }) {
    final width = src.width;
    final height = src.height;
    final numPixels = width * height;

    final baseEps = 15.0 + strength * 120.0;

    final rChannel = Float64List(numPixels);
    final gChannel = Float64List(numPixels);
    final bChannel = Float64List(numPixels);

    int idx = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final p = src.getPixel(x, y);
        rChannel[idx] = p.r.toDouble();
        gChannel[idx] = p.g.toDouble();
        bChannel[idx] = p.b.toDouble();
        idx++;
      }
    }

    final outR = _guidedFilterChannel(rChannel, width, height, radius, baseEps);
    final outG = _guidedFilterChannel(gChannel, width, height, radius, baseEps);
    final outB = _guidedFilterChannel(bChannel, width, height, radius, baseEps);

    final dst = img.Image(width: width, height: height, numChannels: src.numChannels);
    final blend = strength.clamp(0.0, 1.0);

    idx = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final origPixel = src.getPixel(x, y);
        final dstPixel = dst.getPixel(x, y);

        final finalR = (1.0 - blend) * origPixel.r + blend * outR[idx];
        final finalG = (1.0 - blend) * origPixel.g + blend * outG[idx];
        final finalB = (1.0 - blend) * origPixel.b + blend * outB[idx];

        dstPixel.r = finalR.clamp(0.0, 255.0).round();
        dstPixel.g = finalG.clamp(0.0, 255.0).round();
        dstPixel.b = finalB.clamp(0.0, 255.0).round();
        if (src.numChannels > 3) {
          dstPixel.a = origPixel.a;
        }
        idx++;
      }
    }

    return dst;
  }

  static Float64List _guidedFilterChannel(Float64List p, int w, int h, int r, double eps) {
    final n = w * h;
    final meanP = _boxFilter(p, w, h, r);

    final pSq = Float64List(n);
    for (int i = 0; i < n; i++) {
      pSq[i] = p[i] * p[i];
    }
    final meanPSq = _boxFilter(pSq, w, h, r);

    final a = Float64List(n);
    final b = Float64List(n);
    for (int i = 0; i < n; i++) {
      final varVal = math.max(0.0, meanPSq[i] - meanP[i] * meanP[i]);
      final aVal = varVal / (varVal + eps);
      a[i] = aVal;
      b[i] = meanP[i] - aVal * meanP[i];
    }

    final meanA = _boxFilter(a, w, h, r);
    final meanB = _boxFilter(b, w, h, r);

    final q = Float64List(n);
    for (int i = 0; i < n; i++) {
      q[i] = meanA[i] * p[i] + meanB[i];
    }

    return q;
  }

  static Float64List _boxFilter(Float64List src, int w, int h, int r) {
    final n = w * h;
    final temp = Float64List(n);
    final dst = Float64List(n);

    for (int y = 0; y < h; y++) {
      final rowOffset = y * w;
      double sum = 0.0;
      int count = 0;

      for (int x = -r; x <= r; x++) {
        final clampedX = x.clamp(0, w - 1);
        sum += src[rowOffset + clampedX];
        count++;
      }
      temp[rowOffset] = sum / count;

      for (int x = 1; x < w; x++) {
        final addX = (x + r).clamp(0, w - 1);
        final removeX = (x - r - 1).clamp(0, w - 1);
        sum += src[rowOffset + addX] - src[rowOffset + removeX];
        temp[rowOffset + x] = sum / count;
      }
    }

    for (int x = 0; x < w; x++) {
      double sum = 0.0;
      int count = 0;

      for (int y = -r; y <= r; y++) {
        final clampedY = y.clamp(0, h - 1);
        sum += temp[clampedY * w + x];
        count++;
      }
      dst[x] = sum / count;

      for (int y = 1; y < h; y++) {
        final addY = (y + r).clamp(0, h - 1);
        final removeY = (y - r - 1).clamp(0, h - 1);
        sum += temp[addY * w + x] - temp[removeY * w + x];
        dst[y * w + x] = sum / count;
      }
    }

    return dst;
  }

  /// 感知线性 CAS (Contrast Adaptive Sharpening)
  static img.Image applyLinearCAS(img.Image src, {double sharpness = 0.45}) {
    final width = src.width;
    final height = src.height;
    final dst = img.Image(width: width, height: height, numChannels: src.numChannels);

    final peak = -0.05 - (sharpness.clamp(0.0, 1.0) * 0.11);

    for (int y = 0; y < height; y++) {
      final yPrev = math.max(0, y - 1);
      final yNext = math.min(height - 1, y + 1);

      for (int x = 0; x < width; x++) {
        final xPrev = math.max(0, x - 1);
        final xNext = math.min(width - 1, x + 1);

        final e = src.getPixel(x, y);
        final b = src.getPixel(x, yPrev);
        final d = src.getPixel(xPrev, y);
        final f = src.getPixel(xNext, y);
        final h = src.getPixel(x, yNext);

        final outR = _calcCasChannel(e.r.toDouble(), b.r.toDouble(), d.r.toDouble(), f.r.toDouble(), h.r.toDouble(), peak);
        final outG = _calcCasChannel(e.g.toDouble(), b.g.toDouble(), d.g.toDouble(), f.g.toDouble(), h.g.toDouble(), peak);
        final outB = _calcCasChannel(e.b.toDouble(), b.b.toDouble(), d.b.toDouble(), f.b.toDouble(), h.b.toDouble(), peak);

        final dstPixel = dst.getPixel(x, y);
        dstPixel.r = outR;
        dstPixel.g = outG;
        dstPixel.b = outB;
        if (src.numChannels > 3) {
          dstPixel.a = e.a;
        }
      }
    }

    return dst;
  }

  static num _calcCasChannel(double e, double b, double d, double f, double h, double peak) {
    final minVal = math.min(e, math.min(math.min(b, d), math.min(f, h)));
    final maxVal = math.max(e, math.max(math.max(b, d), math.max(f, h)));

    final amp = math.min(minVal, 255.0 - maxVal) / math.max(1.0, maxVal);
    final w = math.sqrt(math.max(0.0, amp)) * peak;

    final totalWeight = 1.0 + 4.0 * w;
    final outVal = (w * (b + d + f + h) + e) / totalWeight;
    return outVal.clamp(0.0, 255.0).round();
  }
}
