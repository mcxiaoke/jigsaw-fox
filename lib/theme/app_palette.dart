import 'package:flutter/material.dart';

/// 品牌色彩体系 — 以琥珀金 #D4963C 为锚点，深炭灰 #1A1D24 为夜间默认底。
///
/// 所有页面/组件必须引用本类常量，禁止硬编码色值。
/// 使用：AppPalette.of(context) 自动返回 light/dark 实例。
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

  // ── 预设实例 ──

  /// 夜间模式（默认）
  static const dark = AppPalette._(
    surface: Color(0xFF1A1D24),
    surfaceContainer: Color(0xFF252A33),
    surfaceContainerLow: Color(0xFF1E232C),
    primaryText: Color(0xFFE8EAEE),
    secondaryText: Color(0xFF9CA3AF),
    disabledText: Color(0xFF4B5563),
    divider: Color(0xFF2E3440),
    brand: Color(0xFFD4963C),
    brandLight: Color(0xFFE0A84A),
    gold: Color(0xFFF0B840),
    success: Color(0xFF3D8B5F),
    warning: Color(0xFFE8A339),
    error: Color(0xFFD64B4B),
    info: Color(0xFF5B8DB8),
  );

  /// 日间模式
  static const light = AppPalette._(
    surface: Color(0xFFF5F1EB),
    surfaceContainer: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF0EDE7),
    primaryText: Color(0xFF1E232C),
    secondaryText: Color(0xFF6B7280),
    disabledText: Color(0xFF9CA3AF),
    divider: Color(0xFFE5E0D8),
    brand: Color(0xFFD4963C),
    brandLight: Color(0xFFE0A84A),
    gold: Color(0xFFF0B840),
    success: Color(0xFF3D8B5F),
    warning: Color(0xFFE8A339),
    error: Color(0xFFD64B4B),
    info: Color(0xFF5B8DB8),
  );

  /// 根据当前 Theme brightness 自动返回对应色板
  static AppPalette of(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? dark : light;
  }

  // ── 快捷渐变 ──
  static LinearGradient get brandGradient => const LinearGradient(
        colors: [Color(0xFFD4963C), Color(0xFFE0A84A)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
}
