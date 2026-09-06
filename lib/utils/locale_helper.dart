import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:jigsawpuzzle/data/constants/puzzle_tags.dart';

/// 语言环境检测与双语本地化支持工具
class LocaleHelper {
  LocaleHelper._();

  /// 用于测试或手动覆盖的语言代码
  static String? overrideLanguageCode;

  /// 判定是否为中文语言环境 (zh 开头，如 zh, zh-CN, zh-TW 等)
  /// 若未传入 [languageCode]，则优先检查 [overrideLanguageCode]，最后获取系统当前语言
  static bool isChinese([String? languageCode]) {
    final code = (languageCode ?? overrideLanguageCode ?? currentLanguageCode)
        .toLowerCase()
        .trim();
    return code.startsWith('zh');
  }

  /// 获取当前系统语言代码 (如 "zh", "en")
  static String get currentLanguageCode {
    if (overrideLanguageCode != null) return overrideLanguageCode!;
    try {
      return WidgetsBinding.instance.platformDispatcher.locale.languageCode
          .toLowerCase();
    } catch (_) {
      try {
        return ui.PlatformDispatcher.instance.locale.languageCode.toLowerCase();
      } catch (_) {
        return 'en';
      }
    }
  }

  /// 获取 Tag 标签的本地化显示文案
  /// - 中文语言：优先从 [kTagIdToZh] 查询中文，未查到则返回原值（或已是中文）
  /// - 其它语言：优先从 [kTagZhToId] 查询英文 ID，未查到则返回原值（或已是英文）
  /// - 特殊情况：'all' 在中文下返回 '全部'，其它语言下返回 'All'
  static String getLocalizedTagName(String tag, [String? languageCode]) {
    final isZh = isChinese(languageCode);
    if (tag.toLowerCase() == 'all') {
      return isZh ? '全部' : 'All';
    }
    if (isZh) {
      return kTagIdToZh[tag] ?? tag;
    } else {
      return kTagZhToId[tag] ?? tag;
    }
  }

  /// 获取前台 UI 专用的本地化 18 项黄金矩阵列表
  /// 保持稳定的英文 'id' (如 'all', 'Landscapes')，'label' 依据当前语言动态生成 ('全部'/'All', '风光'/'Landscapes')
  static List<Map<String, String>> getLocalizedHomeTags([
    String? languageCode,
  ]) {
    final isZh = isChinese(languageCode);
    return [
      {'id': 'all', 'label': isZh ? '全部' : 'All', 'icon': '🧩'},
      for (final tag in kMainTags)
        {'id': tag.id, 'label': isZh ? tag.zh : tag.name, 'icon': tag.icon},
    ];
  }
}

/// 顶层快捷函数：获取 Tag 标签的本地化显示文案
String getLocalizedTagName(String tag, [String? languageCode]) =>
    LocaleHelper.getLocalizedTagName(tag, languageCode);

/// 顶层快捷函数：获取前台 UI 专用的本地化 18 项黄金矩阵列表
List<Map<String, String>> getLocalizedHomeTags([String? languageCode]) =>
    LocaleHelper.getLocalizedHomeTags(languageCode);
