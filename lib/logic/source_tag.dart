import 'package:flutter/material.dart';

import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';

/// 稳定来源标签 key（持久化真源；新写入一律存 key，不再落盘中文）
abstract final class SourceKeys {
  static const String main = 'main';
  static const String daily = 'daily';
  static const String custom = 'custom';
  static const String pack = 'pack';
  static const String album = 'album';
  static const String online = 'online';
  static const String preset = 'preset';
  static const String official = 'official';
  static const String event = 'event';
}

/// 来源标签最小工具：兼容历史中文值，输出当前语言展示文案 / 稳定 key / 主题色。
///
/// 按项目决策（docs/i18n-persistent-source-labels-design-20260906.md §7-B）：
/// 仅规范新写入与等值判断，不做存量迁移；历史中文值在此兼容层归一。
class SourceTag {
  const SourceTag._();

  /// 任意历史值 → 稳定 key；未知回退 [SourceKeys.main]
  static String keyOf(String? raw) {
    switch (raw) {
      case 'main' || '主线' || '官方':
        return SourceKeys.main;
      case 'daily' || '每日':
        return SourceKeys.daily;
      case 'custom' || '自制':
        return SourceKeys.custom;
      case 'pack' || '扩展包':
        return SourceKeys.pack;
      case 'album' || '相册' || '本地相册' || '相册 / 本地' || 'gallery':
        return SourceKeys.album;
      case 'online' || '网络' || '网络图库':
        return SourceKeys.online;
      case 'preset' || '官方预置':
        return SourceKeys.preset;
      case 'official' || '官方图集':
        return SourceKeys.official;
      case 'event' || '活动' || '限时活动':
        return SourceKeys.event;
      default:
        return SourceKeys.main;
    }
  }

  /// 任意历史值 → 当前语言展示文案；未知值原样回退（防止 key/本地化文本误译）
  static String localize(String? raw) {
    final tr = LocaleSettings.instance.currentTranslations.source;
    return switch (keyOf(raw)) {
      SourceKeys.main =>
        (raw == null || raw == 'main' || raw == '主线' || raw == '官方')
            ? tr.main
            : raw,
      SourceKeys.daily => tr.daily,
      SourceKeys.custom => tr.custom,
      SourceKeys.pack => tr.pack,
      SourceKeys.album => tr.album,
      SourceKeys.online => tr.online,
      SourceKeys.preset => tr.preset,
      SourceKeys.official => tr.official,
      _ => tr.event,
    };
  }

  static bool isAlbum(String? v) =>
      keyOf(v) == SourceKeys.album || keyOf(v) == SourceKeys.preset;

  static bool isOnline(String? v) => keyOf(v) == SourceKeys.online;

  /// 来源主题色（与展示文案同一词表）
  static Color colorFor(String? raw) {
    switch (keyOf(raw)) {
      case SourceKeys.main:
        return const Color(0xFF4A90E2);
      case SourceKeys.daily:
        return const Color(0xFFFF9500);
      case SourceKeys.custom:
        return const Color(0xFF9C27B0);
      case SourceKeys.pack:
        return const Color(0xFF00B894);
      case SourceKeys.event:
        return const Color(0xFFFF5252);
      default:
        return const Color(0xFFD4963C);
    }
  }
}
