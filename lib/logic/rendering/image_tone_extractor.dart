import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart' show Color;

/// 拼图图像色调提取与接缝色彩调和工具。
///
/// 【设计背景】：
/// 拼图碎片吸附拼合后，若公用接缝使用固定的纯黑或纯白高光线，会受 Flame 渲染
/// 顺序（Z-Order）影响出现黑灰斑驳不一的问题。
/// 本工具从拼图原图采样基准色温，并将其以 25% 的克制比例融入中性浅灰基底，
/// 生成柔和融入画面、统一弱化的浅灰色接缝色彩。
class ImageToneExtractor {
  const ImageToneExtractor._();

  /// 默认的中性弱化浅灰接缝色（约 42% 半透明中性灰）
  static const Color defaultSeamColor = Color(0x6BC8C8C8);

  /// 异步从图片二进制字节中提取代表性平均色温。
  ///
  /// 解码极微缩略图（默认 24x24 像素，共 576 像素），内存分配极小且耗时低于 2ms。
  /// 遇到异常或空数据时安全返回 `null`。
  static Future<Color?> extractAverageColor(
    Uint8List imageBytes, {
    int sampleSize = 24,
  }) async {
    if (imageBytes.isEmpty || sampleSize <= 0) return null;
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(
        imageBytes,
        targetWidth: sampleSize,
        targetHeight: sampleSize,
      );
      final frame = await codec.getNextFrame();
      final smallImage = frame.image;
      final byteData = await smallImage.toByteData();
      smallImage.dispose();

      if (byteData == null) return null;

      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final pixelCount = sampleSize * sampleSize;
      if (pixelCount <= 0 || bytes.length < pixelCount * 4) return null;

      var sumR = 0;
      var sumG = 0;
      var sumB = 0;
      for (var i = 0; i < pixelCount * 4; i += 4) {
        sumR += bytes[i];
        sumG += bytes[i + 1];
        sumB += bytes[i + 2];
      }

      return Color.fromARGB(
        255,
        sumR ~/ pixelCount,
        sumG ~/ pixelCount,
        sumB ~/ pixelCount,
      );
      // best-effort：提取色温失败时静默降级为默认接缝灰
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      return null;
    } finally {
      codec?.dispose();
    }
  }

  /// 根据传入的代表性色温 [toneColor]，调和生成弱化浅灰接缝色。
  ///
  /// - 若 [toneColor] 为 null，回退到 [defaultSeamColor]；
  /// - 若提供色温，先将其向纯白插值提亮以消除暗色图片引入黑线的风险，
  ///   再将中性浅灰与提亮色温按 75% : 25% 比例融合，最终赋予 42% 柔和透明度。
  static Color resolveSeamColor(Color? toneColor) {
    if (toneColor == null) return defaultSeamColor;

    // 1. 提亮色温（向纯白插值 40%），防止深色/夜景图片拉低接缝亮度变成深色
    final lightTone = Color.lerp(
      toneColor,
      const Color(0xFFFFFFFF),
      0.40,
    )!;

    // 2. 基准浅灰与提亮色温混合（75% 中性浅灰 + 25% 图片色温倾向）
    const baseGrey = Color(0xFFC8C8C8);
    final blended = Color.lerp(baseGrey, lightTone, 0.25)!;

    // 3. 赋予统一克制的柔和半透明度（42%），使切缝平滑融入下方图案
    return blended.withValues(alpha: 0.42);
  }
}
