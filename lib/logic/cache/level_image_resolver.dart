import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../services/app_logger.dart';
import '../content/app_content.dart';
import '../content/models/puzzle_level_item.dart';
import '../content/network/content_http_client.dart';

/// 网络关卡原图懒落地解析器：保证“见缩略必可玩”
///
/// - 若 `level.isLocalFile && File.exists` 直接返回本地路径
/// - 若 `assets/` 直接返回（无需下载）
/// - 若 `http(s)` 则下载到 `appDocumentsDir/network_levels/<hash>.webp`（单次落盘，幂等）
///   后续缩略与 `GamePage` 复用同一文件，离线可玩
class LevelImageResolver {
  LevelImageResolver._();
  static final LevelImageResolver instance = LevelImageResolver._();

  final ContentHttpClient _httpClient = ContentHttpClient();
  String? _networkLevelsDir;

  Future<String> _getNetworkLevelsDir() async {
    if (_networkLevelsDir != null) return _networkLevelsDir!;
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docDir.path, 'network_levels'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _networkLevelsDir = dir.path;
    return dir.path;
  }

  /// FNV-1a 63 位哈希，与 ImageCacheManager.getCacheKey 同算法，保证同 URL 同哈希
  String _hashUrl(String url) {
    final clean = url.replaceAll(r'\', '/');
    var hash = 0xcbf29ce484222325;
    const fnvPrime = 0x100000001b3;
    final bytes = utf8.encode(clean);
    for (final b in bytes) {
      hash ^= b;
      hash *= fnvPrime;
    }
    final masked = hash & 0x7FFFFFFFFFFFFFFF;
    return masked.toRadixString(16).padLeft(16, '0');
  }

  String _extensionForUrl(String url) {
    final clean = url.split('?').first.toLowerCase();
    if (clean.endsWith('.png')) return '.png';
    if (clean.endsWith('.webp')) return '.webp';
    if (clean.endsWith('.jpeg')) return '.jpeg';
    return '.jpg';
  }

  /// 解析关卡本地路径：本地/资产直接返回；网络则后台下载落盘（幂等，单飞由调用方队列保证）
  Future<String> resolveLevelLocalPath(PuzzleLevelItem level) async {
    final path = level.imagePathOrUrl;

    // 1. 本地文件快路径
    if (level.isLocalFile && path.isNotEmpty) {
      if (File(path).existsSync()) return path;
      // 管线已标记本地但文件被误删，回退到网络下载
    }

    // 2. 资产
    if (path.startsWith('assets/')) return path;

    // 3. 网络：优先复用主线管线（已落盘则直接用）
    if (path.startsWith('http://') || path.startsWith('https://')) {
      // 尝试主线管线已缓存（避免与通用目录重复）
      try {
        final mainLevels = AppContent.instance.isInitialized
            ? AppContent.instance.manager.mainPipeline.levels
            : <PuzzleLevelItem>[];
        final existing = mainLevels.where((l) => l.id == level.id).toList();
        if (existing.isNotEmpty && existing.first.isLocalFile && File(existing.first.imagePathOrUrl).existsSync()) {
          return existing.first.imagePathOrUrl;
        }
      } catch (_) {}

      // 4. 通用网络关卡落地（懒下载，幂等）
      try {
        // 若管线侧 ensure 已支持，直接复用（保持 _levelsMap 同步）
        if (AppContent.instance.isInitialized) {
          try {
            final ensured = await AppContent.instance.manager.ensureMainLevelDownloaded(level);
            if (ensured.isLocalFile && File(ensured.imagePathOrUrl).existsSync()) {
              return ensured.imagePathOrUrl;
            }
          } catch (_) {
            // 回退通用目录
          }
        }

        final dir = await _getNetworkLevelsDir();
        final hash = _hashUrl(path);
        final ext = _extensionForUrl(path);
        final targetPath = p.join(dir, 'net_$hash$ext');
        final targetFile = File(targetPath);
        if (targetFile.existsSync() && await targetFile.length() > 0) {
          return targetPath;
        }

        AppLogger.content.info('LevelImageResolver downloading $hash -> $targetPath url=${AppLogger.sanitizeUrl(path)}');
        final downloaded = await _httpClient.downloadFile(path, targetPath);
        if (downloaded.existsSync() && await downloaded.length() > 0) {
          AppLogger.content.info('LevelImageResolver done $hash bytes=${await downloaded.length()}');
          return downloaded.path;
        }
      } catch (e, st) {
        AppLogger.content.warning('LevelImageResolver failed url=${AppLogger.sanitizeUrl(path)}', e, st);
      }

      // 失败回退原 URL（让上层显示占位）
      return path;
    }

    return path;
  }

  /// 同步快路径：仅判断是否已落地，不触发下载（用于预检）
  bool isLocallyAvailable(PuzzleLevelItem level) {
    final path = level.imagePathOrUrl;
    if (path.startsWith('assets/')) return true;
    if (level.isLocalFile && File(path).existsSync()) return true;
    // 检查通用目录是否已有
    if (path.startsWith('http')) {
      try {
        final hash = _hashUrl(path);
        final ext = _extensionForUrl(path);
        // 同步取 dir 可能未初始化，降级为 false（不阻塞）
        if (_networkLevelsDir != null) {
          final targetPath = p.join(_networkLevelsDir!, 'net_$hash$ext');
          if (File(targetPath).existsSync()) return true;
        }
      } catch (_) {}
    }
    return false;
  }
}
