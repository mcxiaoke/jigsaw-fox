/// 图片居中裁剪与主体智能裁切适配（设计 §2.2：移除 3:4/4:3 后的必备配套）
///
/// 仅用于 ZIP 图包导入入库时的静默裁切（设计 §2.2 管线路径）：
/// 任意比例图片裁剪到 {1:1, 3:2, 2:3} 中面积损失最小的档位，
/// 保证入库后进游戏切片 `srcPieceW == srcPieceH`（纯正方形 cell）。
///
/// 规则：
/// - 只裁不缩：保持原分辨率，避免放大损失
/// - 默认支持主体感知智能裁切（findSmartCropRect）：
///   基于边缘细节梯度、色彩饱和度与主体特征计算能量分布，利用 2D 积分图自动滑动搜索最佳窗口；
/// - 保留纯几何居中裁切（centerCropRect）作为快速兜底。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:image/image.dart' as img;

/// 支持的三种标准比例（1:1 / 3:2 / 2:3）
const List<double> kStandardRatios = [1.0, 1.5, 2 / 3];

/// 最小面积损失法（与 `PuzzleAspectRatio.cropLoss` 同一公式，此处解耦避免依赖层级）
double cropLossFor(double imageRatio, double targetRatio) {
  if (imageRatio <= 0 || targetRatio <= 0) return 1.0;
  return 1.0 - math.min(imageRatio / targetRatio, targetRatio / imageRatio);
}

/// 选取 {1:1, 3:2, 2:3} 中面积损失最小的目标比例（设计 §2.2 最小面积损失法）
double nearestStandardRatio({required int width, required int height}) {
  if (width <= 0 || height <= 0) return 1.0;
  final r = width / height;
  var best = kStandardRatios.first;
  var minLoss = cropLossFor(r, best);
  for (final candidate in kStandardRatios) {
    final loss = cropLossFor(r, candidate);
    if (loss < minLoss) {
      minLoss = loss;
      best = candidate;
    }
  }
  return best;
}

/// 判断宽高为 [width]x[height] 的图片是否需要居中裁剪到目标比例
/// （容差 [tolerance]，默认 1% 面积损失）
bool needsCenterCropFor({
  required int width,
  required int height,
  required double targetRatio,
  double tolerance = 0.01,
}) {
  if (width <= 0 || height <= 0 || targetRatio <= 0) return false;
  return cropLossFor(width / height, targetRatio) > tolerance;
}

/// 计算居中裁剪区域（纯数学，便于单测）：
/// `imageRatio > targetRatio` 裁宽（左右各半），否则裁高（上下各半）。
/// 返回源图坐标系下的裁剪矩形。
Rect centerCropRect({
  required int imageWidth,
  required int imageHeight,
  required double targetRatio,
}) {
  final w = imageWidth.toDouble();
  final h = imageHeight.toDouble();
  final srcRatio = w / h;

  double cropW, cropH, dx, dy;
  if (srcRatio > targetRatio) {
    // 太宽：裁宽，高度不变
    cropH = h;
    cropW = h * targetRatio;
    dx = (w - cropW) / 2;
    dy = 0;
  } else {
    // 太高：裁高，宽度不变
    cropW = w;
    cropH = w / targetRatio;
    dx = 0;
    dy = (h - cropH) / 2;
  }

  return Rect.fromLTWH(dx, dy, cropW, cropH);
}

/// 基于主体显著性能量分布与 2D 积分图的智能裁切矩形计算。
///
/// 特性：
/// 1. 降采样至分析尺寸（最长边 <= [analysisLongSide]，默认 512），保证在 ~10ms 内极速完成；
/// 2. 融合 Sobel 边缘梯度（高频轮廓/细节）、HSV 色彩饱和度（鲜明主体）与暖色/肤色加权；
/// 3. 施加弱中心先验（中心 1.0，四角 0.85），并在全图平坦纯色时自动平滑回退居中 [centerCropRect]；
/// 4. 利用 2D 积分图在 O(1) 复杂度内寻找画面主体能量最大的最佳裁剪窗口，避免偏侧主体被裁截。
Rect findSmartCropRect(
  img.Image image, {
  required double targetRatio,
  int analysisLongSide = 512,
}) {
  final srcW = image.width;
  final srcH = image.height;
  if (srcW <= 0 || srcH <= 0 || targetRatio <= 0) {
    return Rect.zero;
  }

  final srcRatio = srcW / srcH;
  // 偏差在 1% 容差内，无需裁剪
  final loss = 1.0 - math.min(srcRatio / targetRatio, targetRatio / srcRatio);
  if (loss <= 0.01) {
    return Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble());
  }

  // 1. 计算目标裁剪尺寸（原图坐标系）
  double cropW, cropH;
  if (srcRatio > targetRatio) {
    cropH = srcH.toDouble();
    cropW = srcH * targetRatio;
  } else {
    cropW = srcW.toDouble();
    cropH = srcW / targetRatio;
  }
  final intCropW = cropW.round().clamp(1, srcW);
  final intCropH = cropH.round().clamp(1, srcH);

  // 若长宽已满，直接返回
  if (intCropW >= srcW && intCropH >= srcH) {
    return Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble());
  }

  // 2. 降采样生成能量分析小图
  final longSide = math.max(srcW, srcH);
  final scale = (longSide > analysisLongSide)
      ? (analysisLongSide / longSide)
      : 1.0;
  final sw = math.max(1, (srcW * scale).round());
  final sh = math.max(1, (srcH * scale).round());

  final img.Image small;
  if (sw == srcW && sh == srcH) {
    small = image;
  } else {
    small = img.copyResize(
      image,
      width: sw,
      height: sh,
      interpolation: img.Interpolation.linear,
    );
  }

  final totalPixels = sw * sh;
  final gray = Float32List(totalPixels);
  final sat = Float32List(totalPixels);
  final warm = Float32List(totalPixels);

  for (var y = 0; y < sh; y++) {
    final row = y * sw;
    for (var x = 0; x < sw; x++) {
      final p = small.getPixel(x, y);
      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();

      gray[row + x] = 0.299 * r + 0.587 * g + 0.114 * b;

      final maxC = math.max(r, math.max(g, b));
      final minC = math.min(r, math.min(g, b));
      sat[row + x] = maxC - minC;

      // 暖色/肤色加权 (R > G && G > B && R - B > 20 && R > 50)
      final isWarm = (r > g && g > b && (r - b) > 20.0 && r > 50.0);
      warm[row + x] = isWarm ? 1.4 : 1.0;
    }
  }

  // 3. 计算边缘梯度幅值
  final grad = Float32List(totalPixels);
  for (var y = 0; y < sh; y++) {
    final row = y * sw;
    final prevRow = y > 0 ? (y - 1) * sw : row;
    final nextRow = y < sh - 1 ? (y + 1) * sw : row;
    for (var x = 0; x < sw; x++) {
      final prevCol = x > 0 ? x - 1 : x;
      final nextCol = x < sw - 1 ? x + 1 : x;

      final gx = (gray[row + nextCol] - gray[row + prevCol]).abs();
      final gy = (gray[nextRow + x] - gray[prevRow + x]).abs();
      grad[row + x] = gx + gy;
    }
  }

  // 4. 融合色彩能量并施加弱中心先验
  final energy = Float32List(totalPixels);
  final cx = sw / 2.0;
  final cy = sh / 2.0;
  final maxDist = math.sqrt(cx * cx + cy * cy);
  var maxEnergy = 0.0;

  for (var y = 0; y < sh; y++) {
    final row = y * sw;
    final dy = (y - cy).abs();
    for (var x = 0; x < sw; x++) {
      final dx = (x - cx).abs();
      final dist = maxDist > 0 ? (math.sqrt(dx * dx + dy * dy) / maxDist) : 0.0;
      final centerPrior = 1.0 - 0.15 * math.min(dist, 1.0);

      final e =
          (grad[row + x] * 0.7 + sat[row + x] * 0.3) *
          warm[row + x] *
          centerPrior;
      energy[row + x] = e;
      if (e > maxEnergy) {
        maxEnergy = e;
      }
    }
  }

  // 若画面纯色或无显著能量，平滑回退居中裁切
  if (maxEnergy <= 1e-4) {
    return centerCropRect(
      imageWidth: srcW,
      imageHeight: srcH,
      targetRatio: targetRatio,
    );
  }

  // 5. 抑制底噪（截断低于 30 百分位的背景噪声）
  final sampleCount = math.min(totalPixels, 1000);
  final sampleStep = math.max(1, totalPixels ~/ sampleCount);
  final samples = Float32List(sampleCount);
  var sIdx = 0;
  for (var i = 0; i < totalPixels && sIdx < sampleCount; i += sampleStep) {
    samples[sIdx++] = energy[i];
  }
  samples.sort();
  final thresh = samples[(sampleCount * 0.3).floor()];

  for (var i = 0; i < totalPixels; i++) {
    if (energy[i] <= thresh) {
      energy[i] = 0.0;
    }
  }

  // 6. 构建 2D 积分图 (Integral Image)
  final iW = sw + 1;
  final integral = Float64List((sh + 1) * iW);

  for (var y = 0; y < sh; y++) {
    final eRow = y * sw;
    final iRow = (y + 1) * iW;
    final iPrevRow = y * iW;
    var rowSum = 0.0;
    for (var x = 0; x < sw; x++) {
      rowSum += energy[eRow + x];
      integral[iRow + (x + 1)] = integral[iPrevRow + (x + 1)] + rowSum;
    }
  }

  double windowEnergy(int rx0, int ry0, int rx1, int ry1) {
    final r0 = ry0.clamp(0, sh);
    final r1 = ry1.clamp(0, sh);
    final c0 = rx0.clamp(0, sw);
    final c1 = rx1.clamp(0, sw);
    final iRow1 = r1 * iW;
    final iRow0 = r0 * iW;
    return integral[iRow1 + c1] -
        integral[iRow0 + c1] -
        integral[iRow1 + c0] +
        integral[iRow0 + c0];
  }

  // 7. 滑动窗口寻找最大能量坐标
  final maxX = srcW - intCropW;
  final maxY = srcH - intCropH;

  // 7.1 水平单轴滑动（最常见：太宽裁两侧）
  if (maxX > 0 && maxY <= 0) {
    final snw = math.max(1, (intCropW * sw / srcW).round());
    final snh = sh;
    final step = math.max(1, (srcW / sw).round());

    var bestScore = -1.0;
    var bestX = (srcW - intCropW) ~/ 2; // 默认居中兜底

    for (var candX = 0; candX <= maxX; candX += step) {
      final rx0 = (candX * sw / srcW).round();
      final rx1 = rx0 + snw;
      final score = windowEnergy(rx0, 0, rx1, snh);
      if (score > bestScore) {
        bestScore = score;
        bestX = candX;
      }
    }
    // 补测最后一格
    if (maxX % step != 0) {
      final rx0 = (maxX * sw / srcW).round();
      final rx1 = rx0 + snw;
      final score = windowEnergy(rx0, 0, rx1, snh);
      if (score > bestScore) {
        bestX = maxX;
      }
    }
    return Rect.fromLTWH(
      bestX.toDouble(),
      0,
      intCropW.toDouble(),
      intCropH.toDouble(),
    );
  }

  // 7.2 垂直单轴滑动（太高裁上下）
  if (maxY > 0 && maxX <= 0) {
    final snw = sw;
    final snh = math.max(1, (intCropH * sh / srcH).round());
    final step = math.max(1, (srcH / sh).round());

    var bestScore = -1.0;
    var bestY = (srcH - intCropH) ~/ 2; // 默认居中兜底

    for (var candY = 0; candY <= maxY; candY += step) {
      final ry0 = (candY * sh / srcH).round();
      final ry1 = ry0 + snh;
      final score = windowEnergy(0, ry0, snw, ry1);
      if (score > bestScore) {
        bestScore = score;
        bestY = candY;
      }
    }
    if (maxY % step != 0) {
      final ry0 = (maxY * sh / srcH).round();
      final ry1 = ry0 + snh;
      final score = windowEnergy(0, ry0, snw, ry1);
      if (score > bestScore) {
        bestY = maxY;
      }
    }
    return Rect.fromLTWH(
      0,
      bestY.toDouble(),
      intCropW.toDouble(),
      intCropH.toDouble(),
    );
  }

  // 7.3 双轴滑动
  final snw = math.max(1, (intCropW * sw / srcW).round());
  final snh = math.max(1, (intCropH * sh / srcH).round());
  final stepX = math.max(1, (srcW / sw).round());
  final stepY = math.max(1, (srcH / sh).round());

  var bestScore = -1.0;
  var bestX = (srcW - intCropW) ~/ 2;
  var bestY = (srcH - intCropH) ~/ 2;

  for (var candY = 0; candY <= maxY; candY += stepY) {
    final ry0 = (candY * sh / srcH).round();
    final ry1 = ry0 + snh;
    for (var candX = 0; candX <= maxX; candX += stepX) {
      final rx0 = (candX * sw / srcW).round();
      final rx1 = rx0 + snw;
      final score = windowEnergy(rx0, ry0, rx1, ry1);
      if (score > bestScore) {
        bestScore = score;
        bestX = candX;
        bestY = candY;
      }
    }
  }

  return Rect.fromLTWH(
    bestX.toDouble(),
    bestY.toDouble(),
    intCropW.toDouble(),
    intCropH.toDouble(),
  );
}
