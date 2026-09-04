import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';

/// Service managing WebView availability on Windows (WebView2 Runtime detection)
/// and global WebViewEnvironment lifecycle.
class WebViewService {
  WebViewService._();

  /// 全局在线搜图是否可用标志（若系统未安装 WebView2 则为 false）
  static bool isOnlineSearchAvailable = true;

  /// 检测到的 WebView2 版本号
  static String? webViewVersion;

  /// Windows 平台的全局 WebViewEnvironment
  static WebViewEnvironment? environment;

  /// 初始化并探测系统 WebView 环境
  static Future<void> init({
    Future<String?> Function()? versionChecker,
    Future<Directory> Function()? appSupportDirFinder,
    Future<WebViewEnvironment?> Function(WebViewEnvironmentSettings settings)?
    environmentCreator,
  }) async {
    // 移动端及非 Windows 平台自带 Web 内核，直接可用
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      isOnlineSearchAvailable = true;
      return;
    }

    try {
      final checker = versionChecker ?? WebViewEnvironment.getAvailableVersion;
      final version = await checker();
      webViewVersion = version;

      if (version != null && version.isNotEmpty) {
        isOnlineSearchAvailable = true;
        AppLogger.webview.info('WebView2 runtime verified: $version');

        // 初始化 Windows WebViewEnvironment 独立数据目录
        final dirFinder = appSupportDirFinder ?? getApplicationSupportDirectory;
        final appSupportDir = await dirFinder();
        final envDir = Directory('${appSupportDir.path}/inappwebview_env');
        if (!await envDir.exists()) {
          await envDir.create(recursive: true);
        }
        final creator =
            environmentCreator ??
            ((settings) => WebViewEnvironment.create(settings: settings));
        environment = await creator(
          WebViewEnvironmentSettings(userDataFolder: envDir.path),
        );
        AppLogger.webview.info(
          'Global WebViewEnvironment initialized: ${envDir.path}',
        );
      } else {
        isOnlineSearchAvailable = false;
        AppLogger.webview.warning(
          'WebView2 runtime not found on this Windows machine. Online search disabled.',
        );
      }
    } catch (e, stack) {
      AppLogger.webview.warning(
        'Failed to initialize WebView2 environment: $e',
        e,
        stack,
      );
      isOnlineSearchAvailable = false;
    }
  }
}
