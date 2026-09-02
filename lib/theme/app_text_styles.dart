import 'package:flutter/material.dart';

import 'app_palette.dart';

/// 全局字体层级 — 支持主题切换时自动反色。
///
/// 使用：AppTextStyles.of(context).h1 / .body / .caption 等
class AppTextStyles {
  const AppTextStyles._({required this.palette});

  final AppPalette palette;

  static AppTextStyles of(BuildContext context) {
    return AppTextStyles._(palette: AppPalette.of(context));
  }

  // ── H1 页面标题 ──
  TextStyle get h1 => TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    color: palette.primaryText,
    height: 1.2,
  );

  // ── H2 模块标题 ──
  TextStyle get h2 => TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: palette.primaryText,
    height: 1.3,
  );

  // ── H3 卡片标题 ──
  TextStyle get h3 => TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: palette.primaryText,
    height: 1.4,
  );

  // ── Body 正文 ──
  TextStyle get body => TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: palette.primaryText,
    height: 1.5,
  );

  // ── Body Bold ──
  TextStyle get bodyBold => TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: palette.primaryText,
    height: 1.5,
  );

  // ── Caption 辅助 ──
  TextStyle get caption => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: palette.secondaryText,
    height: 1.4,
  );

  // ── Caption Bold ──
  TextStyle get captionBold => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: palette.secondaryText,
    height: 1.4,
  );

  // ── Mono 等宽数字（统计/计时/金币） ──
  TextStyle get mono => TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    color: palette.primaryText,
    fontFeatures: const [FontFeature.tabularFigures()],
    height: 1.1,
  );

  TextStyle get monoSmall => TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    color: palette.primaryText,
    fontFeatures: const [FontFeature.tabularFigures()],
    height: 1.1,
  );

  // ── 品牌色强调 ──
  TextStyle get brand => TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: palette.brand,
    height: 1.4,
  );

  // ── 禁用态 ──
  TextStyle get disabled => TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: palette.disabledText,
    height: 1.4,
  );
}
