import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../logic/cache/app_cached_image_provider.dart';
import '../logic/cache/app_cached_network_image_provider.dart';
import '../logic/cache/image_cache_manager.dart';

/// Convenient, high-performance UI Widget for displaying images with built-in
/// disk thumbnail caching, memory downsampling (`ResizeImage`), placeholder shimmer, and error fallbacks.
///
/// Supports:
/// - Local file paths (`/path/to/image.jpg`)
/// - Asset paths (`assets/images/sample.jpg`)
/// - In-memory bytes (`Uint8List`)
class AppCachedImage extends StatelessWidget {
  const AppCachedImage({
    super.key,
    this.imagePathOrUrl,
    this.memoryBytes,
    this.width,
    this.height,
    this.targetDimension = ThumbnailDimension.card,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.borderRadius,
    this.placeholder,
    this.errorWidget,
    this.colorFilter,
    this.fadeInDuration = const Duration(milliseconds: 200),
    this.useThumbnailCache = true,
  });

  /// Path to the image (local file path or asset key)
  final String? imagePathOrUrl;

  /// In-memory image bytes (optional alternative)
  final Uint8List? memoryBytes;

  final double? width;
  final double? height;

  /// 解码与缓存档位：所有图片统一从预定义档位中选择，
  /// 避免各调用点传不同像素值造成同一源图生成多份缩略图。
  final ThumbnailDimension targetDimension;

  final BoxFit fit;
  final Alignment alignment;
  final BorderRadius? borderRadius;
  final Widget? placeholder;
  final Widget? errorWidget;
  final ColorFilter? colorFilter;
  final Duration fadeInDuration;

  /// Whether to utilize disk thumbnail caching for local files
  final bool useThumbnailCache;

  ImageProvider _wrapResize(ImageProvider provider) {
    // 仅按单边等比下采样解码，保证原图宽高比绝对不被破坏，由外层 Image(fit: BoxFit.cover) 执行等比居中裁剪
    return ResizeImage(
      provider,
      width: targetDimension.pixels,
      allowUpscaling: false,
    );
  }

  ImageProvider _resolveImageProvider() {
    if (memoryBytes != null && memoryBytes!.isNotEmpty) {
      final memProvider = MemoryImage(memoryBytes!);
      return _wrapResize(memProvider);
    }

    final path = imagePathOrUrl ?? '';
    if (path.isEmpty) {
      return const AssetImage('assets/images/sample_01.jpg');
    }

    // 1. 网络图片（统一走三级缓存：L1 内存 → L2 磁盘 thumbnail_cache → L3 下载+后台缩略）
    // 与本地文件共用同一缓存目录与 key 体系，解决此前 NetworkImage 无磁盘缓存、每次重联网的问题
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return AppCachedNetworkImageProvider(path, dimension: targetDimension);
    }

    // 2. Assets 打包静态资源
    if (path.startsWith('assets/')) {
      final assetProvider = AssetImage(path);
      return _wrapResize(assetProvider);
    }

    // 3. Local file 本地文件路径
    if (useThumbnailCache) {
      return AppCachedImageProvider(path, dimension: targetDimension);
    } else {
      final fileProvider = FileImage(File(path));
      return _wrapResize(fileProvider);
    }
  }

  Widget _defaultPlaceholder() {
    return Container(
      color: Colors.grey.shade200,
      alignment: Alignment.center,
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Colors.grey.shade400,
        ),
      ),
    );
  }

  Widget _defaultError() {
    return Container(
      color: Colors.grey.shade200,
      alignment: Alignment.center,
      child: Icon(
        PhosphorIconsRegular.imageBroken,
        color: Colors.grey.shade400,
        size: 24,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final imageProvider = _resolveImageProvider();

    Widget content = Image(
      image: imageProvider,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || fadeInDuration == Duration.zero) {
          return child;
        }
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: fadeInDuration,
          curve: Curves.easeOut,
          child: frame == null ? (placeholder ?? _defaultPlaceholder()) : child,
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return errorWidget ?? _defaultError();
      },
    );

    if (colorFilter != null) {
      content = ColorFiltered(
        colorFilter: colorFilter!,
        child: content,
      );
    }

    if (borderRadius != null) {
      content = ClipRRect(
        borderRadius: borderRadius!,
        child: content,
      );
    }

    return content;
  }
}
