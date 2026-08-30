import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../services/app_logger.dart';

/// 传递至后台 Isolate 的缩略图处理参数负载
class ThumbnailTaskParams {
  const ThumbnailTaskParams({
    this.sourceFilePath,
    this.rawBytes,
    this.targetFilePath,
    this.targetDimension = 360,
    this.quality = 80,
  });

  final String? sourceFilePath;
  final Uint8List? rawBytes;
  final String? targetFilePath;
  final int targetDimension;
  final int quality;
}

/// 传递至后台 Isolate 的居中裁剪处理参数负载（设计 §2.2 裁剪适配）
class CropTaskParams {
  const CropTaskParams({
    required this.rawBytes,
    this.targetRatio,
    this.quality = 90,
  });

  final Uint8List rawBytes;

  /// 目标比例（cols / rows）。为 null 时自动选取 {1:1, 3:2, 2:3} 中
  /// 面积损失最小的标准比例（ZIP 图包导入场景）。
  final double? targetRatio;
  final int quality;
}

/// 独立的后台 Isolate 缩略图生成器
/// 纯 Dart 逻辑，基于二进制与图像矩阵运算，零 Flutter UI 依赖
class ThumbnailGenerator {
  const ThumbnailGenerator._();

  /// 在独立后台 Isolate 中生成下采样缩略图，并返回高质量 JPEG 字节
  static Future<Uint8List?> generateThumbnailBytes({
    required String sourceFilePath,
    int targetDimension = 360,
    int quality = 80,
  }) async {
    final params = ThumbnailTaskParams(
      sourceFilePath: sourceFilePath,
      targetDimension: targetDimension,
      quality: quality,
    );

    try {
      return await compute(_processThumbnailToBytesIsolate, params);
    } catch (e, st) {
      AppLogger.thumbnail.severe('Failed to generate thumbnail bytes path=${AppLogger.sanitizePath(params.sourceFilePath ?? '')}', e, st);
      return null;
    }
  }

  /// 针对内存中的原始图片字节直接在后台 Isolate 下采样
  static Future<Uint8List?> generateThumbnailFromBytes({
    required Uint8List rawBytes,
    int targetDimension = 360,
    int quality = 80,
  }) async {
    final params = ThumbnailTaskParams(
      rawBytes: rawBytes,
      targetDimension: targetDimension,
      quality: quality,
    );

    try {
      return await compute(_processThumbnailToBytesIsolate, params);
    } catch (e, st) {
      AppLogger.thumbnail.severe('Failed to generate from bytes len=${rawBytes.length}', e, st);
      return null;
    }
  }

  /// 在后台 Isolate 中生成缩略图并直接写入目标文件
  static Future<bool> generateThumbnail({
    required String sourceFilePath,
    required String targetFilePath,
    int targetDimension = 360,
    int quality = 80,
  }) async {
    final params = ThumbnailTaskParams(
      sourceFilePath: sourceFilePath,
      targetFilePath: targetFilePath,
      targetDimension: targetDimension,
      quality: quality,
    );

    try {
      return await compute(_processThumbnailToFileIsolate, params);
    } catch (e, st) {
      AppLogger.thumbnail.severe('Failed to generate thumbnail file src=${AppLogger.sanitizePath(sourceFilePath)} dst=${AppLogger.sanitizePath(targetFilePath)}', e, st);
      return false;
    }
  }

  /// 后台 Isolate 核心运算例程：返回缩略图 JPEG 字节
  static Uint8List? _processThumbnailToBytesIsolate(ThumbnailTaskParams params) {
    try {
      Uint8List? rawBytes = params.rawBytes;
      if (rawBytes == null && params.sourceFilePath != null) {
        final sourceFile = File(params.sourceFilePath!);
        if (!sourceFile.existsSync()) return null;
        rawBytes = sourceFile.readAsBytesSync();
      }

      if (rawBytes == null || rawBytes.isEmpty) return null;

      final original = img.decodeImage(rawBytes);
      if (original == null) return null;

      final srcW = original.width;
      final srcH = original.height;
      if (srcW <= 0 || srcH <= 0) return null;

      final targetDim = params.targetDimension;
      int dstW, dstH;
      if (srcW <= targetDim && srcH <= targetDim) {
        dstW = srcW;
        dstH = srcH;
      } else {
        final maxSide = max(srcW, srcH);
        final scale = targetDim / maxSide;
        dstW = max(1, (srcW * scale).round());
        dstH = max(1, (srcH * scale).round());
      }

      final resized = img.copyResize(
        original,
        width: dstW,
        height: dstH,
        interpolation: img.Interpolation.linear,
      );

      final jpgBytes = img.encodeJpg(resized, quality: params.quality);
      return Uint8List.fromList(jpgBytes);
    } catch (e) {
      return null;
    }
  }

  /// 后台 Isolate 核心运算例程：写入目标文件
  static bool _processThumbnailToFileIsolate(ThumbnailTaskParams params) {
    try {
      final jpgBytes = _processThumbnailToBytesIsolate(params);
      if (jpgBytes == null || jpgBytes.isEmpty || params.targetFilePath == null) {
        return false;
      }

      final targetFile = File(params.targetFilePath!);
      final parentDir = targetFile.parent;
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }

      targetFile.writeAsBytesSync(jpgBytes, flush: true);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 在独立后台 Isolate 中对内存图片字节执行居中裁剪（只裁不缩），返回 JPEG 字节。
  ///
  /// [targetRatio] 为 null 时自动选取面积损失最小的标准比例（ZIP 图包导入入库用，
  /// 设计 §2.2）；已是标准比例（损失 ≤ 1%）的图**原样返回不重编码**，零质量损耗。
  static Future<Uint8List?> generateCroppedBytesFromBytes({
    required Uint8List rawBytes,
    double? targetRatio,
    int quality = 90,
  }) async {
    if (rawBytes.isEmpty) return null;
    final params = CropTaskParams(rawBytes: rawBytes, targetRatio: targetRatio, quality: quality);
    try {
      return await compute(_processCropToBytesIsolate, params);
    } catch (e, st) {
      AppLogger.thumbnail.severe('Failed to generate cropped bytes len=${rawBytes.length}', e, st);
      return null;
    }
  }

  /// 后台 Isolate 核心运算例程：居中裁剪并返回 JPEG 字节。
  /// `ratio > target` 裁宽（左右各半），否则裁高（上下各半）。
  /// 标准比例图（损失 ≤ 1%）直接返回原始字节，避免无谓重编码。
  static Uint8List? _processCropToBytesIsolate(CropTaskParams params) {
    try {
      final original = img.decodeImage(params.rawBytes);
      if (original == null) return null;
      final srcW = original.width;
      final srcH = original.height;
      if (srcW <= 0 || srcH <= 0) return null;

      final srcRatio = srcW / srcH;
      final target = params.targetRatio ?? _nearestStandardRatio(srcW, srcH);

      // 已是目标比例（容差 1%）：原样返回，零重编码损耗
      final loss = 1.0 - min(srcRatio / target, target / srcRatio);
      if (loss <= 0.01) {
        return params.rawBytes;
      }

      int cropW, cropH, dx, dy;
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

      if (cropW <= 0 || cropH <= 0 || dx < 0 || dy < 0) return null;

      final cropped = img.copyCrop(original, x: dx, y: dy, width: cropW, height: cropH);
      final jpgBytes = img.encodeJpg(cropped, quality: params.quality);
      return Uint8List.fromList(jpgBytes);
    } catch (e) {
      return null;
    }
  }

  /// 选取 {1:1, 3:2, 2:3} 中面积损失最小的目标比例（与 image_crop.dart 一致，isolate 内避免跨库依赖）
  static double _nearestStandardRatio(int width, int height) {
    if (width <= 0 || height <= 0) return 1.0;
    final r = width / height;
    const candidates = [1.0, 1.5, 2 / 3];
    var best = candidates.first;
    var minLoss = 1.0 - min(r / best, best / r);
    for (final c in candidates) {
      final loss = 1.0 - min(r / c, c / r);
      if (loss < minLoss) {
        minLoss = loss;
        best = c;
      }
    }
    return best;
  }
}
