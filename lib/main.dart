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
import 'services/sound_service.dart';

/// Global Windows WebViewEnvironment instance for InAppWebView
WebViewEnvironment? globalWebViewEnvironment;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Tune Flutter engine global ImageCache to optimize memory and prevent OOM
  PaintingBinding.instance.imageCache.maximumSize = 500;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 150 * 1024 * 1024; // 150 MB

  // Initialize WebViewEnvironment on Windows desktop to prevent blank screen and crash
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    try {
      final appSupportDir = await getApplicationSupportDirectory();
      final envDir = Directory('${appSupportDir.path}/inappwebview_env');
      if (!await envDir.exists()) {
        await envDir.create(recursive: true);
      }
      globalWebViewEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: envDir.path,
        ),
      );
      debugPrint('[WebView:Windows:Init] Global WebViewEnvironment initialized successfully.');
    } catch (e, stack) {
      debugPrint('[WebView:Windows:Error] Failed to initialize WebViewEnvironment: $e\n$stack');
    }
  }

  await ImageCacheManager.instance.init();
  await GameRepository.instance.init();
  await DownloadManager.instance.init();
  await AppContent.instance.init();
  await SoundService.I.init();
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
    // 由种子色一次性生成整套 Material 3 配色，主题内不写死任何具体色值
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2E7D32),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: '异形拼图 Jigsaw Puzzle',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const AppScrollBehavior(),
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        fontFamilyFallback: const ['Microsoft YaHei', 'PingFang SC', 'sans-serif'],
        // 全局浅色背景由 fromSeed 生成（surfaceContainerLow）
        scaffoldBackgroundColor: scheme.surfaceContainerLow,
        // AppBar：背景 = primaryContainer，前景 = onPrimaryContainer
        appBarTheme: AppBarTheme(
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          elevation: 0.5,
          scrolledUnderElevation: 0.5,
          centerTitle: false,
        ),
        // 主按钮默认即 scheme.primary/onPrimary，这里仅统一圆角
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        // 分段按钮选中态 = 主题 primary
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: SegmentedButton.styleFrom(
            selectedBackgroundColor: scheme.primary,
            selectedForegroundColor: scheme.onPrimary,
            visualDensity: VisualDensity.compact,
          ),
        ),
        // 开关选中态 = 主题 primary
        switchTheme: SwitchThemeData(
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? scheme.primary : null,
          ),
          trackOutlineColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? scheme.primary : null,
          ),
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? scheme.onPrimary : null,
          ),
        ),
      ),
      home: const MainScreen(),
    );
  }
}
