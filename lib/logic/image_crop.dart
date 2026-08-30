/// 图片居中裁剪适配（设计 §2.2：移除 3:4/4:3 后的必备配套）
///
/// 仅用于 ZIP 图包导入入库时的静默裁切（设计 §2.2 管线路径）：
/// 任意比例图片先居中裁剪到 {1:1, 3:2, 2:3} 中面积损失最小的档位，
/// 保证入库后进游戏切片 `srcPieceW == srcPieceH`（纯正方形 cell）。
///
/// 规则：
/// - 只裁不缩：保持原分辨率，避免放大损失
/// - 居中裁剪：`ratio > target` 裁宽，否则裁高
/// - UGC / 运营导出图不走此路径（前者有可视裁剪交互，后者打包工具已保证标准比例）
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

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
Rect centerCropRect({required int imageWidth, required int imageHeight, required double targetRatio}) {
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
