import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:jigsawpuzzle/logic/cache/level_image_resolver.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/widgets/app_cached_image.dart';
import 'package:jigsawpuzzle/widgets/puzzle_card_placeholder.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// 懒落地关卡缩略：可视时后台下载原图到本地，再以本地文件生成缩略
///
/// 保证“见缩略必可玩”：缩略显示即代表原图已在 `{appSupportDir}/levels/` 目录落盘，
/// 点击直接 `File.readAsBytes` 进 `GamePage`，飞行模式亦可。
class LazyLevelImage extends StatefulWidget {
  const LazyLevelImage({
    required this.level,
    super.key,
    this.fit = BoxFit.cover,
    this.targetDimension,
    this.placeholder,
    this.errorWidget,
  });

  final PuzzleLevelItem level;
  final BoxFit fit;
  final ThumbnailDimension? targetDimension;
  final Widget? placeholder;
  final Widget? errorWidget;

  @override
  State<LazyLevelImage> createState() => _LazyLevelImageState();
}

class _LazyLevelImageState extends State<LazyLevelImage> {
  String? _resolvedPath;
  bool _failed = false;
  int _resolveToken = 0;
  DateTime? _lastFailureTime;

  @override
  void initState() {
    super.initState();
    _checkSyncHit();
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(covariant LazyLevelImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final isDifferentLevel =
        oldWidget.level.id != widget.level.id ||
        oldWidget.level.imagePathOrUrl != widget.level.imagePathOrUrl;

    if (isDifferentLevel) {
      _resolvedPath = null;
      _failed = false;
      _lastFailureTime = null;
      _checkSyncHit();
      unawaited(_resolve());
    } else if (_failed && _resolvedPath == null) {
      // D-11 防重试风暴：同关卡失败后，非用户主动点击时设置 10 秒冷却退避
      final now = DateTime.now();
      if (_lastFailureTime == null ||
          now.difference(_lastFailureTime!) >= const Duration(seconds: 10)) {
        _failed = false;
        unawaited(_resolve());
      }
    }
  }

  void _retry() {
    if (!mounted) return;
    setState(() {
      _failed = false;
      _lastFailureTime = null;
    });
    unawaited(_resolve());
  }

  void _checkSyncHit() {
    final path = widget.level.imagePathOrUrl;
    if (path.isEmpty || path.startsWith('assets/')) return;
    if (widget.level.isLocalFile && File(path).existsSync()) {
      _resolvedPath = path;
    } else if (path.startsWith('http')) {
      final available = LevelImageResolver.instance.getUrlLocalPathIfAvailable(
        path,
      );
      if (available != null) {
        _resolvedPath = available;
      }
    }
  }

  Future<void> _resolve() async {
    final token = ++_resolveToken;
    final targetLevel = widget.level;
    // P3-2：删除仅含注释、无任何行为的空 if 块。存在性校验统一由
    // LevelImageResolver.resolveLevelLocalPath 完成。
    try {
      final localPath = await LevelImageResolver.instance.resolveLevelLocalPath(
        targetLevel,
      );
      // D-11 代次校验：若已有更新的解析请求发出或已被复用，丢弃旧代次结果，防错图覆盖
      if (!mounted || token != _resolveToken) return;

      // 若解析后仍是 http（下载失败），标记失败走 errorWidget
      if (localPath.startsWith('http')) {
        AppLogger.imageCache.warning(
          'LazyLevelImage resolve returned remote (download failed) '
          'id=${targetLevel.id} url=${AppLogger.sanitizeUrl(localPath)}',
        );
        setState(() {
          _failed = true;
          _lastFailureTime = DateTime.now();
        });
        return;
      }
      setState(() {
        _resolvedPath = localPath;
        _failed = false;
        _lastFailureTime = null;
      });
      // best-effort：记录后降级继续
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      AppLogger.imageCache.warning(
        'LazyLevelImage resolve failed '
        'id=${targetLevel.id} path=${AppLogger.sanitizePath(targetLevel.imagePathOrUrl)}',
        e,
        st,
      );
      if (mounted && token == _resolveToken) {
        setState(() {
          _failed = true;
          _lastFailureTime = DateTime.now();
        });
      }
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
          targetDimension: widget.targetDimension ?? kDefaultThumbnailDimension,
          placeholder: widget.placeholder,
          errorWidget: widget.errorWidget,
        );
      }
      // 网络：等待下载时显示占位，下载完成后切本地
      return widget.placeholder ??
          PuzzleCardPlaceholder(
            orderNumber: widget.level.order > 0 ? widget.level.order : null,
          );
    }

    if (_failed) {
      final errorChild =
          widget.errorWidget ??
          Container(
            color: Colors.grey.shade200,
            alignment: Alignment.center,
            child: Icon(
              PhosphorIconsRegular.arrowClockwise,
              color: Colors.grey.shade400,
              size: 24,
            ),
          );
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _retry,
        child: errorChild,
      );
    }

    return AppCachedImage(
      imagePathOrUrl: _resolvedPath,
      fit: widget.fit,
      targetDimension: widget.targetDimension ?? kDefaultThumbnailDimension,
      placeholder: widget.placeholder,
      errorWidget: widget.errorWidget,
    );
  }
}
