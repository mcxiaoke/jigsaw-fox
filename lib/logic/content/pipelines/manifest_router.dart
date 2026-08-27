import 'dart:convert';
import 'dart:io';
import '../models/root_manifest.dart';
import '../network/content_http_client.dart';

/// 根清单发现与路由管理器 (主备轮询容灾 + 本地缓存 + 优雅回退)
class ManifestRouter {
  ManifestRouter({
    required this.bootstrapUrls,
    required this.cacheFilePath,
    ContentHttpClient? httpClient,
  }) : _httpClient = httpClient ?? ContentHttpClient();

  final List<String> bootstrapUrls;
  final String cacheFilePath;
  final ContentHttpClient _httpClient;

  RootManifest? _cachedManifest;
  RootManifest? get currentManifest => _cachedManifest;

  /// 初始化并获取最新的 RootManifest (优先网络拉取，失败降级本地缓存)
  Future<RootManifest> resolveManifest({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedManifest != null) {
      return _cachedManifest!;
    }

    // 1. 尝试从主备 CDN URL 列表轮询拉取
    for (final url in bootstrapUrls) {
      try {
        final json = await _httpClient.fetchJson(url, timeout: const Duration(seconds: 4));
        if (json is Map<String, dynamic>) {
          final manifest = RootManifest.fromJson(json);
          // 写入本地缓存
          await _saveToDiskCache(json);
          _cachedManifest = manifest;
          return manifest;
        }
      } catch (e) {
        // 单个 URL 失败，继续尝试下一个备用 URL
        continue;
      }
    }

    // 2. 网络全部失败，回退到本地磁盘缓存
    final diskManifest = await _loadFromDiskCache();
    if (diskManifest != null) {
      _cachedManifest = diskManifest;
      return diskManifest;
    }

    // 3. 磁盘缓存也无，回退到默认保底清单
    final fallback = _createDefaultFallbackManifest();
    _cachedManifest = fallback;
    return fallback;
  }

  /// 保存清单到本地磁盘缓存
  Future<void> _saveToDiskCache(Map<String, dynamic> json) async {
    try {
      final file = File(cacheFilePath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      await file.writeAsString(jsonEncode(json), flush: true);
    } catch (_) {
      // 忽略磁盘写入异常
    }
  }

  /// 从本地磁盘缓存恢复
  Future<RootManifest?> _loadFromDiskCache() async {
    try {
      final file = File(cacheFilePath);
      if (file.existsSync()) {
        final text = await file.readAsString();
        final json = jsonDecode(text);
        if (json is Map<String, dynamic>) {
          return RootManifest.fromJson(json);
        }
      }
    } catch (_) {
      // 本地缓存文件损坏时安全忽略
    }
    return null;
  }

  /// 兜底默认配置 (保证离线与首次无网可用)
  RootManifest _createDefaultFallbackManifest() {
    return RootManifest(
      schemaVersion: 3,
      updatedAt: DateTime.now(),
      notice: 'Offline mode',
      mainModule: const MainModuleConfig(url: '', version: 0),
      dailyModule: const DailyModuleConfig(
        currentMonth: '',
        zipUrlPattern: '',
        listUrlPattern: '',
        version: 0,
      ),
      eventsModule: const EventsModuleConfig(url: '', version: 0),
    );
  }
}
