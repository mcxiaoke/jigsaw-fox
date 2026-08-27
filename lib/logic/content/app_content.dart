import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'content_manager.dart';
import 'pipelines/pack_content_pipeline.dart';

/// 全局内容与扩展系统门面单例
class AppContent {
  AppContent._();
  static final AppContent instance = AppContent._();

  ContentManager? _manager;
  ContentManager get manager {
    if (_manager == null) {
      throw StateError('AppContent must be initialized by calling init() first.');
    }
    return _manager!;
  }

  static final PackContentPipeline _fallbackPacks = PackContentPipeline(packsBaseDir: '');

  /// 扩展图包管线快捷访问 (带安全 Fallback)
  PackContentPipeline get packs => _manager?.packPipeline ?? _fallbackPacks;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// 全局响应式通知：当内容更新时触发 UI 刷新
  final ValueNotifier<int> contentUpdateNotifier = ValueNotifier<int>(0);

  /// 默认主备 CDN 端点列表 (优先指向测试服务器)
  static const List<String> defaultBootstrapUrls = [
    'http://192.168.1.118/data/www/game/test/manifest.json',
  ];

  Future<void> init({List<String>? bootstrapUrls}) async {
    if (_isInitialized) return;

    final supportDir = await getApplicationSupportDirectory();
    final documentsDir = await getApplicationDocumentsDirectory();

    _manager = ContentManager(
      bootstrapUrls: bootstrapUrls ?? defaultBootstrapUrls,
      appSupportDir: supportDir.path,
      appDocumentsDir: documentsDir.path,
    );

    // 1. 本地快速初始化 (秒开)
    await _manager!.initialize();
    _isInitialized = true;

    // 2. 异步后台网络增量同步
    _backgroundSync();
  }

  Future<void> syncAll() async {
    try {
      await _manager?.syncAll();
      contentUpdateNotifier.value++;
    } catch (e) {
      debugPrint('[AppContent] Sync failed: $e');
    }
  }

  void _backgroundSync() {
    Future.microtask(() async {
      try {
        await _manager?.syncAll();
        contentUpdateNotifier.value++;
      } catch (e) {
        debugPrint('[AppContent] Background sync failed: $e');
      }
    });
  }
}
