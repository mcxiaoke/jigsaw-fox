import 'dart:async';

import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// 拼图卡片专属加载占位组件
///
/// 具备：
/// - 适配当前主题（深/浅色）的底色与微光高光
/// - 优雅的拼图块特征剪影与纯数字序号微字
/// - 高性能无离屏渲染的微光流光动效 (Shimmer)
class PuzzleCardPlaceholder extends StatefulWidget {
  const PuzzleCardPlaceholder({
    super.key,
    this.iconSize = 34.0,
    this.showShimmer = true,
    this.borderRadius,
    this.orderNumber,
  });

  final double iconSize;
  final bool showShimmer;
  final BorderRadius? borderRadius;
  final int? orderNumber;

  @override
  State<PuzzleCardPlaceholder> createState() => _PuzzleCardPlaceholderState();
}

class _PuzzleCardPlaceholderState extends State<PuzzleCardPlaceholder>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.showShimmer) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      );
      unawaited(_controller!.repeat());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 适配 M3 容器色
    final baseColor = palette.surfaceContainer;
    final highlightColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.55);
    final iconColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.10);

    Widget content = Container(
      color: baseColor,
      alignment: Alignment.center,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 拼图块几何剪影
          Icon(
            PhosphorIconsFill.puzzlePiece,
            size: widget.iconSize,
            color: iconColor,
          ),
          // 关卡纯数字序号（若有）
          if (widget.orderNumber != null && widget.orderNumber! > 0)
            Positioned(
              bottom: 8,
              child: Text(
                '${widget.orderNumber}',
                style: TextStyle(
                  color: iconColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
        ],
      ),
    );

    if (widget.showShimmer && _controller != null) {
      content = AnimatedBuilder(
        animation: _controller!,
        builder: (context, child) {
          final progress = _controller!.value;
          return Stack(
            fit: StackFit.expand,
            children: [
              child!,
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(-1.5 + 3.0 * progress, -0.6),
                      end: Alignment(-0.5 + 3.0 * progress, 0.6),
                      colors: [
                        Colors.transparent,
                        highlightColor,
                        Colors.transparent,
                      ],
                      stops: const [0.2, 0.5, 0.8],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        child: content,
      );
    }

    if (widget.borderRadius != null) {
      content = ClipRRect(
        borderRadius: widget.borderRadius!,
        child: content,
      );
    }

    return content;
  }
}
