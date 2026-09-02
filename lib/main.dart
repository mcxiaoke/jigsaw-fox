import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import 'data/game_repository.dart';
import 'logic/cache/image_cache_manager.dart';
import 'logic/content/app_content.dart';
import 'logic/download_manager.dart';
import 'pages/main_screen.dart';
import 'services/achievement_store.dart';
import 'services/app_logger.dart';
import 'services/economy_service.dart';
import 'services/sound_service.dart';

/// Global Windows WebViewEnvironment instance for InAppWebView
WebViewEnvironment? globalWebViewEnvironment;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 0. 日志系统最先初始化（后续所有模块日志均可落盘）
  await AppLogger.init();
  AppLogger.system.info('App launch starting');

  // Tune Flutter engine global ImageCache to optimize memory and prevent OOM
  PaintingBinding.instance.imageCache.maximumSize = 500;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      150 * 1024 * 1024; // 150 MB
  AppLogger.system.info('ImageCache tuned maxSize=500 maxBytes=150MB');

  // Initialize WebViewEnvironment on Windows desktop to prevent blank screen and crash
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    try {
      final appSupportDir = await getApplicationSupportDirectory();
      final envDir = Directory('${appSupportDir.path}/inappwebview_env');
      if (!await envDir.exists()) {
        await envDir.create(recursive: true);
      }
      globalWebViewEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: envDir.path),
      );
      AppLogger.webview.info(
        'Global WebViewEnvironment initialized dir=${envDir.path}',
      );
    } catch (e, stack) {
      AppLogger.webview.severe(
        'Failed to initialize WebViewEnvironment',
        e,
        stack,
      );
    }
  }

  final sw = Stopwatch()..start();
  // 组1 必须await：首屏与币/成就强依赖（main.dart:80 需首帧就绪避免 coins 0 与成就阻塞）
  await Future.wait([
    ImageCacheManager.instance.init(),
    GameRepository.instance.init(),
    EconomyService.instance.init(),
    AchievementStore.instance.init(),
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
