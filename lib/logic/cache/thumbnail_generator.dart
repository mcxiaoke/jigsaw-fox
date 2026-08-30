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
}
