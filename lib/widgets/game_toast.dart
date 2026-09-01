import 'dart:async';
import 'package:flutter/material.dart';

import '../theme/app_palette.dart';

/// 全局 HUD 气泡提示 — 替代原生 SnackBar。
///
/// 位置：状态栏下方，顶部滑入。
/// 样式：深炭褐底 + 琥珀金微边框 + 圆角 24 + 图标 + 文字。
/// 动画：滑入 → 停留 → 向上滑出；最多同时显示 1 条，新提示顶掉旧提示。
///
/// 使用：
///   GameToast.show(context, icon: Icons.check, message: '拼图完成！');
///   GameToast.show(context, message: '出错了', type: GameToastType.error);
enum GameToastType { info, success, warning, error }

class GameToast {
  static OverlayEntry? _currentEntry;
  static Timer? _timer;

  static void show(
    BuildContext context, {
    required String message,
    IconData? icon,
    GameToastType type = GameToastType.info,
    Duration duration = const Duration(milliseconds: 2500),
    VoidCallback? onDismiss,
  }) {
    // 顶掉旧的
    _timer?.cancel();
    _currentEntry?.remove();
    _currentEntry = null;

    final palette = AppPalette.of(context);
    final Color iconColor;
    final IconData effectiveIcon;
    switch (type) {
      case GameToastType.success:
        iconColor = palette.success;
        effectiveIcon = icon ?? Icons.check_circle_rounded;
      case GameToastType.warning:
        iconColor = palette.warning;
        effectiveIcon = icon ?? Icons.warning_amber_rounded;
      case GameToastType.error:
        iconColor = palette.error;
        effectiveIcon = icon ?? Icons.error_outline_rounded;
      case GameToastType.info:
        iconColor = palette.brand;
        effectiveIcon = icon ?? Icons.info_outline_rounded;
    }

    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (ctx) => _GameToastWidget(
        message: message,
        icon: effectiveIcon,
        iconColor: iconColor,
        palette: palette,
        duration: duration,
        onDismiss: () {
          _currentEntry?.remove();
          _currentEntry = null;
          onDismiss?.call();
        },
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);

    _timer = Timer(duration, () {
      _currentEntry?.remove();
      _currentEntry = null;
    });
  }

  static void hide() {
    _timer?.cancel();
    _currentEntry?.remove();
    _currentEntry = null;
  }
}

class _GameToastWidget extends StatefulWidget {
  const _GameToastWidget({
    required this.message,
    required this.icon,
    required this.iconColor,
    required this.palette,
    required this.duration,
    required this.onDismiss,
  });

  final String message;
  final IconData icon;
  final Color iconColor;
  final AppPalette palette;
  final Duration duration;
  final VoidCallback onDismiss;

  @override
  State<_GameToastWidget> createState() => _GameToastWidgetState();
}

class _GameToastWidgetState extends State<_GameToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -1.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _ctrl.forward();

    Future.delayed(widget.duration - const Duration(milliseconds: 300), () {
      if (mounted) {
        _ctrl.reverse().whenComplete(widget.onDismiss);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slideAnim,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2F3A),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: p.brand.withValues(alpha: 0.25), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, color: widget.iconColor, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.message,
                    style: TextStyle(
                      color: p.primaryText,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
