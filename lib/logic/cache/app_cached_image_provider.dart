import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'image_cache_manager.dart';

@immutable
class AppImageKey {
  const AppImageKey({
    required this.filePath,
    required this.targetDimension,
    required this.scale,
  });

  final String filePath;
  final int targetDimension;
  final double scale;

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is AppImageKey &&
        other.filePath == filePath &&
        other.targetDimension == targetDimension &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(filePath, targetDimension, scale);

  @override
  String toString() => '${describeIdentity(this)}("$filePath", dim: $targetDimension, scale: $scale)';
}

/// 基于工业级三级分级缓存系统实现的 Flutter 原生 [ImageProvider]
///
/// 具备以下特性：
/// 1. 优先从 L1 内存中极速秒取字节 (耗时 < 0.001ms)；
/// 2. 彻底杜绝主线程任何同步磁盘操作 (No existsSync / No sync blocking I/O)；
/// 3. L3 未命中时自动进入并发受控调度队列 (EngineTaskQueue)，防止 CPU 洪峰与 UI 掉帧；
/// 4. 配合 GPU 显存限制 TargetImageSize 下采样。
class AppCachedImageProvider extends ImageProvider<AppImageKey> {
  const AppCachedImageProvider(
    this.filePath, {
    this.targetDimension = ImageCacheManager.kDefaultThumbnailDimension,
    this.scale = 1.0,
  });

  final String filePath;
  final int targetDimension;
  final double scale;

  @override
  Future<AppImageKey> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<AppImageKey>(
      AppImageKey(
        filePath: filePath,
        targetDimension: targetDimension,
        scale: scale,
      ),
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

  Future<ui.Codec> _loadAsync(AppImageKey key, ImageDecoderCallback decode) async {
    try {
      // 1. 通过分级缓存系统获取缩略图字节 (L1 内存 -> L2 磁盘 -> L3 调度生成)
      Uint8List? bytes = await ImageCacheManager.instance.getThumbnailBytes(
        key.filePath,
        targetDimension: key.targetDimension,
      );

      // 2. 若分级缓存未返回，回退异步读取原始文件
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
          if (intrinsicWidth > key.targetDimension || intrinsicHeight > key.targetDimension) {
            final double ratio = key.targetDimension / (intrinsicWidth > intrinsicHeight ? intrinsicWidth : intrinsicHeight);
            return ui.TargetImageSize(
              width: (intrinsicWidth * ratio).round(),
              height: (intrinsicHeight * ratio).round(),
            );
          }
          return ui.TargetImageSize(width: intrinsicWidth, height: intrinsicHeight);
        },
      );
    } catch (e) {
      debugPrint('[AppCachedImageProvider:Error] Failed to load image: ${key.filePath}, error: $e');
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is AppCachedImageProvider &&
        other.filePath == filePath &&
        other.targetDimension == targetDimension &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(filePath, targetDimension, scale);

  @override
  String toString() => '${describeIdentity(this)}("$filePath", targetDim: $targetDimension)';
}
