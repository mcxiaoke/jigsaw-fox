import 'package:flutter/material.dart';

import '../logic/cache/level_image_resolver.dart';
import '../logic/content/models/puzzle_level_item.dart';
import 'app_cached_image.dart';

/// 懒落地关卡缩略：可视时后台下载原图到本地，再以本地文件生成缩略
///
/// 保证“见缩略必可玩”：缩略显示即代表原图已在 `appDocumentsDir` 落盘，
/// 点击直接 `File.readAsBytes` 进 `GamePage`，飞行模式亦可。
class LazyLevelImage extends StatefulWidget {
  const LazyLevelImage({
    super.key,
    required this.level,
    this.fit = BoxFit.cover,
    this.targetDimension,
    this.placeholder,
    this.errorWidget,
  });

  final PuzzleLevelItem level;
  final BoxFit fit;
  final dynamic targetDimension;
  final Widget? placeholder;
  final Widget? errorWidget;

  @override
  State<LazyLevelImage> createState() => _LazyLevelImageState();
}

class _LazyLevelImageState extends State<LazyLevelImage> {
  String? _resolvedPath;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant LazyLevelImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level.id != widget.level.id ||
        oldWidget.level.imagePathOrUrl != widget.level.imagePathOrUrl) {
      _resolvedPath = null;
      _failed = false;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final path = widget.level.imagePathOrUrl;

    // 资产/已落地本地：同步直接显示，无需异步
    if (path.startsWith('assets/') ||
        (widget.level.isLocalFile && path.isNotEmpty)) {
      // 仍走异步校验是否存在，避免曾标记本地但文件被误删
      if (widget.level.isLocalFile) {
        // 快路径：文件存在则直接用
        // 实际校验在 LevelImageResolver 内
      }
    }

    try {
      final localPath = await LevelImageResolver.instance.resolveLevelLocalPath(
        widget.level,
      );
      if (!mounted) return;
      // 若解析后仍是 http（下载失败），标记失败走 errorWidget
      if (localPath.startsWith('http')) {
        setState(() => _failed = true);
        return;
      }
      setState(() => _resolvedPath = localPath);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 解析中：占位（与 AppCachedImage 默认 placeholder 一致）
    if (_resolvedPath == null && !_failed) {
      if (widget.level.imagePathOrUrl.startsWith('assets/')) {
        // 资产可直接显示，无需等待
        return AppCachedImage(
          imagePathOrUrl: widget.level.imagePathOrUrl,
          fit: widget.fit,
          placeholder: widget.placeholder,
          errorWidget: widget.errorWidget,
        );
      }
      // 网络：等待下载时显示占位，下载完成后切本地
      return widget.placeholder ??
          Container(
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

    if (_failed) {
      return widget.errorWidget ??
          Container(
            color: Colors.grey.shade200,
            alignment: Alignment.center,
            child: Icon(
              Icons.broken_image_outlined,
              color: Colors.grey.shade400,
              size: 24,
            ),
          );
    }

    return AppCachedImage(
      imagePathOrUrl: _resolvedPath!,
      fit: widget.fit,
      placeholder: widget.placeholder,
      errorWidget: widget.errorWidget,
    );
  }
}
