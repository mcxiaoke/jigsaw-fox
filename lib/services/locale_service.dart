import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 语言偏好枚举，持久化到 SharedPreferences
enum AppLanguage { system, zh, en }

/// 全局语言服务：唯一真源，单例 ChangeNotifier
///
/// 职责：
/// - 持久化用户选择（`jigsaw_setting_language` = system|zh|en）
/// - 计算 effectiveLocale（用户覆盖 ?? 系统语言，zh-* 归一为 zh）
/// - 同步 slang 的 LocaleSettings 并通知 UI 重建
class LocaleService extends ChangeNotifier {
  LocaleService._();
  static final LocaleService instance = LocaleService._();

  static const String _prefsKey = 'jigsaw_setting_language';

  AppLanguage _language = AppLanguage.system;
  bool _initialized = false;

  /// 测试注入：非空时强制覆盖 effective 判定（优先级高于一切）
  String? _overrideLanguageCode;

  AppLanguage get language => _language;
  bool get isInitialized => _initialized;

  /// 是否为中文环境（基于 effective）
  bool get isChinese => effectiveLanguageCode.startsWith('zh');

  /// 当前生效的 slang AppLocale
  AppLocale get effectiveLocale {
    if (_overrideLanguageCode != null) {
      final code = _overrideLanguageCode!.toLowerCase().trim();
      return code.startsWith('zh') ? AppLocale.zh : AppLocale.en;
    }
    switch (_language) {
      case AppLanguage.zh:
        return AppLocale.zh;
      case AppLanguage.en:
        return AppLocale.en;
      case AppLanguage.system:
        final code = _deviceLanguageCode().toLowerCase().trim();
        return code.startsWith('zh') ? AppLocale.zh : AppLocale.en;
    }
  }

  /// 当前生效的语言代码 'zh' | 'en'
  String get effectiveLanguageCode => effectiveLocale.languageCode;

  /// Flutter Locale 供 MaterialApp.locale 使用
  Locale get flutterLocale => effectiveLocale.flutterLocale;

  /// 读取系统语言，兼容 WidgetsBinding 未初始化时的回退
  String _deviceLanguageCode() {
    try {
      return WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    } catch (_) {
      try {
        return ui.PlatformDispatcher.instance.locale.languageCode;
      } catch (_) {
        return 'en';
      }
    }
  }

  /// 初始化：从 SharedPreferences 读取并同步 slang
  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey)?.toLowerCase().trim();
      _language = _parseLanguage(raw);
      // 同步 slang 全局
      LocaleSettings.setLocaleSync(effectiveLocale);
      AppLogger.system.info(
        'LocaleService init language=$_language effective=${effectiveLocale.name} raw=$raw',
      );
    } catch (e, st) {
      AppLogger.system.warning('LocaleService init failed', e, st);
      _language = AppLanguage.system;
      try {
        LocaleSettings.setLocaleSync(effectiveLocale);
      } catch (_) {}
    } finally {
      _initialized = true;
    }
  }

  /// 测试专用：重置为未初始化（模拟冷启动）
  @visibleForTesting
  void resetForTest() {
    _initialized = false;
    _language = AppLanguage.system;
    _overrideLanguageCode = null;
    try {
      LocaleSettings.setLocaleSync(effectiveLocale);
    } catch (_) {}
    notifyListeners();
  }

  /// 测试注入：覆盖语言代码（'zh'/'en'/'zh-CN'），null 清除（生产可用，供 LocaleHelper 兼容）
  void setOverrideForTest(String? code) {
    _overrideLanguageCode = code;
    try {
      LocaleSettings.setLocaleSync(effectiveLocale);
    } catch (_) {}
    notifyListeners();
  }

  /// 设置用户语言偏好并持久化
  Future<void> setLanguage(AppLanguage lang) async {
    if (_language == lang && _initialized) return;
    _language = lang;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, lang.name);
    } catch (e, st) {
      AppLogger.system.warning(
        'LocaleService setLanguage persist failed',
        e,
        st,
      );
    }
    try {
      LocaleSettings.setLocaleSync(effectiveLocale);
    } catch (e, st) {
      AppLogger.system.warning('LocaleService setLocaleSync failed', e, st);
    }
    AppLogger.system.info(
      'LocaleService setLanguage $lang effective=${effectiveLocale.name}',
    );
    notifyListeners();
  }

  /// 系统语言变化时由 WidgetsBindingObserver 触发（仅 system 模式需重建）
  void onSystemLocaleChanged() {
    if (_language != AppLanguage.system) return;
    if (_overrideLanguageCode != null) return;
    try {
      LocaleSettings.setLocaleSync(effectiveLocale);
    } catch (_) {}
    notifyListeners();
    AppLogger.system.info(
      'LocaleService system locale changed -> ${effectiveLocale.name}',
    );
  }

  static AppLanguage _parseLanguage(String? raw) {
    switch (raw) {
      case 'zh':
      case 'zh-cn':
      case 'zh_cn':
      case 'cn':
        return AppLanguage.zh;
      case 'en':
      case 'en-us':
      case 'en_us':
        return AppLanguage.en;
      case 'system':
      case null:
      case '':
        return AppLanguage.system;
      default:
        // 兼容旧版及其它异常值（raw 在 default 分支必非 null/空）
        if (raw.startsWith('zh')) return AppLanguage.zh;
        if (raw.startsWith('en')) return AppLanguage.en;
        return AppLanguage.system;
    }
  }

  /// 供 LocaleHelper.isChinese(languageCode) 的静态兼容
  static bool isChineseCode(String? code) {
    if (code != null) return code.toLowerCase().trim().startsWith('zh');
    return instance.isChinese;
  }
}
