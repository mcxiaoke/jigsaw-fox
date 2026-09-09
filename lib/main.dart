import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:jigsawpuzzle/data/favorite_store.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/cache/image_cache_manager.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/download_manager.dart';
import 'package:jigsawpuzzle/pages/boot_gate_page.dart';
import 'package:jigsawpuzzle/pages/main_screen.dart';
import 'package:jigsawpuzzle/services/achievement_store.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/economy_service.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import 'package:jigsawpuzzle/services/recommend_service.dart';
import 'package:jigsawpuzzle/services/sound_service.dart';
import 'package:jigsawpuzzle/services/webview_service.dart';

/// 桌面生命周期监听器（**必须顶层持有**，设计 §7.5）。
///
/// 写成 main() 局部变量会随 main 栈帧结束被 GC 静默回收，回调失效且无任何提示。
AppLifecycleListener? _lifecycleListener;

/// 会话备份节流时间戳（桌面反复切窗不放大磁盘复制）
DateTime? _lastBackupTime;

/// 监听器实例（供测试断言引用仍被持有、回调未失效，设计 §10.3）
@visibleForTesting
AppLifecycleListener? get lifecycleListenerForTest => _lifecycleListener;

/// 会话备份节流时间戳（供测试断言 5 分钟节流生效）
@visibleForTesting
DateTime? get lastBackupTimeForTest => _lastBackupTime;

/// 桌面生命周期钩子注册点（唯一）：Windows 桌面端 `AppLifecycleState.paused`
/// **永不触发**，只有 inactive（失焦）/ hidden（最小化/切后台），
/// 关窗直接走 detached/进程终止——故基于 paused 的 WidgetsBindingObserver
/// 方案在 Windows 上一次都不会执行，改用 Flutter 3.13+ 的 AppLifecycleListener。
void _initLifecycleHooks() {
  _lifecycleListener = AppLifecycleListener(
    onHide: _handleBackgroundSync, // Windows 最小化 / 切到后台
    onInactive: _handleBackgroundSync, // 失焦（有节流，防频繁磁盘复制）
    onPause: _handleBackgroundSync, // 移动端退后台（桌面不触发，保留兼容）
    onExitRequested: () async {
      // 桌面端点 X / Alt+F4：进程终止前最后的同步机会（P05 等待挂起put）
      try {
        if (!StorageManager.instance.isTestInstance) {
          await StorageManager.instance.waitPendingWrites();
          await StorageManager.instance.flushPendingWrites();
          await StorageManager.instance.backupNow();
        } else {
          await StorageManager.instance.waitPendingWrites();
        }
        await StorageManager.instance.closeAll();
      } catch (e, st) {
        AppLogger.system.warning('exit cleanup failed', e, st);
        // 清理失败不阻止退出
      }
      return AppExitResponse.exit;
    },
  );
}

/// flush + 会话备份（§7.8 备份点 B），5 分钟节流
void _handleBackgroundSync() {
  // Fire-and-forget: background sync must not block the UI.
  // ignore: discarded_futures
  StorageManager.instance.flushPendingWrites().then((_) {
    if (StorageManager.instance.isTestInstance) return;
    final now = DateTime.now();
    if (_lastBackupTime != null &&
        now.difference(_lastBackupTime!) < const Duration(minutes: 5)) {
      return;
    }
    _lastBackupTime = now;
    // Fire-and-forget: backup runs in background without blocking.
    // ignore: discarded_futures
    StorageManager.instance.backupNow();
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 0. 日志系统最先初始化（后续所有模块日志均可落盘）
  await AppLogger.init();
  AppLogger.system.info('App launch starting');
  final sw0 = Stopwatch()..start();

  // Tune Flutter engine global ImageCache to optimize memory and prevent OOM
  PaintingBinding.instance.imageCache.maximumSize = 500;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      150 * 1024 * 1024; // 150 MB
  AppLogger.system.info('ImageCache tuned maxSize=500 maxBytes=150MB');

  // Initialize and detect WebView2 environment
  await WebViewService.init();

  // 生命周期钩子必须在 runApp() 之前注册一次（引用由顶层变量持有防 GC）
  _initLifecycleHooks();

  // Hive 必须在所有 Store 初始化之前打开（Store 取 box 时尚未打开会 fail-fast）
  await StorageManager.instance.openAllWithMemoryFallback();
  AppLogger.system.info(
    'StorageManager openAll done ${sw0.elapsedMilliseconds}ms',
  );

  // 语言服务需在 runApp 前完成（避免首帧闪烁，且 LocaleHelper 真源就绪）
  try {
    await LocaleService.instance.init();
  } catch (e, st) {
    AppLogger.system.warning('LocaleService init failed', e, st);
  }

  // §7.8 备份点 A：启动备份——此刻进程内尚无任何业务写入，
  // openBox 期间的 crashRecovery 截断 / compaction 均已完成，.hive 处于一致态。
  // 守卫：openAll 期间有 box 走过兜底重建则跳过本轮，否则重建出的空 box
  // 会立刻成为最新备份，配合「只留 5 份」轮转逐步覆盖历史好备份。
  if (StorageManager.instance.hasRecreatedBoxes) {
    AppLogger.system.severe(
      'Startup backup skipped: boxes were recreated this launch',
    );
  } else {
    await StorageManager.instance.backupNow();
  }

  final sw = Stopwatch()..start();
  // 组1 必须await：首屏与币/成就/收藏/本地内容缓存强依赖。
  // AppContent.initFromDiskCache 纯本地（5~15ms，无网络），runApp 前据此判定
  // initialHome = MainScreen(秒开) 或 BootGatePage(首启初始化)。
  await Future.wait([
    ImageCacheManager.instance.init(),
    GameRepository.instance.init(),
    EconomyService.instance.init(),
    AchievementStore.instance.init(),
    FavoriteStore.instance.init(),
    AppContent.instance.initFromDiskCache(),
  ]);
  AppLogger.system.info('Group1(Core) init done ${sw.elapsedMilliseconds}ms');
  // 推荐难度：只在启动后计算一次（进程内恒定），进入 Home 时各入口直接读全局缓存
  await RecommendService.instance.ensureComputed();
  sw.reset();
  // 组2/3 可后台：下载与音效不阻塞首帧（内容后台增量由 MainScreen/BootGate 收口触发）
  final bgFutures = [
    DownloadManager.instance.init().then((_) {
      AppLogger.system.info(
        'DownloadManager init done ${sw.elapsedMilliseconds}ms',
      );
    }),
    SoundService.I.init().then((_) {
      AppLogger.system.info(
        'SoundService init done ${sw.elapsedMilliseconds}ms',
      );
    }),
  ];
  // 不阻塞首帧，后台并行；首帧先出壳由 contentUpdateNotifier 刷新
  Future.wait(bgFutures).then((_) {
    AppLogger.system.info('Background init group done');
  });
  AppLogger.system.info(
    'App launch Locale=${LocaleService.instance.effectiveLocale.name} lang=${LocaleService.instance.language.name}',
  );
  // 0 闪烁秒开判定：json + main 前 4 关原图齐 → 直进 MainScreen；否则首启 BootGate
  final isContentReady = AppContent.instance.isFirstBootReady();
  AppLogger.system.info(
    'App launch runApp isContentReady=$isContentReady',
  );
  runApp(
    TranslationProvider(
      child: AnimatedBuilder(
        animation: LocaleService.instance,
        builder: (context, _) => JigsawPuzzleApp(
          initialHome: isContentReady
              ? const MainScreen()
              : const BootGatePage(),
        ),
      ),
    ),
  );
}

/// Custom scroll behavior enabling smooth mouse dragging and trackpad gestures across all platforms.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

class JigsawPuzzleApp extends StatefulWidget {
  const JigsawPuzzleApp({this.initialHome = const MainScreen(), super.key});

  /// 首帧宿主：老用户（数据齐）直进 MainScreen；首启走 BootGatePage 初始化
  final Widget initialHome;

  @override
  State<JigsawPuzzleApp> createState() => _JigsawPuzzleAppState();
}

class _JigsawPuzzleAppState extends State<JigsawPuzzleApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    super.didChangeLocales(locales);
    LocaleService.instance.onSystemLocaleChanged();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFD4963C);
    final lightScheme = ColorScheme.fromSeed(
      seedColor: seed,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );

    // slang 翻译（使用全局 t，兼容测试无 TranslationProvider）
    final tr = LocaleSettings.instance.currentTranslations;
    return MaterialApp(
      title: tr.app.titleFull,
      locale: LocaleService.instance.flutterLocale,
      supportedLocales: AppLocaleUtils.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      debugShowCheckedModeBanner: false,
      scrollBehavior: const AppScrollBehavior(),
      themeMode: ThemeMode.light, // 默认亮色 — 休闲明亮
      theme: _buildTheme(lightScheme, Brightness.light),
      darkTheme: _buildTheme(darkScheme, Brightness.dark),
      home: widget.initialHome,
    );
  }

  ThemeData _buildTheme(ColorScheme scheme, Brightness brightness) {
    return ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      useMaterial3: true,
      fontFamilyFallback: const [
        'Microsoft YaHei',
        'PingFang SC',
        'sans-serif',
      ],
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.bold,
          color: scheme.onSurface,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: scheme.primary,
          selectedForegroundColor: scheme.onPrimary,
          backgroundColor: scheme.surfaceContainer,
          foregroundColor: scheme.onSurfaceVariant,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          visualDensity: VisualDensity.compact,
        ),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.onSurfaceVariant,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
