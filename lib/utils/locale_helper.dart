import 'package:jigsawpuzzle/data/constants/puzzle_tags.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';

/// 语言环境检测与双语本地化支持工具
///
/// 已收敛至 [LocaleService] 为唯一真源，本类保留为兼容门面。
class LocaleHelper {
  LocaleHelper._();

  /// 用于测试或手动覆盖的语言代码（已废弃，请用 LocaleService.instance.setOverrideForTest）
  @Deprecated('Use LocaleService.instance.setOverrideForTest instead')
  static String? get overrideLanguageCode =>
      // ignore: deprecated_member_use_from_same_package
      _legacyOverride;
  @Deprecated('Use LocaleService.instance.setOverrideForTest instead')
  static set overrideLanguageCode(String? v) {
    _legacyOverride = v;
    LocaleService.instance.setOverrideForTest(v);
  }

  static String? _legacyOverride;

  /// 判定是否为中文语言环境 (zh 开头，如 zh, zh-CN, zh-TW 等)
  /// 若未传入 [languageCode]，则委托 LocaleService 的 effective 判定
  static bool isChinese([String? languageCode]) {
    if (languageCode != null) {
      return languageCode.toLowerCase().trim().startsWith('zh');
    }
    return LocaleService.instance.isChinese;
  }

  /// 获取当前生效语言代码 (如 "zh", "en")，委托 LocaleService
  static String get currentLanguageCode =>
      LocaleService.instance.effectiveLanguageCode;

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
