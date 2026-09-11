import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:jigsawpuzzle/logic/cache/image_cache_manager.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';

@immutable
class AppImageKey {
  const AppImageKey({
    required this.filePath,
    required this.dimension,
    required this.scale,
  });

  final String filePath;
  final ThumbnailDimension dimension;
  final double scale;

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is AppImageKey &&
        other.filePath == filePath &&
        other.dimension == dimension &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(filePath, dimension, scale);

  @override
  String toString() =>
      '${describeIdentity(this)}("$filePath", dim: ${dimension.pixels}, scale: $scale)';
}

/// 基于工业级三级分级缓存系统实现的 Flutter 原生 [ImageProvider]
///
/// 具备以下特性：
/// 1. 优先从 L1 内存中极速秒取字节 (耗时 < 0.001ms)；
/// 2. 彻底杜绝主线程任何同步磁盘操作 (No existsSync / No sync blocking I/O)；
/// 3. 缩略图缓存未命中时原图直出：不进 EngineTaskQueue 排队生成，
///    由原生 C++ 解码器在 getTargetSize 阶段降采样，毫秒级出图；
/// 4. 缓存探测异常平滑降级读原图，绝不因缓存链路故障导致永久裂图。
class AppCachedImageProvider extends ImageProvider<AppImageKey> {
  const AppCachedImageProvider(
    this.filePath, {
    this.dimension = ThumbnailDimension.card,
    this.scale = 1.0,
  });

  final String filePath;
  final ThumbnailDimension dimension;
  final double scale;

  @override
  Future<AppImageKey> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<AppImageKey>(
      AppImageKey(filePath: filePath, dimension: dimension, scale: scale),
    );
  }

  @override
  ImageStreamCompleter loadImage(AppImageKey key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: key.filePath,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<AppImageKey>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    AppImageKey key,
    ImageDecoderCallback decode,
  ) async {
    Uint8List? bytes;
    // 1. 仅查询已有缓存（L1 内存 → L2 磁盘索引），绝不触发 L3 排队生成。
    //    这是“十几秒不出图”问题的最小修复：此前 L1/L2 未命中时，
    //    getThumbnailBytes 会把任务推入全局 EngineTaskQueue（并发 2~4）排队，
    //    纯 Dart 软解单张 0.5~1.5s，一屏 20~30 张卡片排队可达 10~30s。
    //    现在未命中直接走下面第 2 步原图直出，由原生 C++ 解码器在
    //    getTargetSize 阶段降采样，毫秒级完成，与选择难度面板同路径同速度。
    try {
      final manager = ImageCacheManager.instance;
      bytes = manager.getCachedThumbnailBytesFromMemory(
        key.filePath,
        dimension: key.dimension,
      );
      if (bytes == null && manager.isThumbnailCached(key.filePath)) {
        final thumbPath = manager.getThumbnailFilePath(
          key.filePath,
          dimension: key.dimension,
        );
        if (thumbPath != null) {
          final thumbFile = File(thumbPath);
          if (await thumbFile.exists()) {
            bytes = await thumbFile.readAsBytes();
          }
        }
      }
    } catch (e, st) {
      // 缓存查询异常不致命：记录后继续原图直出，杜绝任何 rethrow 导致永久裂图
      AppLogger.imageCache.warning(
        'Cached-thumbnail probe failed '
        '${AppLogger.sanitizePath(key.filePath)}',
        e,
        st,
      );
    }

    // 2. 原图直出：缩略图缓存未命中时直接读取原图（异步 I/O），
    //    decode() 的 getTargetSize 会在原生解码期按档位长边下采样。
    //    注意：此路径不再后台排队生成磁盘缩略图文件（无预热），
    //    L2 缩略图仍由既有的显式调用方（下载/裁切管线）按原逻辑生成。
    if (bytes == null || bytes.isEmpty) {
      final rawFile = File(key.filePath);
      if (await rawFile.exists()) {
        bytes = await rawFile.readAsBytes();
      }
    }

    if (bytes == null || bytes.isEmpty) {
      throw StateError('Loaded image bytes is empty: ${key.filePath}');
    }

    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(
      buffer,
      getTargetSize: (intrinsicWidth, intrinsicHeight) {
        if (intrinsicWidth <= 0 || intrinsicHeight <= 0) {
          return const ui.TargetImageSize(width: 1, height: 1);
        }
        final targetDim = key.dimension.pixels;
        if (intrinsicWidth > targetDim || intrinsicHeight > targetDim) {
          final ratio =
              targetDim /
              (intrinsicWidth > intrinsicHeight
                  ? intrinsicWidth
                  : intrinsicHeight);
          return ui.TargetImageSize(
            width: math.max(1, (intrinsicWidth * ratio).round()),
            height: math.max(1, (intrinsicHeight * ratio).round()),
          );
        }
        return ui.TargetImageSize(
          width: intrinsicWidth,
          height: intrinsicHeight,
        );
      },
    );
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is AppCachedImageProvider &&
        other.filePath == filePath &&
        other.dimension == dimension &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(filePath, dimension, scale);

  @override
  String toString() =>
      '${describeIdentity(this)}("$filePath", dim: ${dimension.pixels})';
}
