import 'dart:ui';

import 'package:flutter/material.dart';
import 'data/favorite_store.dart';
import 'data/game_repository.dart';
import 'data/storage_manager.dart';
import 'logic/cache/image_cache_manager.dart';
import 'logic/content/app_content.dart';
import 'logic/download_manager.dart';
import 'pages/main_screen.dart';
import 'services/achievement_store.dart';
import 'services/app_logger.dart';
import 'services/economy_service.dart';
import 'services/sound_service.dart';
import 'services/webview_service.dart';

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
      // 桌面端点 X / Alt+F4：进程终止前最后的同步机会
      try {
        if (!StorageManager.instance.isTestInstance) {
          await StorageManager.instance.flushPendingWrites();
          await StorageManager.instance.backupNow();
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
  // ignore: discarded_futures
  StorageManager.instance.flushPendingWrites().then((_) {
    if (StorageManager.instance.isTestInstance) return;
    final now = DateTime.now();
    if (_lastBackupTime != null &&
        now.difference(_lastBackupTime!) < const Duration(minutes: 5)) {
      return;
    }
    _lastBackupTime = now;
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
  // 组1 必须await：首屏与币/成就/收藏强依赖
  await Future.wait([
    ImageCacheManager.instance.init(),
    GameRepository.instance.init(),
    EconomyService.instance.init(),
    AchievementStore.instance.init(),
    FavoriteStore.instance.init(),
  ]);
  AppLogger.system.info('Group1(Core) init done ${sw.elapsedMilliseconds}ms');
  sw.reset();
  // 组2/3 可后台：下载与内容同步、音效不阻塞首帧
  final bgFutures = [
    DownloadManager.instance.init().then((_) {
      AppLogger.system.info(
        'DownloadManager init done ${sw.elapsedMilliseconds}ms',
      );
    }),
    AppContent.instance.init().then((_) {
      AppLogger.system.info('AppContent init done ${sw.elapsedMilliseconds}ms');
    }),
    SoundService.I.init().then((_) {
      AppLogger.system.info(
        'SoundService init done ${sw.elapsedMilliseconds}ms',
      );
    }),
  ];
  // 不阻塞首帧，后台并行；首帧先出壳由 contentUpdateNotifier 刷新
  // ignore: discarded_futures
  Future.wait(bgFutures).then((_) {
    AppLogger.system.info('Background init group done');
  });
  AppLogger.system.info('App launch completed runApp');
  runApp(const JigsawPuzzleApp());
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

class JigsawPuzzleApp extends StatelessWidget {
  const JigsawPuzzleApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFD4963C);
    final lightScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: '异形拼图 Jigsaw Puzzle',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const AppScrollBehavior(),
      themeMode: ThemeMode.light, // 默认亮色 — 休闲明亮
      theme: _buildTheme(lightScheme, Brightness.light),
      darkTheme: _buildTheme(darkScheme, Brightness.dark),
      home: const MainScreen(),
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
