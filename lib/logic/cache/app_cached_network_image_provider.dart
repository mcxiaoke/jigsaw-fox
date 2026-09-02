import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../services/app_logger.dart';
import 'image_cache_manager.dart';

/// 网络图片的 ImageProvider，复用与本地文件相同的三级缓存体系
///
/// 链路：L1 内存 (`MemoryCache`) → L2 磁盘 `thumbnail_cache/thumb_<hash>_<dim>.jpg`
/// → L3 下载+后台 Isolate 缩略图生成（`ImageCacheManager.getNetworkThumbnailBytes`）。
/// 解码期通过 `getTargetSize` 钳制长边，避免全尺寸位图进入引擎 L3。
@immutable
class AppNetworkImageKey {
  const AppNetworkImageKey({
    required this.url,
    required this.dimension,
    required this.scale,
  });

  final String url;
  final ThumbnailDimension dimension;
  final double scale;

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is AppNetworkImageKey &&
        other.url == url &&
        other.dimension == dimension &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(url, dimension, scale);

  @override
  String toString() =>
      '${describeIdentity(this)}("$url", dim: ${dimension.pixels}, scale: $scale)';
}

/// 基于 `ImageCacheManager.getNetworkThumbnailBytes` 的网络缩略图 Provider
///
/// 与 `AppCachedImageProvider` 对称：本地文件走 `getThumbnailBytes`，网络 URL 走
/// `getNetworkThumbnailBytes`，最终都落到同一 `thumbnail_cache` 目录、同一 L1/L2。
class AppCachedNetworkImageProvider extends ImageProvider<AppNetworkImageKey> {
  const AppCachedNetworkImageProvider(
    this.url, {
    this.dimension = ThumbnailDimension.eventCover,
    this.scale = 1.0,
  });

  final String url;
  final ThumbnailDimension dimension;
  final double scale;

  @override
  Future<AppNetworkImageKey> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<AppNetworkImageKey>(
      AppNetworkImageKey(url: url, dimension: dimension, scale: scale),
    );
  }

  @override
  ImageStreamCompleter loadImage(
    AppNetworkImageKey key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<AppNetworkImageKey>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    AppNetworkImageKey key,
    ImageDecoderCallback decode,
  ) async {
    try {
      // 优先走三级缓存（L1→L2→L3 下载+生成）
      Uint8List? bytes = await ImageCacheManager.instance
          .getNetworkThumbnailBytes(key.url, dimension: key.dimension);

      if (bytes == null || bytes.isEmpty) {
        throw StateError('Failed to load network thumbnail: ${key.url}');
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
              width: (intrinsicWidth * ratio).round(),
              height: (intrinsicHeight * ratio).round(),
            );
          }
          return ui.TargetImageSize(
            width: intrinsicWidth,
            height: intrinsicHeight,
          );
        },
      );
    } catch (e, st) {
      AppLogger.imageCache.severe(
        'Failed to load network image ${AppLogger.sanitizeUrl(key.url)}',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is AppCachedNetworkImageProvider &&
        other.url == url &&
        other.dimension == dimension &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(url, dimension, scale);

  @override
  String toString() =>
      '${describeIdentity(this)}("$url", dim: ${dimension.pixels})';
}
