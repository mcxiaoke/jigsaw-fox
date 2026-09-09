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
	@override late final _Translations$home$zh home = _Translations$home$zh._(_root);
	@override late final _Translations$daily$zh daily = _Translations$daily$zh._(_root);
	@override late final _Translations$events$zh events = _Translations$events$zh._(_root);
	@override late final _Translations$levels$zh levels = _Translations$levels$zh._(_root);
	@override late final _Translations$collections$zh collections = _Translations$collections$zh._(_root);
	@override late final _Translations$pack$zh pack = _Translations$pack$zh._(_root);
	@override late final _Translations$unlock$zh unlock = _Translations$unlock$zh._(_root);
	@override late final _Translations$myPuzzles$zh myPuzzles = _Translations$myPuzzles$zh._(_root);
	@override late final _Translations$drawer$zh drawer = _Translations$drawer$zh._(_root);
	@override late final _Translations$crop$zh crop = _Translations$crop$zh._(_root);
	@override late final _Translations$online$zh online = _Translations$online$zh._(_root);
	@override late final _Translations$share$zh share = _Translations$share$zh._(_root);
	@override late final _Translations$importPack$zh importPack = _Translations$importPack$zh._(_root);
	@override late final _Translations$background$zh background = _Translations$background$zh._(_root);
	@override late final _Translations$howTo$zh howTo = _Translations$howTo$zh._(_root);
	@override late final _Translations$logs$zh logs = _Translations$logs$zh._(_root);
	@override late final _Translations$source$zh source = _Translations$source$zh._(_root);
	@override late final _Translations$downloads$zh downloads = _Translations$downloads$zh._(_root);
	@override late final _Translations$achievements$zh achievements = _Translations$achievements$zh._(_root);
	@override late final _Translations$difficulty$zh difficulty = _Translations$difficulty$zh._(_root);
	@override late final _Translations$game$zh game = _Translations$game$zh._(_root);
	@override late final _Translations$victory$zh victory = _Translations$victory$zh._(_root);
	@override late final _Translations$continueDialog$zh continueDialog = _Translations$continueDialog$zh._(_root);
	@override late final _Translations$chooseDifficulty$zh chooseDifficulty = _Translations$chooseDifficulty$zh._(_root);
	@override late final _Translations$achievementsPage$zh achievementsPage = _Translations$achievementsPage$zh._(_root);
	@override late final _Translations$myCenter$zh myCenter = _Translations$myCenter$zh._(_root);
	@override late final _Translations$boot$zh boot = _Translations$boot$zh._(_root);
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
	@override String get sync => '刷新同步';
	@override String get back => '返回';
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
	@override String get scatterModeTitle => '棋盘模式';
	@override String get scatterModeDescTray => '散落碎片收纳在底部托盘';
	@override String get scatterModeDescTabletop => '散落碎片分布在棋盘周围';
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
	@override String footerVersion({required Object version}) => '版本 ${version}';
	@override String get toastCacheCleared => '缩略图缓存已清空，下次浏览时会自动重新生成';
	@override String toastCacheClearFailed({required Object error}) => '清理缓存失败: ${error}';
	@override String get languageTitle => '语言';
	@override String get languageDesc => '应用显示语言 / App Language';
	@override String get languageSystem => '跟随系统';
	@override String get languageZh => '简体中文';
	@override String get languageEn => 'English';
	@override String timeSeconds({required Object count}) => '${count} 秒';
	@override String timeMinutes({required Object count}) => '${count} 分';
	@override String timeHoursMinutes({required Object hours, required Object minutes}) => '${hours} 小时 ${minutes} 分';
}

// Path: home
class _Translations$home$zh extends Translations$home$en {
	_Translations$home$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get loadImageFailed => '关卡图片加载失败，请重试';
	@override String get puzzleTitle => '拼图';
	@override String get emptyCategory => '小狐狸没找到该分类的关卡';
	@override String get viewAll => '查看全部';
	@override String get allCategories => '全部分类';
	@override String bannerDailyTitle({required Object month, required Object day}) => '${month}月${day}日 · 今日专属';
	@override String get bannerDailySub => '每日专属拼图 · 激活大脑';
	@override String get bannerDailyBadge => '每日挑战';
}

// Path: daily
class _Translations$daily$zh extends Translations$daily$en {
	_Translations$daily$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get todayFallback => '今日挑战';
	@override String dateChallenge({required Object month, required Object day}) => '${month}月${day}日 挑战';
	@override String get notUnlocked => '⏳ 未到解锁时间，敬请期待！';
	@override String dateCaption({required Object month, required Object day}) => '${month} 月 ${day} 日';
	@override String todayTitle({required Object month, required Object day}) => '${month}月${day}日 · 今日挑战';
	@override String get btnClearedReplay => '已通关 (重玩)';
	@override String get btnResume => '继续挑战';
	@override String get btnStart => '开始挑战';
	@override String totalProgress({required Object done, required Object total}) => '每日总进度: ${done}/${total}';
	@override String streakDays({required Object count}) => '连胜 ${count} 天';
	@override String loadingMonth({required Object month}) => '正在加载 ${month} 挑战关卡...';
	@override String loadMonthFailed({required Object month}) => '加载 ${month} 关卡失败，请检查网络后重试';
	@override String emptyMonth({required Object month}) => '暂未下载 ${month} 关卡数据';
	@override String get downloadMonth => '下载本月关卡';
	@override String monthTitle({required Object year, required Object month}) => '${year}年${month}月';
	@override String monthCompleted({required Object done, required Object total}) => '已完成 ${done}/${total}';
}

// Path: events
class _Translations$events$zh extends Translations$events$en {
	_Translations$events$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get emptyTitle => '小狐狸没找到正在进行的活动';
	@override String get emptyHint => '下拉刷新或稍后再来看看吧';
	@override String get badgeActive => '限时进行中';
	@override String get badgePast => '往期活动';
	@override String get badgeZip => '离线整包';
	@override String get badgeOnline => '在线精选';
	@override String get descFallback => '精彩专题拼图挑战';
	@override String get subFallback => '限时活动挑战';
	@override String get badgeLimited => '限时活动';
	@override String get enter => '进入挑战';
}

// Path: levels
class _Translations$levels$zh extends Translations$levels$en {
	_Translations$levels$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get empty => '暂无可用关卡';
	@override String titleOf({required Object title, required Object index}) => '${title} · 第 ${index} 关';
	@override String get retryDownload => '重试下载';
	@override String get retryLoad => '重试加载';
	@override String countLabel({required Object count}) => '共 ${count} 个关卡';
	@override String countWithSize({required Object count, required Object size}) => '共 ${count} 个关卡 · ${size}';
	@override String imgLoadFailed({required Object error}) => '图片加载失败: ${error}';
	@override String get networkFail => '关卡图片下载失败，请检查网络后重试';
}

// Path: collections
class _Translations$collections$zh extends Translations$collections$en {
	_Translations$collections$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String toastReady({required Object title}) => '「${title}」下载就绪，可离线畅玩';
	@override String get toastFailed => '下载失败，请检查网络后重试';
	@override String toastError({required Object error}) => '下载异常: ${error}';
	@override String get statsTitle => '精选图集';
	@override String statsCount({required Object count}) => '${count} 套';
	@override String get emptyAll => '暂无图集内容';
	@override String get emptyHint => '下拉刷新同步官方资源';
	@override String get emptyCollections => '暂无图集';
	@override String downloading({required Object title, required Object percent}) => '「${title}」正在下载中 (${percent}%)，请稍候...';
	@override String startDownload({required Object title}) => '开始下载「${title}」...';
	@override String levelCount({required Object count}) => '${count} 关';
	@override String get badgeDownloaded => '已下载';
	@override String get badgeDownload => '下载';
	@override String get freeTooltip => '释放图集存储空间';
	@override String clearTitle({required Object title}) => '清理「${title}」';
	@override String clearDesc({required Object size}) => '确定要清理已下载的本地资源吗？\n清理后可释放 ${size} 磁盘空间。您随时可以重新下载。';
	@override String get confirmClear => '确认清理';
	@override String get toastCleared => '已释放图集本地存储空间';
	@override String get toastClearFailed => '清理失败，请重试';
	@override String get typeOfficial => '官方图集';
	@override String get typeEvent => '限时活动';
}

// Path: pack
class _Translations$pack$zh extends Translations$pack$en {
	_Translations$pack$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String deleteTitle({required Object title}) => '删除「${title}」图包';
	@override String deleteDesc({required Object count, required Object size}) => '确定要删除此扩展图包吗？\n将同时清理包内 ${count} 个关卡并释放 ${size} 存储空间。';
	@override String get confirmDelete => '确认删除';
	@override String get toastDeleteFailed => '删除失败，请重试';
	@override String get imageMissing => '关卡图片文件不存在';
	@override String get deleteTooltip => '删除此图包';
	@override String levelCount({required Object count}) => '${count} 关卡';
	@override String get emptyLevels => '此图包中暂无关卡图片';
	@override String get sourceLocal => '相册 / 本地';
	@override String get sourceNetwork => '网络';
}

// Path: unlock
class _Translations$unlock$zh extends Translations$unlock$en {
	_Translations$unlock$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String stars3({required Object req, required Object current}) => '需要获得 3 星的不同拼图达到 ${req} 张（当前 ${current}/${req}）';
	@override String get daily => '完成第 1 关主线即可解锁每日挑战';
	@override String eventPack({required Object req, required Object current}) => '完成 ${req} 关主线即可解锁活动与主题包（当前 ${current}/${req}）';
}

// Path: myPuzzles
class _Translations$myPuzzles$zh extends Translations$myPuzzles$en {
	_Translations$myPuzzles$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get actionGallery => '相册选图';
	@override String get subBatch => '批量导入';
	@override String get actionImportPack => '导入关卡包';
	@override String get subZip => 'ZIP 扩展包';
	@override String get actionOnline => '在线搜图';
	@override String get subOnline => '海量图库';
	@override String get importedPacksTitle => '已导入扩展包';
	@override String importedPacksCount({required Object count}) => '${count} 个扩展包';
	@override String get customTitle => '自制关卡';
	@override String get emptyTitle => '小狐狸抱着空篮子等你制作拼图';
	@override String get emptyHint => '点击上方「相册选图」或「素材库」开始制作吧！';
	@override String get packBadge => '扩展合辑';
	@override String get packDescFallback => '精选拼图扩展关卡合辑';
	@override String packTotalLevels({required Object count}) => '共 ${count} 关';
}

// Path: drawer
class _Translations$drawer$zh extends Translations$drawer$en {
	_Translations$drawer$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '素材库';
	@override String count({required Object count}) => '${count} 张素材';
	@override String get clearAllTitle => '清空素材库';
	@override String get clearAllDesc => '确定要清空所有待制作的素材图片吗？（不会影响已经制作成功的拼图关卡）';
	@override String get clearAll => '清空全部';
	@override String get emptyTitle => '素材库暂无图片';
	@override String get emptyHint => '点击「相册选图」批量导入本地照片，或在「在线搜图」中一键下载，即可将图片加入素材库随时制作拼图。';
	@override String get close => '关闭';
	@override String get makePuzzle => '制作拼图';
	@override String get deleteImageTooltip => '删除此图片';
	@override String get fileMissing => '素材文件不存在或已被清理';
}

// Path: crop
class _Translations$crop$zh extends Translations$crop$en {
	_Translations$crop$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '裁剪与自制拼图';
	@override String regionLabel({required Object width, required Object height}) => '裁切区域: ${width} × ${height}';
	@override String get gestureHint => '按住拖动调整裁切位置 · 双指或滚轮缩放';
	@override String get saving => '正在保存...';
	@override String get saveButton => '保存自制关卡';
	@override String get optimizing => '正在优化画质并生成自制关卡...';
	@override String saveFailedToast({required Object error}) => '保存失败: ${error}';
}

// Path: online
class _Translations$online$zh extends Translations$online$en {
	_Translations$online$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String savedBanner({required Object width, required Object height}) => '已存入素材库 (${width}×${height})';
	@override String get savedSourceSub => '来源: 网络 · 点击查看';
	@override String get alreadyInBox => '该图片已在下载箱中';
	@override String downloadFailed({required Object error}) => '下载图片失败: ${error}';
	@override String get noHighResDetected => '未在当前页面检测到高清大图，请点击进入照片详情页后再试';
	@override String get closePickerTooltip => '关闭在线选图';
	@override String get backTooltip => '后退';
	@override String get refreshTooltip => '刷新';
	@override String get extracting => '正在提取...';
	@override String get extractCurrent => '提取本页大图';
	@override String get dismissTooltip => '关闭提示';
}

// Path: share
class _Translations$share$zh extends Translations$share$en {
	_Translations$share$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '分享成绩';
	@override String get exportTooltip => '导出分享';
	@override String get toastSaved => '分享卡片已保存到临时目录';
	@override String toastExportFailed({required Object error}) => '导出失败: ${error}';
	@override String get completed => '拼图完成!';
	@override String get timeLabel => '用时';
	@override String get piecesLabel => '碎片';
	@override String get stepsLabel => '步数';
	@override String get exporting => '导出中...';
	@override String get saveButton => '保存分享卡片';
}

// Path: importPack
class _Translations$importPack$zh extends Translations$importPack$en {
	_Translations$importPack$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String pickFailed({required Object error}) => '选择文件失败: ${error}';
	@override String get hintPickFile => '请选择本地 ZIP 文件或输入网络下载地址';
	@override String get extractingLocal => '正在解压并解析本地图包...';
	@override String get downloadingNet => '正在下载并解压网络图包...';
	@override String imported({required Object title, required Object count}) => '成功导入《${title}》(共 ${count} 关)';
	@override String importFailedToast({required Object error}) => '导入失败: ${error}';
	@override String get appbarTitle => '导入扩展图包 (.zip)';
	@override String get infoBanner => '支持导入任意包含 JPG/PNG/WebP 图片的 ZIP 压缩包；导入后将自动生成独立合辑，可随时整包删除。';
	@override String get methodLocal => '方式一：从本地文件选择';
	@override String get browseHint => '点击右侧按钮选择 .zip 文件';
	@override String get browse => '浏览...';
	@override String get methodNetwork => '方式二：输入网络下载地址';
	@override String get testChip1 => '测试包: 赛博霓虹';
	@override String get testChip2 => '测试包: 纯图片猫咪';
	@override String get startImport => '开始导入并解析';
}

// Path: background
class _Translations$background$zh extends Translations$background$en {
	_Translations$background$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '更换拼图背景';
	@override String tableLabel({required Object index}) => '桌板 ${index}';
}

// Path: howTo
class _Translations$howTo$zh extends Translations$howTo$en {
	_Translations$howTo$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '玩法与操作技巧';
	@override String get welcomeTitle => '轻松上手异形拼图';
	@override String get welcomeSub => '熟悉以下核心操作手势与辅助工具，能让你在挑战高难度拼图时事半功倍！';
	@override late final _Translations$howTo$t1$zh t1 = _Translations$howTo$t1$zh._(_root);
	@override late final _Translations$howTo$t2$zh t2 = _Translations$howTo$t2$zh._(_root);
	@override late final _Translations$howTo$t3$zh t3 = _Translations$howTo$t3$zh._(_root);
	@override late final _Translations$howTo$t4$zh t4 = _Translations$howTo$t4$zh._(_root);
	@override late final _Translations$howTo$t5$zh t5 = _Translations$howTo$t5$zh._(_root);
	@override late final _Translations$howTo$t6$zh t6 = _Translations$howTo$t6$zh._(_root);
}

// Path: logs
class _Translations$logs$zh extends Translations$logs$en {
	_Translations$logs$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '运行日志';
	@override String get filterPrefix => '过滤：';
	@override String get filterAll => '全部';
	@override String get scrollTopTooltip => '回到顶部（最新日志）';
	@override String get copyTooltip => '复制日志';
	@override String copyFiltered({required Object count}) => '复制当前视图（${count}）';
	@override String copyAll({required Object count}) => '复制全部日志（${count}）';
	@override String get nothingToCopy => '暂无可复制的日志';
	@override String copiedFiltered({required Object count}) => '已复制当前视图 ${count} 条日志';
	@override String copiedAll({required Object count}) => '已复制全部 ${count} 条日志';
	@override String get clearTooltip => '清除日志';
	@override String get clearConfirmTitle => '清除全部日志？';
	@override String get clearConfirmDesc => '将删除磁盘上的日志文件，并清空内存中的日志记录，此操作不可恢复。\n清除后日志会从头重新记录，下次复制时内容将大幅减少。';
	@override String get clearConfirmBtn => '清除日志';
	@override String get clearedToast => '日志已清除，正在从空白重新记录';
	@override String get emptyFiltered => '当前过滤条件下暂无日志';
	@override String get loading => '日志加载中…';
	@override String get close => '关闭';
}

// Path: source
class _Translations$source$zh extends Translations$source$en {
	_Translations$source$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get main => '主线';
	@override String get daily => '每日';
	@override String get custom => '自制';
	@override String get pack => '扩展包';
	@override String get album => '相册';
	@override String get online => '网络';
	@override String get preset => '官方';
	@override String get official => '官方图集';
	@override String get event => '限时活动';
}

// Path: downloads
class _Translations$downloads$zh extends Translations$downloads$en {
	_Translations$downloads$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get q4k => '4K 超清';
	@override String get q2k => '2K 2.5K';
	@override String get q1080 => 'FHD 全高清';
	@override String get q720 => 'HD 高清';
	@override String get qsd => '标清';
}

// Path: achievements
class _Translations$achievements$zh extends Translations$achievements$en {
	_Translations$achievements$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override late final _Translations$achievements$first_win$zh first_win = _Translations$achievements$first_win$zh._(_root);
	@override late final _Translations$achievements$win_10$zh win_10 = _Translations$achievements$win_10$zh._(_root);
	@override late final _Translations$achievements$win_50$zh win_50 = _Translations$achievements$win_50$zh._(_root);
	@override late final _Translations$achievements$win_100$zh win_100 = _Translations$achievements$win_100$zh._(_root);
	@override late final _Translations$achievements$star_1$zh star_1 = _Translations$achievements$star_1$zh._(_root);
	@override late final _Translations$achievements$star_10$zh star_10 = _Translations$achievements$star_10$zh._(_root);
	@override late final _Translations$achievements$star_30$zh star_30 = _Translations$achievements$star_30$zh._(_root);
	@override late final _Translations$achievements$star_50$zh star_50 = _Translations$achievements$star_50$zh._(_root);
	@override late final _Translations$achievements$tier_l3$zh tier_l3 = _Translations$achievements$tier_l3$zh._(_root);
	@override late final _Translations$achievements$tier_l4$zh tier_l4 = _Translations$achievements$tier_l4$zh._(_root);
	@override late final _Translations$achievements$tier_l5$zh tier_l5 = _Translations$achievements$tier_l5$zh._(_root);
	@override late final _Translations$achievements$tier_l6$zh tier_l6 = _Translations$achievements$tier_l6$zh._(_root);
	@override late final _Translations$achievements$custom_1$zh custom_1 = _Translations$achievements$custom_1$zh._(_root);
	@override late final _Translations$achievements$custom_5$zh custom_5 = _Translations$achievements$custom_5$zh._(_root);
	@override late final _Translations$achievements$no_hint_win$zh no_hint_win = _Translations$achievements$no_hint_win$zh._(_root);
	@override late final _Translations$achievements$speed_10min$zh speed_10min = _Translations$achievements$speed_10min$zh._(_root);
	@override late final _Translations$achievements$night_owl$zh night_owl = _Translations$achievements$night_owl$zh._(_root);
	@override late final _Translations$achievements$snap_100$zh snap_100 = _Translations$achievements$snap_100$zh._(_root);
	@override late final _Translations$achievements$snap_500$zh snap_500 = _Translations$achievements$snap_500$zh._(_root);
	@override late final _Translations$achievements$snap_2000$zh snap_2000 = _Translations$achievements$snap_2000$zh._(_root);
	@override late final _Translations$achievements$time_30m$zh time_30m = _Translations$achievements$time_30m$zh._(_root);
	@override late final _Translations$achievements$time_2h$zh time_2h = _Translations$achievements$time_2h$zh._(_root);
	@override late final _Translations$achievements$time_10h$zh time_10h = _Translations$achievements$time_10h$zh._(_root);
	@override late final _Translations$achievements$daily_7$zh daily_7 = _Translations$achievements$daily_7$zh._(_root);
	@override late final _Translations$achievements$master_all$zh master_all = _Translations$achievements$master_all$zh._(_root);
}

// Path: difficulty
class _Translations$difficulty$zh extends Translations$difficulty$en {
	_Translations$difficulty$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override late final _Translations$difficulty$tier$zh tier = _Translations$difficulty$tier$zh._(_root);
	@override late final _Translations$difficulty$estimated$zh estimated = _Translations$difficulty$estimated$zh._(_root);
	@override late final _Translations$difficulty$aspect$zh aspect = _Translations$difficulty$aspect$zh._(_root);
	@override String pieceCount({required Object cols, required Object rows, required Object count}) => '${cols} x ${rows} (${count} 块)';
	@override String get recommended => '推荐';
}

// Path: game
class _Translations$game$zh extends Translations$game$en {
	_Translations$game$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String titleLevel({required Object index}) => '第 ${index} 关';
	@override String titleDaily({required Object date}) => '${date} 每日挑战';
	@override String get titleCustom => '自制拼图';
	@override String titlePack({required Object title}) => '${title}';
	@override String get tooltipBack => '返回';
	@override String get tooltipEdges => '仅显示边缘碎片';
	@override String get tooltipEdgesAll => '显示全部碎片';
	@override String get tooltipHint => '智能提示';
	@override String tooltipGhost({required Object opacity}) => '底图透视 ${opacity}%';
	@override String get tooltipGhostOff => '底图透视关闭';
	@override String get tooltipPreview => '查看原图';
	@override String get tooltipOrganize => '一键整理托盘';
	@override String get tooltipChangeBg => '更换壁纸背景';
	@override String hintNotEnoughCoins({required Object price, required Object coins}) => '金币不足（当前难度提示需 ${price} 金币，当前拥有 ${coins}）';
	@override String get imageDecodeFailed => '图片解码失败，请重试';
	@override String get tapToReturn => '点击任意处返回拼图';
	@override String get zoomReset => '重置';
	@override String progress({required Object percent}) => '${percent}%';
}

// Path: victory
class _Translations$victory$zh extends Translations$victory$en {
	_Translations$victory$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '拼图完成！';
	@override String stars({required num count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('zh'))(count,
		other: '${count} 星',
	);
	@override String time({required Object time}) => '用时：${time}';
	@override String pieces({required Object count}) => '${count} 块';
	@override String coinsReward({required Object coins}) => '+${coins} 金币';
	@override String newAchievements({required Object count}) => '${count} 项新成就';
	@override String get btnNext => '下一关';
	@override String get btnShare => '分享成绩';
	@override String get btnView => '欣赏拼图';
	@override String get btnExit => '退出';
	@override String get btnSaveWallpaper => '保存壁纸';
	@override String get perfect => '完美！';
	@override String get great => '精彩！';
	@override String get btnClose => '关闭弹窗 (Esc)';
	@override String get toastWallpaperSaved => '壁纸已保存到本地';
	@override String toastSaveWallpaperFailed({required Object error}) => '壁纸保存失败：${error}';
}

// Path: continueDialog
class _Translations$continueDialog$zh extends Translations$continueDialog$en {
	_Translations$continueDialog$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get progressLabel => '已拼进度';
	@override String get timeLabel => '已用时间';
	@override String spec({required Object key}) => '规格 ${key}';
	@override String specPieces({required Object key, required Object count}) => '规格 ${key}（${count} 块）';
	@override String piecesCount({required Object count}) => '碎片 ${count}';
	@override String get foxHint => '小狐狸在等你完成这幅拼图呢';
	@override String get restartTitle => '重新开始？';
	@override String get restartDesc => '将清除该难度的存档进度，不可恢复，确定重新开始吗？';
	@override String get btnRestart => '重新开始';
	@override String get restartConfirm => '确定重开';
	@override String get btnResume => '继续挑战';
}

// Path: chooseDifficulty
class _Translations$chooseDifficulty$zh extends Translations$chooseDifficulty$en {
	_Translations$chooseDifficulty$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '选择难度';
	@override String pieces({required Object count}) => '${count} 块';
	@override String get recommended => '推荐';
	@override String get locked => '未解锁';
	@override String get lockedByLevel => '关卡未解锁';
	@override String get lockedDesc => '请先通关前一关解锁';
	@override String get btnStart => '开始';
	@override String get btnReplay => '重玩此难度';
	@override String btnContinue({required Object percent}) => '继续游玩 (进度 ${percent}%)';
	@override String get btnReset => '放弃进度并重新开始';
	@override String savedProgress({required Object percent}) => '⚡ 检测到未完成存档 (已拼 ${percent}%)';
	@override String get previewHint => '预览切线';
	@override String get badgeCleared => '已通关';
	@override String get deleteTitle => '删除自制拼图';
	@override String deleteDesc({required Object title}) => '确定要永久删除「${title}」吗？删除后不可恢复。';
	@override String get deleteDescGeneric => '确定要永久删除此自制拼图吗？删除后不可恢复。';
	@override String get deleteConfirm => '确定删除';
	@override String get deleteTooltip => '删除此自制拼图';
	@override String get favAdd => '加入收藏';
	@override String get favRemove => '取消收藏';
	@override String lockedProgress({required Object gap, required Object tier}) => '再获得 ${gap} 张 3 星图即可解锁 ${tier}';
}

// Path: achievementsPage
class _Translations$achievementsPage$zh extends Translations$achievementsPage$en {
	_Translations$achievementsPage$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '成就与统计';
	@override String get stats => '数据统计看板';
	@override String get groupClears => '通关与星级表现';
	@override String get groupAssets => '游玩历程与资产';
	@override String get totalStars => '总星数';
	@override String get totalSolved => '已通关';
	@override String get totalSnaps => '吸附碎片';
	@override String get totalTime => '游玩时长';
	@override String get threeStarCount => '满星通关';
	@override String get coinsOwned => '拥有金币';
	@override String get wall => '成就勋章墙';
	@override String wallCount({required Object count}) => '共 ${count} 项成就';
	@override String get unlocked => '已解锁';
	@override String get locked => '未解锁';
	@override String get claim => '领取';
	@override String get claimed => '已领取';
	@override String coins({required Object count}) => '${count} 金币';
}

// Path: myCenter
class _Translations$myCenter$zh extends Translations$myCenter$en {
	_Translations$myCenter$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override late final _Translations$myCenter$tabs$zh tabs = _Translations$myCenter$tabs$zh._(_root);
	@override late final _Translations$myCenter$topActions$zh topActions = _Translations$myCenter$topActions$zh._(_root);
	@override late final _Translations$myCenter$empty$zh empty = _Translations$myCenter$empty$zh._(_root);
	@override late final _Translations$myCenter$card$zh card = _Translations$myCenter$card$zh._(_root);
	@override late final _Translations$myCenter$orphanDialog$zh orphanDialog = _Translations$myCenter$orphanDialog$zh._(_root);
	@override late final _Translations$myCenter$toast$zh toast = _Translations$myCenter$toast$zh._(_root);
}

// Path: boot
class _Translations$boot$zh extends Translations$boot$en {
	_Translations$boot$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get initTitle => '正在初始化游戏内容…';
	@override String get initSubtitle => '首次启动需联网获取图库，请稍候。';
	@override String get failedTitle => '初始化失败';
	@override String get failedDesc => '无法连接内容服务器，请检查网络后重试。';
	@override String get retry => '重试';
}

// Path: howTo.t1
class _Translations$howTo$t1$zh extends Translations$howTo$t1$en {
	_Translations$howTo$t1$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '拖拽与磁吸';
	@override String get page => '单指拖拽碎片到棋盘正确位置附近，会自动发出清脆吸附声并精准归位锁定。';
}

// Path: howTo.t2
class _Translations$howTo$t2$zh extends Translations$howTo$t2$en {
	_Translations$howTo$t2$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '碎片组队合并 (Cluster)';
	@override String get page => '相连的碎片即使尚未放在棋盘正确格子，也可以在托盘或画布任意处互相拼合，合并后可整体拖动调整。';
}

// Path: howTo.t3
class _Translations$howTo$t3$zh extends Translations$howTo$t3$en {
	_Translations$howTo$t3$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '双指缩放与平移';
	@override String get page => '双指捏合可无级放大/缩小棋盘，双指滑动或鼠标中键拖拽可平移画布，助你轻松对齐细节局部。';
}

// Path: howTo.t4
class _Translations$howTo$t4$zh extends Translations$howTo$t4$en {
	_Translations$howTo$t4$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '底图透视参考 (Ghost)';
	@override String get page => '点击顶部透视图标可在棋盘开启 20%/45% 半透明底图，辅助观察画面线条与色彩快速定位。';
}

// Path: howTo.t5
class _Translations$howTo$t5$zh extends Translations$howTo$t5$en {
	_Translations$howTo$t5$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '边缘碎片筛选';
	@override String get page => '点击边框筛选图标，可高亮所有外围平边碎片并暗淡内部碎片，助你先拼好外层框架。';
}

// Path: howTo.t6
class _Translations$howTo$t6$zh extends Translations$howTo$t6$en {
	_Translations$howTo$t6$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '一键整理托盘';
	@override String get page => '散落在棋盘画布上的单块碎片，点击扫把图标即可瞬间整齐归纳至下方托盘，恢复整洁视野。';
}

// Path: achievements.first_win
class _Translations$achievements$first_win$zh extends Translations$achievements$first_win$en {
	_Translations$achievements$first_win$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '初露锋芒';
	@override String get desc => '通关首张拼图';
}

// Path: achievements.win_10
class _Translations$achievements$win_10$zh extends Translations$achievements$win_10$en {
	_Translations$achievements$win_10$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '熟能生巧';
	@override String get desc => '累计通关 10 张拼图';
}

// Path: achievements.win_50
class _Translations$achievements$win_50$zh extends Translations$achievements$win_50$en {
	_Translations$achievements$win_50$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '拼图达人';
	@override String get desc => '累计通关 50 张拼图';
}

// Path: achievements.win_100
class _Translations$achievements$win_100$zh extends Translations$achievements$win_100$en {
	_Translations$achievements$win_100$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '拼图大师';
	@override String get desc => '累计通关 100 张拼图';
}

// Path: achievements.star_1
class _Translations$achievements$star_1$zh extends Translations$achievements$star_1$en {
	_Translations$achievements$star_1$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '三星启航';
	@override String get desc => '首次以 3 星评价完成拼图';
}

// Path: achievements.star_10
class _Translations$achievements$star_10$zh extends Translations$achievements$star_10$en {
	_Translations$achievements$star_10$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '闪耀之星';
	@override String get desc => '累计获得 10 个 3 星评价';
}

// Path: achievements.star_30
class _Translations$achievements$star_30$zh extends Translations$achievements$star_30$en {
	_Translations$achievements$star_30$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '群星璀璨';
	@override String get desc => '累计获得 30 个 3 星评价';
}

// Path: achievements.star_50
class _Translations$achievements$star_50$zh extends Translations$achievements$star_50$en {
	_Translations$achievements$star_50$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '星光领主';
	@override String get desc => '累计获得 50 个 3 星评价';
}

// Path: achievements.tier_l3
class _Translations$achievements$tier_l3$zh extends Translations$achievements$tier_l3$en {
	_Translations$achievements$tier_l3$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '中阶挑战';
	@override String get desc => '完成一次中等（L3）及以上难度拼图';
}

// Path: achievements.tier_l4
class _Translations$achievements$tier_l4$zh extends Translations$achievements$tier_l4$en {
	_Translations$achievements$tier_l4$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '进阶高手';
	@override String get desc => '完成一次进阶（L4）及以上难度拼图';
}

// Path: achievements.tier_l5
class _Translations$achievements$tier_l5$zh extends Translations$achievements$tier_l5$en {
	_Translations$achievements$tier_l5$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '困难征服';
	@override String get desc => '完成一次困难（L5）及以上难度拼图';
}

// Path: achievements.tier_l6
class _Translations$achievements$tier_l6$zh extends Translations$achievements$tier_l6$en {
	_Translations$achievements$tier_l6$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '极限登顶';
	@override String get desc => '完成一次极限（L6）难度拼图';
}

// Path: achievements.custom_1
class _Translations$achievements$custom_1$zh extends Translations$achievements$custom_1$en {
	_Translations$achievements$custom_1$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '创作者';
	@override String get desc => '完成 1 次自制拼图';
}

// Path: achievements.custom_5
class _Translations$achievements$custom_5$zh extends Translations$achievements$custom_5$en {
	_Translations$achievements$custom_5$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '创意无限';
	@override String get desc => '完成 5 次自制拼图';
}

// Path: achievements.no_hint_win
class _Translations$achievements$no_hint_win$zh extends Translations$achievements$no_hint_win$en {
	_Translations$achievements$no_hint_win$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '心灵手巧';
	@override String get desc => '不使用任何提示完成一局拼图';
}

// Path: achievements.speed_10min
class _Translations$achievements$speed_10min$zh extends Translations$achievements$speed_10min$en {
	_Translations$achievements$speed_10min$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '疾风拼手';
	@override String get desc => '10 分钟内完成 ≥100 片的拼图';
}

// Path: achievements.night_owl
class _Translations$achievements$night_owl$zh extends Translations$achievements$night_owl$en {
	_Translations$achievements$night_owl$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '夜猫子';
	@override String get desc => '在夜间 22:00 ~ 05:00 间完成一局拼图';
}

// Path: achievements.snap_100
class _Translations$achievements$snap_100$zh extends Translations$achievements$snap_100$en {
	_Translations$achievements$snap_100$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '初试身手';
	@override String get desc => '累计吸附 100 片碎片';
}

// Path: achievements.snap_500
class _Translations$achievements$snap_500$zh extends Translations$achievements$snap_500$en {
	_Translations$achievements$snap_500$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '渐入佳境';
	@override String get desc => '累计吸附 500 片碎片';
}

// Path: achievements.snap_2000
class _Translations$achievements$snap_2000$zh extends Translations$achievements$snap_2000$en {
	_Translations$achievements$snap_2000$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '千锤百炼';
	@override String get desc => '累计吸附 2000 片碎片';
}

// Path: achievements.time_30m
class _Translations$achievements$time_30m$zh extends Translations$achievements$time_30m$en {
	_Translations$achievements$time_30m$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '沉浸其中';
	@override String get desc => '累计游玩时间达到 30 分钟';
}

// Path: achievements.time_2h
class _Translations$achievements$time_2h$zh extends Translations$achievements$time_2h$en {
	_Translations$achievements$time_2h$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '拼图发烧友';
	@override String get desc => '累计游玩时间达到 2 小时';
}

// Path: achievements.time_10h
class _Translations$achievements$time_10h$zh extends Translations$achievements$time_10h$en {
	_Translations$achievements$time_10h$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '岁月如歌';
	@override String get desc => '累计游玩时间达到 10 小时';
}

// Path: achievements.daily_7
class _Translations$achievements$daily_7$zh extends Translations$achievements$daily_7$en {
	_Translations$achievements$daily_7$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '日积月累';
	@override String get desc => '累计完成 7 次每日挑战';
}

// Path: achievements.master_all
class _Translations$achievements$master_all$zh extends Translations$achievements$master_all$en {
	_Translations$achievements$master_all$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '拼图宗师';
	@override String get desc => '达成以上全部 24 项成就';
}

// Path: difficulty.tier
class _Translations$difficulty$tier$zh extends Translations$difficulty$tier$en {
	_Translations$difficulty$tier$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get l1 => '新手 Easy';
	@override String get l1_5 => '入门+';
	@override String get l2 => '简单 Beginner';
	@override String get l3 => '普通 Medium';
	@override String get l4 => '进阶 Hard';
	@override String get l5 => '困难 Expert';
	@override String get l6 => '大师 Master';
	@override String get l7 => '宗师 Grandmaster';
}

// Path: difficulty.estimated
class _Translations$difficulty$estimated$zh extends Translations$difficulty$estimated$en {
	_Translations$difficulty$estimated$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get l1 => '1~3分钟';
	@override String get l1_5 => '2~4分钟';
	@override String get l2 => '5~8分钟';
	@override String get l3 => '12~18分钟';
	@override String get l4 => '25~35分钟';
	@override String get l5 => '50~75分钟';
	@override String get l6 => '1.5~3小时';
	@override String get l7 => '3~5小时';
}

// Path: difficulty.aspect
class _Translations$difficulty$aspect$zh extends Translations$difficulty$aspect$en {
	_Translations$difficulty$aspect$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get square => '1:1 正方形';
	@override String get portrait2x3 => '2:3 竖屏';
	@override String get landscape3x2 => '3:2 横屏';
	@override String get portrait3x4 => '3:4 竖屏';
	@override String get landscape4x3 => '4:3 横屏';
}

// Path: myCenter.tabs
class _Translations$myCenter$tabs$zh extends Translations$myCenter$tabs$en {
	_Translations$myCenter$tabs$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String inProgress({required Object count}) => '进行中 (${count})';
	@override String favorites({required Object count}) => '收藏 (${count})';
	@override String completed({required Object count}) => '已完成 (${count})';
	@override String custom({required Object count}) => '自制 (${count})';
}

// Path: myCenter.topActions
class _Translations$myCenter$topActions$zh extends Translations$myCenter$topActions$en {
	_Translations$myCenter$topActions$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get gallery => '相册选图';
	@override String get gallerySub => '本地自制';
	@override String get online => '在线搜图';
	@override String get onlineSub => '海量图库';
	@override String get archive => '素材库';
	@override String archiveSub({required Object count}) => '${count} 张';
	@override String get import => '导入图包';
	@override String get importSub => 'ZIP扩展';
}

// Path: myCenter.empty
class _Translations$myCenter$empty$zh extends Translations$myCenter$empty$en {
	_Translations$myCenter$empty$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get inProgressTitle => '暂无进行中的拼图';
	@override String get inProgressSub => '挑一张喜欢的拼图，开启拼图时光吧！';
	@override String get favoritesTitle => '还没有收藏的拼图';
	@override String get favoritesSub => '在选择难度面板中点击红心，可快捷收藏';
	@override String get completedTitle => '还没有完成过拼图';
	@override String get completedSub => '通关任意一张拼图，即可在此记录辉煌战绩！';
	@override String get customTitle => '暂无自制拼图';
	@override String get customSub => '点击上方“相册选图”等工具，打造专属自制拼图！';
	@override String get goExplore => '去挑选拼图';
	@override String get create => '相册选图制作';
}

// Path: myCenter.card
class _Translations$myCenter$card$zh extends Translations$myCenter$card$en {
	_Translations$myCenter$card$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get orphan => '失效';
	@override String get orphanDesc => '已失效 · 点击清理';
	@override String progress({required Object percent}) => '${percent}%';
	@override String get retry => '再挑战';
}

// Path: myCenter.orphanDialog
class _Translations$myCenter$orphanDialog$zh extends Translations$myCenter$orphanDialog$en {
	_Translations$myCenter$orphanDialog$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String get title => '拼图资源已失效';
	@override String desc({required Object title}) => '该拼图资源已从本地或列表中移除，无法继续游玩。\n是否从记录与收藏中清理移除「${title}」？';
	@override String get keep => '暂保留';
	@override String get remove => '清理移除';
}

// Path: myCenter.toast
class _Translations$myCenter$toast$zh extends Translations$myCenter$toast$en {
	_Translations$myCenter$toast$zh._(TranslationsZh root) : this._root = root, super.internal(root);

	final TranslationsZh _root; // ignore: unused_field

	// Translations
	@override String importSuccess({required Object count}) => '已成功导入 ${count} 张图片到素材库';
	@override String importFailed({required Object error}) => '选择图片失败：${error}';
	@override String get webviewMissing => '当前系统未安装 WebView2 运行时，无法使用在线搜图';
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
			'common.sync' => '刷新同步',
			'common.back' => '返回',
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
			'settings.scatterModeTitle' => '棋盘模式',
			'settings.scatterModeDescTray' => '散落碎片收纳在底部托盘',
			'settings.scatterModeDescTabletop' => '散落碎片分布在棋盘周围',
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
			'settings.footerVersion' => ({required Object version}) => '版本 ${version}',
			'settings.toastCacheCleared' => '缩略图缓存已清空，下次浏览时会自动重新生成',
			'settings.toastCacheClearFailed' => ({required Object error}) => '清理缓存失败: ${error}',
			'settings.languageTitle' => '语言',
			'settings.languageDesc' => '应用显示语言 / App Language',
			'settings.languageSystem' => '跟随系统',
			'settings.languageZh' => '简体中文',
			'settings.languageEn' => 'English',
			'settings.timeSeconds' => ({required Object count}) => '${count} 秒',
			'settings.timeMinutes' => ({required Object count}) => '${count} 分',
			'settings.timeHoursMinutes' => ({required Object hours, required Object minutes}) => '${hours} 小时 ${minutes} 分',
			'home.loadImageFailed' => '关卡图片加载失败，请重试',
			'home.puzzleTitle' => '拼图',
			'home.emptyCategory' => '小狐狸没找到该分类的关卡',
			'home.viewAll' => '查看全部',
			'home.allCategories' => '全部分类',
			'home.bannerDailyTitle' => ({required Object month, required Object day}) => '${month}月${day}日 · 今日专属',
			'home.bannerDailySub' => '每日专属拼图 · 激活大脑',
			'home.bannerDailyBadge' => '每日挑战',
			'daily.todayFallback' => '今日挑战',
			'daily.dateChallenge' => ({required Object month, required Object day}) => '${month}月${day}日 挑战',
			'daily.notUnlocked' => '⏳ 未到解锁时间，敬请期待！',
			'daily.dateCaption' => ({required Object month, required Object day}) => '${month} 月 ${day} 日',
			'daily.todayTitle' => ({required Object month, required Object day}) => '${month}月${day}日 · 今日挑战',
			'daily.btnClearedReplay' => '已通关 (重玩)',
			'daily.btnResume' => '继续挑战',
			'daily.btnStart' => '开始挑战',
			'daily.totalProgress' => ({required Object done, required Object total}) => '每日总进度: ${done}/${total}',
			'daily.streakDays' => ({required Object count}) => '连胜 ${count} 天',
			'daily.loadingMonth' => ({required Object month}) => '正在加载 ${month} 挑战关卡...',
			'daily.loadMonthFailed' => ({required Object month}) => '加载 ${month} 关卡失败，请检查网络后重试',
			'daily.emptyMonth' => ({required Object month}) => '暂未下载 ${month} 关卡数据',
			'daily.downloadMonth' => '下载本月关卡',
			'daily.monthTitle' => ({required Object year, required Object month}) => '${year}年${month}月',
			'daily.monthCompleted' => ({required Object done, required Object total}) => '已完成 ${done}/${total}',
			'events.emptyTitle' => '小狐狸没找到正在进行的活动',
			'events.emptyHint' => '下拉刷新或稍后再来看看吧',
			'events.badgeActive' => '限时进行中',
			'events.badgePast' => '往期活动',
			'events.badgeZip' => '离线整包',
			'events.badgeOnline' => '在线精选',
			'events.descFallback' => '精彩专题拼图挑战',
			'events.subFallback' => '限时活动挑战',
			'events.badgeLimited' => '限时活动',
			'events.enter' => '进入挑战',
			'levels.empty' => '暂无可用关卡',
			'levels.titleOf' => ({required Object title, required Object index}) => '${title} · 第 ${index} 关',
			'levels.retryDownload' => '重试下载',
			'levels.retryLoad' => '重试加载',
			'levels.countLabel' => ({required Object count}) => '共 ${count} 个关卡',
			'levels.countWithSize' => ({required Object count, required Object size}) => '共 ${count} 个关卡 · ${size}',
			'levels.imgLoadFailed' => ({required Object error}) => '图片加载失败: ${error}',
			'levels.networkFail' => '关卡图片下载失败，请检查网络后重试',
			'collections.toastReady' => ({required Object title}) => '「${title}」下载就绪，可离线畅玩',
			'collections.toastFailed' => '下载失败，请检查网络后重试',
			'collections.toastError' => ({required Object error}) => '下载异常: ${error}',
			'collections.statsTitle' => '精选图集',
			'collections.statsCount' => ({required Object count}) => '${count} 套',
			'collections.emptyAll' => '暂无图集内容',
			'collections.emptyHint' => '下拉刷新同步官方资源',
			'collections.emptyCollections' => '暂无图集',
			'collections.downloading' => ({required Object title, required Object percent}) => '「${title}」正在下载中 (${percent}%)，请稍候...',
			'collections.startDownload' => ({required Object title}) => '开始下载「${title}」...',
			'collections.levelCount' => ({required Object count}) => '${count} 关',
			'collections.badgeDownloaded' => '已下载',
			'collections.badgeDownload' => '下载',
			'collections.freeTooltip' => '释放图集存储空间',
			'collections.clearTitle' => ({required Object title}) => '清理「${title}」',
			'collections.clearDesc' => ({required Object size}) => '确定要清理已下载的本地资源吗？\n清理后可释放 ${size} 磁盘空间。您随时可以重新下载。',
			'collections.confirmClear' => '确认清理',
			'collections.toastCleared' => '已释放图集本地存储空间',
			'collections.toastClearFailed' => '清理失败，请重试',
			'collections.typeOfficial' => '官方图集',
			'collections.typeEvent' => '限时活动',
			'pack.deleteTitle' => ({required Object title}) => '删除「${title}」图包',
			'pack.deleteDesc' => ({required Object count, required Object size}) => '确定要删除此扩展图包吗？\n将同时清理包内 ${count} 个关卡并释放 ${size} 存储空间。',
			'pack.confirmDelete' => '确认删除',
			'pack.toastDeleteFailed' => '删除失败，请重试',
			'pack.imageMissing' => '关卡图片文件不存在',
			'pack.deleteTooltip' => '删除此图包',
			'pack.levelCount' => ({required Object count}) => '${count} 关卡',
			'pack.emptyLevels' => '此图包中暂无关卡图片',
			'pack.sourceLocal' => '相册 / 本地',
			'pack.sourceNetwork' => '网络',
			'unlock.stars3' => ({required Object req, required Object current}) => '需要获得 3 星的不同拼图达到 ${req} 张（当前 ${current}/${req}）',
			'unlock.daily' => '完成第 1 关主线即可解锁每日挑战',
			'unlock.eventPack' => ({required Object req, required Object current}) => '完成 ${req} 关主线即可解锁活动与主题包（当前 ${current}/${req}）',
			'myPuzzles.actionGallery' => '相册选图',
			'myPuzzles.subBatch' => '批量导入',
			'myPuzzles.actionImportPack' => '导入关卡包',
			'myPuzzles.subZip' => 'ZIP 扩展包',
			'myPuzzles.actionOnline' => '在线搜图',
			'myPuzzles.subOnline' => '海量图库',
			'myPuzzles.importedPacksTitle' => '已导入扩展包',
			'myPuzzles.importedPacksCount' => ({required Object count}) => '${count} 个扩展包',
			'myPuzzles.customTitle' => '自制关卡',
			'myPuzzles.emptyTitle' => '小狐狸抱着空篮子等你制作拼图',
			'myPuzzles.emptyHint' => '点击上方「相册选图」或「素材库」开始制作吧！',
			'myPuzzles.packBadge' => '扩展合辑',
			'myPuzzles.packDescFallback' => '精选拼图扩展关卡合辑',
			'myPuzzles.packTotalLevels' => ({required Object count}) => '共 ${count} 关',
			'drawer.title' => '素材库',
			'drawer.count' => ({required Object count}) => '${count} 张素材',
			'drawer.clearAllTitle' => '清空素材库',
			'drawer.clearAllDesc' => '确定要清空所有待制作的素材图片吗？（不会影响已经制作成功的拼图关卡）',
			'drawer.clearAll' => '清空全部',
			'drawer.emptyTitle' => '素材库暂无图片',
			'drawer.emptyHint' => '点击「相册选图」批量导入本地照片，或在「在线搜图」中一键下载，即可将图片加入素材库随时制作拼图。',
			'drawer.close' => '关闭',
			'drawer.makePuzzle' => '制作拼图',
			'drawer.deleteImageTooltip' => '删除此图片',
			'drawer.fileMissing' => '素材文件不存在或已被清理',
			'crop.title' => '裁剪与自制拼图',
			'crop.regionLabel' => ({required Object width, required Object height}) => '裁切区域: ${width} × ${height}',
			'crop.gestureHint' => '按住拖动调整裁切位置 · 双指或滚轮缩放',
			'crop.saving' => '正在保存...',
			'crop.saveButton' => '保存自制关卡',
			'crop.optimizing' => '正在优化画质并生成自制关卡...',
			'crop.saveFailedToast' => ({required Object error}) => '保存失败: ${error}',
			'online.savedBanner' => ({required Object width, required Object height}) => '已存入素材库 (${width}×${height})',
			'online.savedSourceSub' => '来源: 网络 · 点击查看',
			'online.alreadyInBox' => '该图片已在下载箱中',
			'online.downloadFailed' => ({required Object error}) => '下载图片失败: ${error}',
			'online.noHighResDetected' => '未在当前页面检测到高清大图，请点击进入照片详情页后再试',
			'online.closePickerTooltip' => '关闭在线选图',
			'online.backTooltip' => '后退',
			'online.refreshTooltip' => '刷新',
			'online.extracting' => '正在提取...',
			'online.extractCurrent' => '提取本页大图',
			'online.dismissTooltip' => '关闭提示',
			'share.title' => '分享成绩',
			'share.exportTooltip' => '导出分享',
			'share.toastSaved' => '分享卡片已保存到临时目录',
			'share.toastExportFailed' => ({required Object error}) => '导出失败: ${error}',
			'share.completed' => '拼图完成!',
			'share.timeLabel' => '用时',
			'share.piecesLabel' => '碎片',
			'share.stepsLabel' => '步数',
			'share.exporting' => '导出中...',
			'share.saveButton' => '保存分享卡片',
			'importPack.pickFailed' => ({required Object error}) => '选择文件失败: ${error}',
			'importPack.hintPickFile' => '请选择本地 ZIP 文件或输入网络下载地址',
			'importPack.extractingLocal' => '正在解压并解析本地图包...',
			'importPack.downloadingNet' => '正在下载并解压网络图包...',
			'importPack.imported' => ({required Object title, required Object count}) => '成功导入《${title}》(共 ${count} 关)',
			'importPack.importFailedToast' => ({required Object error}) => '导入失败: ${error}',
			'importPack.appbarTitle' => '导入扩展图包 (.zip)',
			'importPack.infoBanner' => '支持导入任意包含 JPG/PNG/WebP 图片的 ZIP 压缩包；导入后将自动生成独立合辑，可随时整包删除。',
			'importPack.methodLocal' => '方式一：从本地文件选择',
			'importPack.browseHint' => '点击右侧按钮选择 .zip 文件',
			'importPack.browse' => '浏览...',
			'importPack.methodNetwork' => '方式二：输入网络下载地址',
			'importPack.testChip1' => '测试包: 赛博霓虹',
			'importPack.testChip2' => '测试包: 纯图片猫咪',
			'importPack.startImport' => '开始导入并解析',
			'background.title' => '更换拼图背景',
			'background.tableLabel' => ({required Object index}) => '桌板 ${index}',
			'howTo.title' => '玩法与操作技巧',
			'howTo.welcomeTitle' => '轻松上手异形拼图',
			'howTo.welcomeSub' => '熟悉以下核心操作手势与辅助工具，能让你在挑战高难度拼图时事半功倍！',
			'howTo.t1.title' => '拖拽与磁吸',
			'howTo.t1.page' => '单指拖拽碎片到棋盘正确位置附近，会自动发出清脆吸附声并精准归位锁定。',
			'howTo.t2.title' => '碎片组队合并 (Cluster)',
			'howTo.t2.page' => '相连的碎片即使尚未放在棋盘正确格子，也可以在托盘或画布任意处互相拼合，合并后可整体拖动调整。',
			'howTo.t3.title' => '双指缩放与平移',
			'howTo.t3.page' => '双指捏合可无级放大/缩小棋盘，双指滑动或鼠标中键拖拽可平移画布，助你轻松对齐细节局部。',
			'howTo.t4.title' => '底图透视参考 (Ghost)',
			'howTo.t4.page' => '点击顶部透视图标可在棋盘开启 20%/45% 半透明底图，辅助观察画面线条与色彩快速定位。',
			'howTo.t5.title' => '边缘碎片筛选',
			'howTo.t5.page' => '点击边框筛选图标，可高亮所有外围平边碎片并暗淡内部碎片，助你先拼好外层框架。',
			'howTo.t6.title' => '一键整理托盘',
			'howTo.t6.page' => '散落在棋盘画布上的单块碎片，点击扫把图标即可瞬间整齐归纳至下方托盘，恢复整洁视野。',
			'logs.title' => '运行日志',
			'logs.filterPrefix' => '过滤：',
			'logs.filterAll' => '全部',
			'logs.scrollTopTooltip' => '回到顶部（最新日志）',
			'logs.copyTooltip' => '复制日志',
			'logs.copyFiltered' => ({required Object count}) => '复制当前视图（${count}）',
			'logs.copyAll' => ({required Object count}) => '复制全部日志（${count}）',
			'logs.nothingToCopy' => '暂无可复制的日志',
			'logs.copiedFiltered' => ({required Object count}) => '已复制当前视图 ${count} 条日志',
			'logs.copiedAll' => ({required Object count}) => '已复制全部 ${count} 条日志',
			'logs.clearTooltip' => '清除日志',
			'logs.clearConfirmTitle' => '清除全部日志？',
			'logs.clearConfirmDesc' => '将删除磁盘上的日志文件，并清空内存中的日志记录，此操作不可恢复。\n清除后日志会从头重新记录，下次复制时内容将大幅减少。',
			'logs.clearConfirmBtn' => '清除日志',
			'logs.clearedToast' => '日志已清除，正在从空白重新记录',
			'logs.emptyFiltered' => '当前过滤条件下暂无日志',
			'logs.loading' => '日志加载中…',
			'logs.close' => '关闭',
			'source.main' => '主线',
			'source.daily' => '每日',
			'source.custom' => '自制',
			'source.pack' => '扩展包',
			'source.album' => '相册',
			'source.online' => '网络',
			'source.preset' => '官方',
			'source.official' => '官方图集',
			'source.event' => '限时活动',
			'downloads.q4k' => '4K 超清',
			'downloads.q2k' => '2K 2.5K',
			'downloads.q1080' => 'FHD 全高清',
			'downloads.q720' => 'HD 高清',
			'downloads.qsd' => '标清',
			'achievements.first_win.title' => '初露锋芒',
			'achievements.first_win.desc' => '通关首张拼图',
			'achievements.win_10.title' => '熟能生巧',
			'achievements.win_10.desc' => '累计通关 10 张拼图',
			'achievements.win_50.title' => '拼图达人',
			'achievements.win_50.desc' => '累计通关 50 张拼图',
			'achievements.win_100.title' => '拼图大师',
			'achievements.win_100.desc' => '累计通关 100 张拼图',
			'achievements.star_1.title' => '三星启航',
			'achievements.star_1.desc' => '首次以 3 星评价完成拼图',
			'achievements.star_10.title' => '闪耀之星',
			'achievements.star_10.desc' => '累计获得 10 个 3 星评价',
			'achievements.star_30.title' => '群星璀璨',
			'achievements.star_30.desc' => '累计获得 30 个 3 星评价',
			'achievements.star_50.title' => '星光领主',
			'achievements.star_50.desc' => '累计获得 50 个 3 星评价',
			'achievements.tier_l3.title' => '中阶挑战',
			'achievements.tier_l3.desc' => '完成一次中等（L3）及以上难度拼图',
			'achievements.tier_l4.title' => '进阶高手',
			'achievements.tier_l4.desc' => '完成一次进阶（L4）及以上难度拼图',
			'achievements.tier_l5.title' => '困难征服',
			'achievements.tier_l5.desc' => '完成一次困难（L5）及以上难度拼图',
			'achievements.tier_l6.title' => '极限登顶',
			'achievements.tier_l6.desc' => '完成一次极限（L6）难度拼图',
			'achievements.custom_1.title' => '创作者',
			'achievements.custom_1.desc' => '完成 1 次自制拼图',
			'achievements.custom_5.title' => '创意无限',
			'achievements.custom_5.desc' => '完成 5 次自制拼图',
			'achievements.no_hint_win.title' => '心灵手巧',
			'achievements.no_hint_win.desc' => '不使用任何提示完成一局拼图',
			'achievements.speed_10min.title' => '疾风拼手',
			'achievements.speed_10min.desc' => '10 分钟内完成 ≥100 片的拼图',
			'achievements.night_owl.title' => '夜猫子',
			'achievements.night_owl.desc' => '在夜间 22:00 ~ 05:00 间完成一局拼图',
			'achievements.snap_100.title' => '初试身手',
			'achievements.snap_100.desc' => '累计吸附 100 片碎片',
			'achievements.snap_500.title' => '渐入佳境',
			'achievements.snap_500.desc' => '累计吸附 500 片碎片',
			'achievements.snap_2000.title' => '千锤百炼',
			'achievements.snap_2000.desc' => '累计吸附 2000 片碎片',
			'achievements.time_30m.title' => '沉浸其中',
			'achievements.time_30m.desc' => '累计游玩时间达到 30 分钟',
			'achievements.time_2h.title' => '拼图发烧友',
			'achievements.time_2h.desc' => '累计游玩时间达到 2 小时',
			'achievements.time_10h.title' => '岁月如歌',
			'achievements.time_10h.desc' => '累计游玩时间达到 10 小时',
			'achievements.daily_7.title' => '日积月累',
			'achievements.daily_7.desc' => '累计完成 7 次每日挑战',
			'achievements.master_all.title' => '拼图宗师',
			'achievements.master_all.desc' => '达成以上全部 24 项成就',
			'difficulty.tier.l1' => '新手 Easy',
			'difficulty.tier.l1_5' => '入门+',
			'difficulty.tier.l2' => '简单 Beginner',
			'difficulty.tier.l3' => '普通 Medium',
			'difficulty.tier.l4' => '进阶 Hard',
			'difficulty.tier.l5' => '困难 Expert',
			'difficulty.tier.l6' => '大师 Master',
			'difficulty.tier.l7' => '宗师 Grandmaster',
			'difficulty.estimated.l1' => '1~3分钟',
			'difficulty.estimated.l1_5' => '2~4分钟',
			'difficulty.estimated.l2' => '5~8分钟',
			'difficulty.estimated.l3' => '12~18分钟',
			'difficulty.estimated.l4' => '25~35分钟',
			'difficulty.estimated.l5' => '50~75分钟',
			'difficulty.estimated.l6' => '1.5~3小时',
			'difficulty.estimated.l7' => '3~5小时',
			'difficulty.aspect.square' => '1:1 正方形',
			'difficulty.aspect.portrait2x3' => '2:3 竖屏',
			'difficulty.aspect.landscape3x2' => '3:2 横屏',
			'difficulty.aspect.portrait3x4' => '3:4 竖屏',
			'difficulty.aspect.landscape4x3' => '4:3 横屏',
			'difficulty.pieceCount' => ({required Object cols, required Object rows, required Object count}) => '${cols} x ${rows} (${count} 块)',
			'difficulty.recommended' => '推荐',
			'game.titleLevel' => ({required Object index}) => '第 ${index} 关',
			'game.titleDaily' => ({required Object date}) => '${date} 每日挑战',
			'game.titleCustom' => '自制拼图',
			'game.titlePack' => ({required Object title}) => '${title}',
			'game.tooltipBack' => '返回',
			'game.tooltipEdges' => '仅显示边缘碎片',
			'game.tooltipEdgesAll' => '显示全部碎片',
			'game.tooltipHint' => '智能提示',
			'game.tooltipGhost' => ({required Object opacity}) => '底图透视 ${opacity}%',
			'game.tooltipGhostOff' => '底图透视关闭',
			'game.tooltipPreview' => '查看原图',
			'game.tooltipOrganize' => '一键整理托盘',
			'game.tooltipChangeBg' => '更换壁纸背景',
			'game.hintNotEnoughCoins' => ({required Object price, required Object coins}) => '金币不足（当前难度提示需 ${price} 金币，当前拥有 ${coins}）',
			'game.imageDecodeFailed' => '图片解码失败，请重试',
			'game.tapToReturn' => '点击任意处返回拼图',
			'game.zoomReset' => '重置',
			'game.progress' => ({required Object percent}) => '${percent}%',
			'victory.title' => '拼图完成！',
			'victory.stars' => ({required num count}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('zh'))(count, other: '${count} 星', ), 
			'victory.time' => ({required Object time}) => '用时：${time}',
			'victory.pieces' => ({required Object count}) => '${count} 块',
			'victory.coinsReward' => ({required Object coins}) => '+${coins} 金币',
			'victory.newAchievements' => ({required Object count}) => '${count} 项新成就',
			'victory.btnNext' => '下一关',
			'victory.btnShare' => '分享成绩',
			'victory.btnView' => '欣赏拼图',
			'victory.btnExit' => '退出',
			'victory.btnSaveWallpaper' => '保存壁纸',
			'victory.perfect' => '完美！',
			'victory.great' => '精彩！',
			'victory.btnClose' => '关闭弹窗 (Esc)',
			'victory.toastWallpaperSaved' => '壁纸已保存到本地',
			'victory.toastSaveWallpaperFailed' => ({required Object error}) => '壁纸保存失败：${error}',
			'continueDialog.progressLabel' => '已拼进度',
			'continueDialog.timeLabel' => '已用时间',
			'continueDialog.spec' => ({required Object key}) => '规格 ${key}',
			'continueDialog.specPieces' => ({required Object key, required Object count}) => '规格 ${key}（${count} 块）',
			'continueDialog.piecesCount' => ({required Object count}) => '碎片 ${count}',
			'continueDialog.foxHint' => '小狐狸在等你完成这幅拼图呢',
			'continueDialog.restartTitle' => '重新开始？',
			'continueDialog.restartDesc' => '将清除该难度的存档进度，不可恢复，确定重新开始吗？',
			'continueDialog.btnRestart' => '重新开始',
			'continueDialog.restartConfirm' => '确定重开',
			'continueDialog.btnResume' => '继续挑战',
			'chooseDifficulty.title' => '选择难度',
			'chooseDifficulty.pieces' => ({required Object count}) => '${count} 块',
			'chooseDifficulty.recommended' => '推荐',
			'chooseDifficulty.locked' => '未解锁',
			'chooseDifficulty.lockedByLevel' => '关卡未解锁',
			'chooseDifficulty.lockedDesc' => '请先通关前一关解锁',
			'chooseDifficulty.btnStart' => '开始',
			'chooseDifficulty.btnReplay' => '重玩此难度',
			'chooseDifficulty.btnContinue' => ({required Object percent}) => '继续游玩 (进度 ${percent}%)',
			'chooseDifficulty.btnReset' => '放弃进度并重新开始',
			'chooseDifficulty.savedProgress' => ({required Object percent}) => '⚡ 检测到未完成存档 (已拼 ${percent}%)',
			'chooseDifficulty.previewHint' => '预览切线',
			'chooseDifficulty.badgeCleared' => '已通关',
			'chooseDifficulty.deleteTitle' => '删除自制拼图',
			'chooseDifficulty.deleteDesc' => ({required Object title}) => '确定要永久删除「${title}」吗？删除后不可恢复。',
			'chooseDifficulty.deleteDescGeneric' => '确定要永久删除此自制拼图吗？删除后不可恢复。',
			'chooseDifficulty.deleteConfirm' => '确定删除',
			'chooseDifficulty.deleteTooltip' => '删除此自制拼图',
			'chooseDifficulty.favAdd' => '加入收藏',
			'chooseDifficulty.favRemove' => '取消收藏',
			'chooseDifficulty.lockedProgress' => ({required Object gap, required Object tier}) => '再获得 ${gap} 张 3 星图即可解锁 ${tier}',
			'achievementsPage.title' => '成就与统计',
			'achievementsPage.stats' => '数据统计看板',
			'achievementsPage.groupClears' => '通关与星级表现',
			'achievementsPage.groupAssets' => '游玩历程与资产',
			'achievementsPage.totalStars' => '总星数',
			'achievementsPage.totalSolved' => '已通关',
			'achievementsPage.totalSnaps' => '吸附碎片',
			'achievementsPage.totalTime' => '游玩时长',
			'achievementsPage.threeStarCount' => '满星通关',
			'achievementsPage.coinsOwned' => '拥有金币',
			'achievementsPage.wall' => '成就勋章墙',
			'achievementsPage.wallCount' => ({required Object count}) => '共 ${count} 项成就',
			'achievementsPage.unlocked' => '已解锁',
			'achievementsPage.locked' => '未解锁',
			'achievementsPage.claim' => '领取',
			'achievementsPage.claimed' => '已领取',
			'achievementsPage.coins' => ({required Object count}) => '${count} 金币',
			'myCenter.tabs.inProgress' => ({required Object count}) => '进行中 (${count})',
			'myCenter.tabs.favorites' => ({required Object count}) => '收藏 (${count})',
			'myCenter.tabs.completed' => ({required Object count}) => '已完成 (${count})',
			'myCenter.tabs.custom' => ({required Object count}) => '自制 (${count})',
			'myCenter.topActions.gallery' => '相册选图',
			'myCenter.topActions.gallerySub' => '本地自制',
			'myCenter.topActions.online' => '在线搜图',
			'myCenter.topActions.onlineSub' => '海量图库',
			'myCenter.topActions.archive' => '素材库',
			'myCenter.topActions.archiveSub' => ({required Object count}) => '${count} 张',
			'myCenter.topActions.import' => '导入图包',
			'myCenter.topActions.importSub' => 'ZIP扩展',
			'myCenter.empty.inProgressTitle' => '暂无进行中的拼图',
			'myCenter.empty.inProgressSub' => '挑一张喜欢的拼图，开启拼图时光吧！',
			'myCenter.empty.favoritesTitle' => '还没有收藏的拼图',
			'myCenter.empty.favoritesSub' => '在选择难度面板中点击红心，可快捷收藏',
			'myCenter.empty.completedTitle' => '还没有完成过拼图',
			'myCenter.empty.completedSub' => '通关任意一张拼图，即可在此记录辉煌战绩！',
			'myCenter.empty.customTitle' => '暂无自制拼图',
			'myCenter.empty.customSub' => '点击上方“相册选图”等工具，打造专属自制拼图！',
			'myCenter.empty.goExplore' => '去挑选拼图',
			'myCenter.empty.create' => '相册选图制作',
			'myCenter.card.orphan' => '失效',
			'myCenter.card.orphanDesc' => '已失效 · 点击清理',
			'myCenter.card.progress' => ({required Object percent}) => '${percent}%',
			'myCenter.card.retry' => '再挑战',
			'myCenter.orphanDialog.title' => '拼图资源已失效',
			'myCenter.orphanDialog.desc' => ({required Object title}) => '该拼图资源已从本地或列表中移除，无法继续游玩。\n是否从记录与收藏中清理移除「${title}」？',
			'myCenter.orphanDialog.keep' => '暂保留',
			'myCenter.orphanDialog.remove' => '清理移除',
			'myCenter.toast.importSuccess' => ({required Object count}) => '已成功导入 ${count} 张图片到素材库',
			'myCenter.toast.importFailed' => ({required Object error}) => '选择图片失败：${error}',
			'myCenter.toast.webviewMissing' => '当前系统未安装 WebView2 运行时，无法使用在线搜图',
			'boot.initTitle' => '正在初始化游戏内容…',
			'boot.initSubtitle' => '首次启动需联网获取图库，请稍候。',
			'boot.failedTitle' => '初始化失败',
			'boot.failedDesc' => '无法连接内容服务器，请检查网络后重试。',
			'boot.retry' => '重试',
			_ => null,
		};
	}
}
