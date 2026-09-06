///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import
// dart format off

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:slang/generated.dart';
import 'strings.g.dart';

// Path: <root>
class TranslationsZh extends Translations with BaseTranslations<AppLocale, Translations> {
	/// You can call this constructor and build your own translation instance of this locale.
	/// Constructing via the enum [AppLocale.build] is preferred.
	TranslationsZh({Map<String, Node>? overrides, PluralResolver? cardinalResolver, PluralResolver? ordinalResolver, TranslationMetadata<AppLocale, Translations>? meta})
		: assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
		  _meta = meta ?? TranslationMetadata(
		    locale: AppLocale.zh,
		    overrides: overrides ?? {},
		    cardinalResolver: cardinalResolver,
		    ordinalResolver: ordinalResolver,
		  ),
		  super(cardinalResolver: cardinalResolver, ordinalResolver: ordinalResolver) {
		_meta.setFlatMapFunction(_flatMapFunction);
	}

	/// Metadata for the translations of <zh>.
	final TranslationMetadata<AppLocale, Translations> _meta;
	@override TranslationMetadata<AppLocale, Translations> get $meta => _meta;

	/// Access flat map
	@override dynamic operator[](String key) => _meta.getTranslation(key) ?? super[key];

	late final TranslationsZh _root = this; // ignore: unused_field

	@override 
	TranslationsZh $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => TranslationsZh(meta: meta ?? this.$meta);

	// Translations
	@override late final _Translations$app$zh app = _Translations$app$zh._(_root);
	@override late final _Translations$common$zh common = _Translations$common$zh._(_root);
	@override late final _Translations$nav$zh nav = _Translations$nav$zh._(_root);
	@override late final _Translations$settings$zh settings = _Translations$settings$zh._(_root);
}

// Path: app
class _Translations$app$zh extends Translations$app$en {
	_Translations$app$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '异形拼图';
	@override String get titleFull => '异形拼图 Jigsaw Puzzle';
}

// Path: common
class _Translations$common$zh extends Translations$common$en {
	_Translations$common$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get ok => '确定';
	@override String get cancel => '取消';
	@override String get confirm => '确认';
	@override String get save => '保存';
	@override String get retry => '重试';
	@override String get clear => '清理';
	@override String get loading => '加载中…';
	@override String get calculating => '计算中…';
	@override String version({required Object version}) => '版本 ${version}';
}

// Path: nav
class _Translations$nav$zh extends Translations$nav$en {
	_Translations$nav$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get home => '主页';
	@override String get daily => '每日';
	@override String get collections => '图集';
	@override String get my => '我的';
	@override String get titleHome => '异形拼图';
	@override String get titleDaily => '每日挑战';
	@override String get titleCollections => '图集画册';
	@override String get titleMy => '我的拼图';
	@override String get tooltipAchievements => '成就与统计';
	@override String get tooltipSettings => '设置';
}

// Path: settings
class _Translations$settings$zh extends Translations$settings$en {
	_Translations$settings$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '游戏设置';
	@override String get playerTitle => '拼图玩家';
	@override String playerPlayed({required Object time}) => '已游玩 ${time}';
	@override String get sectionsAudio => '音效与交互';
	@override String get sectionsAppearance => '外观与背景';
	@override String get sectionsHelp => '玩法与帮助';
	@override String get sectionsData => '数据管理';
	@override String get sectionsLanguage => '语言';
	@override String get snapSoundTitle => '拼图吸附音效';
	@override String get snapSoundDesc => '碎片对齐磁吸时播放清脆音效';
	@override String get hapticTitle => '触感震动反馈';
	@override String get hapticDesc => '拼图吸附与操作时的触觉微震';
	@override String get gridPreviewTitle => '选关切图网格预览';
	@override String get gridPreviewDesc => '在难度选择预览图上叠加异形切线';
	@override String get scatterModeTitle => '碎片初始排布模式';
	@override String get scatterModeDescTray => '底部托盘收纳（默认/推荐手机）';
	@override String get scatterModeDescTabletop => '桌面环形散落（推荐宽屏/平板）';
	@override String get scatterTray => '托盘';
	@override String get scatterTabletop => '桌面';
	@override String get appearanceBgTitle => '默认壁纸背景';
	@override String get appearanceBgDesc => '选择拼图对局时的全屏桌面背景';
	@override String get helpTitle => '玩法技巧与操作指引';
	@override String get helpDesc => '手势操作、组队拖拽、底图透视、整理工具说明';
	@override String get dataCacheTitle => '缩略图缓存';
	@override String dataCacheDesc({required Object size}) => '卡片预览图的本地缓存，当前占用 ${size}';
	@override String get dataClear => '清理';
	@override String get dataViewLogsTitle => '查看运行日志';
	@override String get dataViewLogsDesc => '查看、过滤并复制 App 运行日志（诊断用）';
	@override String get dataResetTitle => '重置所有游戏数据';
	@override String get dataResetDesc => '清除所有关卡记录、每日挑战与自制拼图';
	@override String get dataResetConfirmTitle => '确认重置全部数据？';
	@override String get dataResetConfirmDesc => '该操作不可逆，将清除所有主线关卡进度、每日挑战与自制拼图记录。';
	@override String get dataCancel => '取消';
	@override String get dataConfirmReset => '确定重置';
	@override String footerVersion({required Object version}) => '版本 ${version}';
	@override String get toastCacheCleared => '缩略图缓存已清空，下次浏览时会自动重新生成';
	@override String toastCacheClearFailed({required Object error}) => '清理缓存失败: ${error}';
	@override String get toastDataReset => '所有游戏数据已重置为初始状态';
	@override String get languageTitle => '语言';
	@override String get languageDesc => '应用显示语言 / App Language';
	@override String get languageSystem => '跟随系统';
	@override String get languageZh => '简体中文';
	@override String get languageEn => 'English';
	@override String timeSeconds({required Object count}) => '${count} 秒';
	@override String timeMinutes({required Object count}) => '${count} 分';
	@override String timeHoursMinutes({required Object hours, required Object minutes}) => '${hours} 小时 ${minutes} 分';
}

/// The flat map containing all translations for locale <zh>.
/// Only for edge cases! For simple maps, use the map function of this library.
///
/// The Dart AOT compiler has issues with very large switch statements,
/// so the map is split into smaller functions (512 entries each).
extension on TranslationsZh {
	dynamic _flatMapFunction(String path) {
		return switch (path) {
			'app.title' => '异形拼图',
			'app.titleFull' => '异形拼图 Jigsaw Puzzle',
			'common.ok' => '确定',
			'common.cancel' => '取消',
			'common.confirm' => '确认',
			'common.save' => '保存',
			'common.retry' => '重试',
			'common.clear' => '清理',
			'common.loading' => '加载中…',
			'common.calculating' => '计算中…',
			'common.version' => ({required Object version}) => '版本 ${version}',
			'nav.home' => '主页',
			'nav.daily' => '每日',
			'nav.collections' => '图集',
			'nav.my' => '我的',
			'nav.titleHome' => '异形拼图',
			'nav.titleDaily' => '每日挑战',
			'nav.titleCollections' => '图集画册',
			'nav.titleMy' => '我的拼图',
			'nav.tooltipAchievements' => '成就与统计',
			'nav.tooltipSettings' => '设置',
			'settings.title' => '游戏设置',
			'settings.playerTitle' => '拼图玩家',
			'settings.playerPlayed' => ({required Object time}) => '已游玩 ${time}',
			'settings.sectionsAudio' => '音效与交互',
			'settings.sectionsAppearance' => '外观与背景',
			'settings.sectionsHelp' => '玩法与帮助',
			'settings.sectionsData' => '数据管理',
			'settings.sectionsLanguage' => '语言',
			'settings.snapSoundTitle' => '拼图吸附音效',
			'settings.snapSoundDesc' => '碎片对齐磁吸时播放清脆音效',
			'settings.hapticTitle' => '触感震动反馈',
			'settings.hapticDesc' => '拼图吸附与操作时的触觉微震',
			'settings.gridPreviewTitle' => '选关切图网格预览',
			'settings.gridPreviewDesc' => '在难度选择预览图上叠加异形切线',
			'settings.scatterModeTitle' => '碎片初始排布模式',
			'settings.scatterModeDescTray' => '底部托盘收纳（默认/推荐手机）',
			'settings.scatterModeDescTabletop' => '桌面环形散落（推荐宽屏/平板）',
			'settings.scatterTray' => '托盘',
			'settings.scatterTabletop' => '桌面',
			'settings.appearanceBgTitle' => '默认壁纸背景',
			'settings.appearanceBgDesc' => '选择拼图对局时的全屏桌面背景',
			'settings.helpTitle' => '玩法技巧与操作指引',
			'settings.helpDesc' => '手势操作、组队拖拽、底图透视、整理工具说明',
			'settings.dataCacheTitle' => '缩略图缓存',
			'settings.dataCacheDesc' => ({required Object size}) => '卡片预览图的本地缓存，当前占用 ${size}',
			'settings.dataClear' => '清理',
			'settings.dataViewLogsTitle' => '查看运行日志',
			'settings.dataViewLogsDesc' => '查看、过滤并复制 App 运行日志（诊断用）',
			'settings.dataResetTitle' => '重置所有游戏数据',
			'settings.dataResetDesc' => '清除所有关卡记录、每日挑战与自制拼图',
			'settings.dataResetConfirmTitle' => '确认重置全部数据？',
			'settings.dataResetConfirmDesc' => '该操作不可逆，将清除所有主线关卡进度、每日挑战与自制拼图记录。',
			'settings.dataCancel' => '取消',
			'settings.dataConfirmReset' => '确定重置',
			'settings.footerVersion' => ({required Object version}) => '版本 ${version}',
			'settings.toastCacheCleared' => '缩略图缓存已清空，下次浏览时会自动重新生成',
			'settings.toastCacheClearFailed' => ({required Object error}) => '清理缓存失败: ${error}',
			'settings.toastDataReset' => '所有游戏数据已重置为初始状态',
			'settings.languageTitle' => '语言',
			'settings.languageDesc' => '应用显示语言 / App Language',
			'settings.languageSystem' => '跟随系统',
			'settings.languageZh' => '简体中文',
			'settings.languageEn' => 'English',
			'settings.timeSeconds' => ({required Object count}) => '${count} 秒',
			'settings.timeMinutes' => ({required Object count}) => '${count} 分',
			'settings.timeHoursMinutes' => ({required Object hours, required Object minutes}) => '${hours} 小时 ${minutes} 分',
			_ => null,
		};
	}
}
