import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:jigsawpuzzle/logic/image_crop.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';

/// 传递至后台 Isolate 的居中裁剪与智能裁切处理参数负载（设计 §2.2 裁剪适配）
class CropTaskParams {
  const CropTaskParams({
    required this.rawBytes,
    this.targetRatio,
    this.quality = 90,
    this.smartCrop = true,
  });

  final Uint8List rawBytes;

  /// 目标比例（cols / rows）。为 null 时自动选取标准画幅（1:1, 2:3, 3:2, 3:4, 4:3）中
  /// 面积损失最小的标准比例（ZIP 图包导入场景）。
  final double? targetRatio;
  final int quality;

  /// 是否启用主体感知智能裁切（默认启用）。为 false 时回退几何居中裁切。
  final bool smartCrop;
}

/// 独立的后台 Isolate 图像裁剪规格化处理器（纯 Dart 逻辑，零 Flutter UI 依赖）
///
/// 原图入库规格化（[generateCroppedBytesFromBytes]）：
/// 针对 ZIP 图包导入等比例不可控的源图，智能裁切/居中裁切至标准比例，
/// 保证入库后拼图切片网格为纯正方形。
class ThumbnailGenerator {
  const ThumbnailGenerator._();

  /// 在独立后台 Isolate 中对内存图片字节执行智能或居中裁剪（只裁不缩），返回 JPEG 字节。
  ///
  /// [targetRatio] 为 null 时自动选取面积损失最小的标准比例（ZIP 图包导入入库用，
  /// 设计 §2.2）；已是标准比例（损失 ≤ 1%）的图**原样返回不重编码**，零质量损耗。
  /// [smartCrop] 为 true 时启用主体显著性感知智能裁切（默认启用），为 false 时回退纯几何居中裁切。
  static Future<Uint8List?> generateCroppedBytesFromBytes({
    required Uint8List rawBytes,
    double? targetRatio,
    int quality = 90,
    bool smartCrop = true,
  }) async {
    if (rawBytes.isEmpty) return null;
    final params = CropTaskParams(
      rawBytes: rawBytes,
      targetRatio: targetRatio,
      quality: quality,
      smartCrop: smartCrop,
    );
    try {
      return await compute(_processCropToBytesIsolate, params);
    } catch (e, st) {
      AppLogger.thumbnail.severe(
        'Failed to generate cropped bytes len=${rawBytes.length}',
        e,
        st,
      );
      return null;
    }
  }

  /// 后台 Isolate 核心运算例程：智能/居中裁剪并返回 JPEG 字节。
  /// 默认使用 [findSmartCropRect] 进行主体显著性能量寻优；
  /// 标准比例图（损失 ≤ 1%）直接返回原始字节，避免无谓重编码。
  /// ⚠️ 错误一律抛出（不吞 null），由主 Isolate 的 catch 记录日志。
  static Uint8List? _processCropToBytesIsolate(CropTaskParams params) {
    try {
      final original = img.decodeImage(params.rawBytes);
      if (original == null) {
        throw StateError(
          'crop decodeImage returned null: bytes=${params.rawBytes.length} '
          'first4=${params.rawBytes.take(4).toList()}',
        );
      }
      final srcW = original.width;
      final srcH = original.height;
      if (srcW <= 0 || srcH <= 0) {
        throw StateError('crop invalid source dimensions ${srcW}x$srcH');
      }

      final srcRatio = srcW / srcH;
      final target =
          params.targetRatio ?? nearestStandardRatio(width: srcW, height: srcH);

      // 已是目标比例（容差 1%）：原样返回，零重编码损耗
      final loss = 1.0 - min(srcRatio / target, target / srcRatio);
      if (loss <= 0.01) {
        return params.rawBytes;
      }

      int cropW;
      int cropH;
      int dx;
      int dy;
      if (params.smartCrop) {
        final rect = findSmartCropRect(original, targetRatio: target);
        cropW = rect.width.round();
        cropH = rect.height.round();
        dx = rect.left.round();
        dy = rect.top.round();
      } else {
        if (srcRatio > target) {
          // 太宽：裁宽，高度不变
          cropH = srcH;
          cropW = (srcH * target).round();
          dx = ((srcW - cropW) / 2).round();
          dy = 0;
        } else {
          // 太高：裁高，宽度不变
          cropW = srcW;
          cropH = (srcW / target).round();
          dx = 0;
          dy = ((srcH - cropH) / 2).round();
        }
      }

      if (cropW <= 0 || cropH <= 0 || dx < 0 || dy < 0) {
        throw StateError(
          'crop invalid rect ${cropW}x$cropH @($dx,$dy) src=${srcW}x$srcH',
        );
      }

      final cropped = img.copyCrop(
        original,
        x: dx,
        y: dy,
        width: cropW,
        height: cropH,
      );
      final jpgBytes = img.encodeJpg(cropped, quality: params.quality);
      if (jpgBytes.isEmpty) {
        throw StateError('crop encodeJpg returned empty');
      }
      return Uint8List.fromList(jpgBytes);
    } catch (e) {
      if (e is StateError) rethrow;
      throw StateError('crop isolate failed: $e');
    }
  }
}
