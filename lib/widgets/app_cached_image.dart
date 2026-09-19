import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/logic/cache/level_image_resolver.dart';
import 'package:jigsawpuzzle/logic/cache/thumbnail_dimension.dart';
import 'package:jigsawpuzzle/widgets/puzzle_card_placeholder.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

export 'package:jigsawpuzzle/logic/cache/thumbnail_dimension.dart';

/// 高性能统一图片展示组件：
/// - 本地文件 / 资产 / 内存字节：由 Flutter 原生 C++ 解码器硬件加速等比降采样（`ResizeImage`，3~5ms 秒出）
/// - 解码后纹理直接进入 Flutter 引擎 `PaintingBinding.instance.imageCache`（默认 100MB / 1000 张 LRU）
/// - 远程网络 URL：首次由 Single-Flight 单次下载落盘为本地文件后自动切换展示，离线永久可用
/// - 双层 Stack 骨架屏淡入修复，消除白洞与透明跳变
class AppCachedImage extends StatelessWidget {
  const AppCachedImage({
    super.key,
    this.imagePathOrUrl,
    this.memoryBytes,
    this.width,
    this.height,
    this.targetDimension = kDefaultThumbnailDimension,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.borderRadius,
    this.placeholder,
    this.errorWidget,
    this.colorFilter,
    this.fadeInDuration = const Duration(milliseconds: 200),
  });

  /// 图片路径（本地文件路径、assets 资源键或网络 URL）
  final String? imagePathOrUrl;

  /// 内存图片字节数据（可选替代源）
  final Uint8List? memoryBytes;

  final double? width;
  final double? height;

  /// 解码与缓存档位：所有图片统一从预定义档位中选择
  final ThumbnailDimension targetDimension;

  final BoxFit fit;
  final Alignment alignment;
  final BorderRadius? borderRadius;
  final Widget? placeholder;
  final Widget? errorWidget;
  final ColorFilter? colorFilter;
  final Duration fadeInDuration;

  ImageProvider _wrapResize(ImageProvider provider) {
    // 仅按单边等比下采样解码，保证原图宽高比绝对不被破坏，由外层 Image(fit: BoxFit.cover) 执行等比居中裁剪
    return ResizeImage(
      provider,
      width: targetDimension.pixels,
    );
  }

  ImageProvider _resolveImageProvider() {
    if (memoryBytes != null && memoryBytes!.isNotEmpty) {
      final memProvider = MemoryImage(memoryBytes!);
      return _wrapResize(memProvider);
    }

    final path = imagePathOrUrl ?? '';
    if (path.isEmpty) {
      return _wrapResize(
        MemoryImage(
          Uint8List.fromList(const [
            0x89,
            0x50,
            0x4E,
            0x47,
            0x0D,
            0x0A,
            0x1A,
            0x0A,
            0x00,
            0x00,
            0x00,
            0x0D,
            0x49,
            0x48,
            0x44,
            0x52,
            0x00,
            0x00,
            0x00,
            0x01,
            0x00,
            0x00,
            0x00,
            0x01,
            0x08,
            0x06,
            0x00,
            0x00,
            0x00,
            0x1F,
            0x15,
            0xC4,
            0x89,
            0x00,
            0x00,
            0x00,
            0x0A,
            0x49,
            0x44,
            0x41,
            0x54,
            0x78,
            0x9C,
            0x63,
            0x00,
            0x01,
            0x00,
            0x00,
            0x05,
            0x00,
            0x01,
            0x0D,
            0x0A,
            0x2D,
            0xB4,
            0x00,
            0x00,
            0x00,
            0x00,
            0x49,
            0x45,
            0x4E,
            0x44,
            0xAE,
            0x42,
            0x60,
            0x82,
          ]),
        ),
      );
    }

    // 1. Assets 打包静态资源
    if (path.startsWith('assets/')) {
      final assetProvider = AssetImage(path);
      return _wrapResize(assetProvider);
    }

    // 2. Remote URL（进入此处必已落盘为本地文件）
    if (path.startsWith('http://') || path.startsWith('https://')) {
      final localPath = LevelImageResolver.instance.getUrlLocalPathIfAvailable(
        path,
      );
      if (localPath != null && File(localPath).existsSync()) {
        return _wrapResize(FileImage(File(localPath)));
      }
    }

    // 3. Local file 本地文件路径
    final fileProvider = FileImage(File(path));
    return _wrapResize(fileProvider);
  }

  Widget _defaultPlaceholder() {
    return const PuzzleCardPlaceholder();
  }

  Widget _defaultError() {
    return Container(
      color: Colors.grey.shade200,
      alignment: Alignment.center,
      child: Icon(
        PhosphorIconsRegular.arrowClockwise,
        color: Colors.grey.shade400,
        size: 24,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = imagePathOrUrl ?? '';
    final hasMemory = memoryBytes != null && memoryBytes!.isNotEmpty;
    if (path.isEmpty && !hasMemory) {
      return placeholder ?? _defaultPlaceholder();
    }

    // 网络图片未落盘场景：走单次异步落地与自动平滑淡入切换组件
    if (memoryBytes == null &&
        (path.startsWith('http://') || path.startsWith('https://'))) {
      final localPath = LevelImageResolver.instance.getUrlLocalPathIfAvailable(
        path,
      );
      if (localPath == null || !File(localPath).existsSync()) {
        return _NetworkImageLoader(
          url: path,
          width: width,
          height: height,
          targetDimension: targetDimension,
          fit: fit,
          alignment: alignment,
          borderRadius: borderRadius,
          colorFilter: colorFilter,
          placeholder: placeholder ?? _defaultPlaceholder(),
          errorWidget: errorWidget ?? _defaultError(),
          fadeInDuration: fadeInDuration,
        );
      }
    }

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
        return Stack(
          fit: StackFit.passthrough,
          alignment: alignment,
          children: [
            // 1. 底层常规尺寸子节点：由占位图自然撑开 Stack 约束，避免零尺寸塌缩
            if (frame == null) placeholder ?? _defaultPlaceholder(),
            // 2. 顶层常驻平滑淡入：首帧就绪后由 0 淡入到 1.0 覆盖占位
            AnimatedOpacity(
              opacity: frame == null ? 0.0 : 1.0,
              duration: fadeInDuration,
              curve: Curves.easeOut,
              child: child,
            ),
          ],
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return errorWidget ?? _defaultError();
      },
    );

    if (colorFilter != null) {
      content = ColorFiltered(colorFilter: colorFilter!, child: content);
    }

    if (borderRadius != null) {
      content = ClipRRect(borderRadius: borderRadius!, child: content);
    }

    return content;
  }
}

/// 内部私有组件：用于未落盘的远程网络图片（如 Event Banner / Collection 封面），
/// 负责单次触发异步原子落盘，落盘成功后平滑淡入切为本地 FileImage 渲染，离线永久可用。
class _NetworkImageLoader extends StatefulWidget {
  const _NetworkImageLoader({
    required this.url,
    required this.targetDimension,
    required this.placeholder,
    required this.errorWidget,
    required this.fadeInDuration,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.borderRadius,
    this.colorFilter,
  });

  final String url;
  final ThumbnailDimension targetDimension;
  final Widget placeholder;
  final Widget errorWidget;
  final Duration fadeInDuration;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final BorderRadius? borderRadius;
  final ColorFilter? colorFilter;

  @override
  State<_NetworkImageLoader> createState() => _NetworkImageLoaderState();
}

class _NetworkImageLoaderState extends State<_NetworkImageLoader> {
  String? _localPath;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _NetworkImageLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || (_failed && _localPath == null)) {
      _localPath = null;
      _failed = false;
      unawaited(_load());
    }
  }

  void _retry() {
    if (!mounted) return;
    setState(() => _failed = false);
    unawaited(_load());
  }

  Future<void> _load() async {
    final url = widget.url;
    final path = await LevelImageResolver.instance.resolveUrlLocalPath(
      url,
    );
    if (!mounted || widget.url != url) return;
    if (path.isNotEmpty && File(path).existsSync()) {
      setState(() => _localPath = path);
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _retry,
        child: widget.errorWidget,
      );
    }
    if (_localPath == null) {
      var ph = widget.placeholder;
      if (widget.borderRadius != null) {
        ph = ClipRRect(borderRadius: widget.borderRadius!, child: ph);
      }
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: ph,
      );
    }
    return AppCachedImage(
      imagePathOrUrl: _localPath,
      width: widget.width,
      height: widget.height,
      targetDimension: widget.targetDimension,
      fit: widget.fit,
      alignment: widget.alignment,
      borderRadius: widget.borderRadius,
      colorFilter: widget.colorFilter,
      fadeInDuration: widget.fadeInDuration,
    );
  }
}
