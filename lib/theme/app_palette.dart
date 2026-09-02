import 'package:flutter/material.dart';

/// 品牌语义色板 —— 从 Material 3 ColorScheme 动态读取，
/// 支持 ThemeMode.light/dark/system 全局切换时自动反色。
///
/// 所有页面/组件必须引用本类常量，禁止硬编码色值。
/// 使用：AppPalette.of(context) 从当前 Theme 的 ColorScheme 构建。
class AppPalette {
  const AppPalette._({
    required this.surface,
    required this.surfaceContainer,
    required this.surfaceContainerLow,
    required this.primaryText,
    required this.secondaryText,
    required this.disabledText,
    required this.divider,
    required this.brand,
    required this.brandLight,
    required this.gold,
    required this.success,
    required this.warning,
    required this.error,
    required this.info,
  });

  // ── Surface ──
  final Color surface;            // 页面底色
  final Color surfaceContainer;   // 卡片/面板底色
  final Color surfaceContainerLow;// 低层级容器底色

  // ── Text ──
  final Color primaryText;        // 主文字（标题/正文）
  final Color secondaryText;      // 次要文字（描述/辅助）
  final Color disabledText;       // 禁用/锁定文字

  // ── Accent ──
  final Color brand;              // 品牌色：琥珀金 #D4963C
  final Color brandLight;         // 品牌亮部：#E0A84A
  final Color gold;               // 金币/奖励色：#F0B840

  // ── Semantic ──
  final Color success;            // 暗松绿 #3D8B5F
  final Color warning;            // 暖橙 #E8A339
  final Color error;              // 砖红 #D64B4B
  final Color info;               // 灰蓝 #5B8DB8

  // ── Divider / Border ──
  final Color divider;

  /// 从当前 Theme 的 ColorScheme 构建 — M3 自适应亮暗
  static AppPalette of(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AppPalette._(
      surface:              s.surface,
      surfaceContainer:     s.surfaceContainer,
      surfaceContainerLow:  isDark ? s.surfaceContainerLow : s.surfaceContainerHighest,
      primaryText:          s.onSurface,
      secondaryText:        s.onSurfaceVariant,
      disabledText:         s.outline,
      divider:              s.outlineVariant,
      brand:                const Color(0xFFD4963C),
      brandLight:           const Color(0xFFE0A84A),
      gold:                 const Color(0xFFF0B840),
      success:              const Color(0xFF3D8B5F),
      warning:              const Color(0xFFE8A339),
      error:                const Color(0xFFD64B4B),
      info:                 const Color(0xFF5B8DB8),
    );
  }

  // ── 快捷渐变 ──
  static LinearGradient get brandGradient => const LinearGradient(
        colors: [Color(0xFFD4963C), Color(0xFFE0A84A)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
}
