import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart'
    show BlendMode, Color, Offset, Paint, PaintingStyle, Rect, TileMode;

/// 实体拼图亚麻纸质漫反射微纹理管理器（Linen Finish & Diffuse Noise Manager）。
///
/// 【设计背景与核心原理】：
/// 高端实体艺术拼图（如 Ravensburger / Jigsaw Explorer）表面具有一层压印亚麻布纹（Linen Emboss Finish），
/// 呈现细微的十字交织纤维触感与漫反射哑光效果，能消除数码屏幕图片的纯平塑料反光感。
///
/// 【性能与架构设计】：
/// 1. 内存中仅生成一张 64x64 像素的无缝平铺微纹理，耗时 < 1ms，内存 < 16KB；
/// 2. 使用 GPU 硬件采样器 [ImageShader]（[TileMode.repeated]），渲染管线中 0 额外 CPU 计算；
/// 3. 单例缓存，全局复用。
class LinenTextureManager {
  LinenTextureManager._();

  static ui.Image? _textureImage;
  static Paint? _linenPaint;
  static bool _isInitializing = false;

  /// 全局亚麻布纹源贴图
  static ui.Image? get textureImage => _textureImage;

  /// 全局亚麻布纹画笔（已就绪时返回画笔，未就绪时返回 null）
  static Paint? get paint => _linenPaint;

  /// 是否启用亚麻纸质纹理覆盖
  static bool enabled = true;

  /// 异步初始化并预热亚麻布纹贴图
  static Future<void> ensureInitialized() async {
    if (_linenPaint != null || _isInitializing) return;
    _isInitializing = true;

    try {
      final image = await _generateLinenTextureImage(64, 64);
      _textureImage = image;

      // 4x4 单位矩阵
      final matrix4 = Float64List.fromList([
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
      ]);

      final shader = ui.ImageShader(
        image,
        TileMode.repeated,
        TileMode.repeated,
        matrix4,
      );

      _linenPaint = Paint()
        ..shader = shader
        ..blendMode = BlendMode.softLight
        ..isAntiAlias = true;
    } catch (_) {
      // 容错降级：若生成异常不阻断游戏正常渲染
    } finally {
      _isInitializing = false;
    }
  }

  /// 程序化生成无缝平铺的 64x64 亚麻布十字纤维与纸浆微粒贴图
  static Future<ui.Image> _generateLinenTextureImage(
    int width,
    int height,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    // 1. 中性灰底色 (柔和 128 灰阶，适于 softLight / overlay 混合)
    final basePaint = Paint()..color = const Color(0x00808080);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      basePaint,
    );

    final whiteLinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = const Color(0x0CFFFFFF); // 约 5% 半透明高光丝线

    final darkLinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = const Color(0x0E000000); // 约 5.5% 半透明暗纹切口

    const step = 4.0; // 4px 编织周期

    // 2. 绘制纵向经线纤维 (Warp Threads)
    for (double x = 0; x < width; x += step) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, height.toDouble()),
        whiteLinePaint,
      );
      canvas.drawLine(
        Offset(x + 1.0, 0),
        Offset(x + 1.0, height.toDouble()),
        darkLinePaint,
      );
    }

    // 3. 绘制横向纬线纤维 (Weft Threads)
    for (double y = 0; y < height; y += step) {
      canvas.drawLine(
        Offset(0, y),
        Offset(width.toDouble(), y),
        whiteLinePaint,
      );
      canvas.drawLine(
        Offset(0, y + 1.0),
        Offset(width.toDouble(), y + 1.0),
        darkLinePaint,
      );
    }

    // 4. 绘制经纬交叉编织节点 (Weave Intersection Highlights)
    final nodePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x08FFFFFF);

    for (double x = 0; x < width; x += step) {
      for (double y = 0; y < height; y += step) {
        final isEven = ((x / step).toInt() + (y / step).toInt()) % 2 == 0;
        if (isEven) {
          canvas.drawRect(Rect.fromLTWH(x, y, 1.5, 1.5), nodePaint);
        }
      }
    }

    // 5. 伪随机细微纸浆噪点 (Diffuse Pulp Micro-Noise)
    final rng = Random(12345);
    final dotPaintLight = Paint()..color = const Color(0x07FFFFFF);
    final dotPaintDark = Paint()..color = const Color(0x07000000);

    for (int i = 0; i < 96; i++) {
      final px = rng.nextDouble() * width;
      final py = rng.nextDouble() * height;
      final paint = rng.nextBool() ? dotPaintLight : dotPaintDark;
      canvas.drawCircle(Offset(px, py), 0.6, paint);
    }

    final picture = recorder.endRecording();
    return picture.toImage(width, height);
  }
}
