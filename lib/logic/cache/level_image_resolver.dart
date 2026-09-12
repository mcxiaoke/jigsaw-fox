// P1-4：图片/下载链路 best-effort：失败仅降级到备用来源，不阻断主流程
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 网络关卡与封面原图懒落地解析器：保证“见缩略必可玩”与离线秒显
///
/// - 若 `level.isLocalFile && File.exists` 直接返回本地路径
/// - 若 `assets/` 直接返回（无需下载）
/// - 若 `http(s)` 则单飞原子下载到 `{appSupportDir}/levels/network/net_<hash>.<ext>`（单次落盘，幂等）
///   后续缩略与 `GamePage` 复用同一文件，离线可玩
class LevelImageResolver {
  LevelImageResolver._();
  static final LevelImageResolver instance = LevelImageResolver._();

  ContentHttpClient _httpClient = ContentHttpClient();
  final Map<String, Future<String>> _inFlight = <String, Future<String>>{};
  String? _networkLevelsDir;

  @visibleForTesting
  void resetForTest({
    String? networkLevelsDirOverride,
    ContentHttpClient? httpClientOverride,
  }) {
    _networkLevelsDir = networkLevelsDirOverride;
    if (httpClientOverride != null) {
      _httpClient = httpClientOverride;
    }
    _inFlight.clear();
  }

  @visibleForTesting
  Map<String, Future<String>> get inFlightForTest => _inFlight;

  /// 当前是否有前台网络图片（封面/关卡原图）正在下载落地中
  bool get hasInFlightRequests => _inFlight.isNotEmpty;

  /// 当前进行中的前台网络图片请求数
  int get inFlightCount => _inFlight.length;

  /// 预热网络关卡落地根目录，确保冷启动首帧同步探测可用
  Future<void> warmup() async {
    await _getNetworkLevelsDir();
  }

  // P3-5：cleanLegacyThumbnailCache 已删除。项目尚未发版，不存在旧版遗留的
  // thumbnail_cache 目录，该“启动即删目录”属无必要的自动删除既有数据（R1/R5）。

  Future<String> _getNetworkLevelsDir() async {
    if (_networkLevelsDir != null) return _networkLevelsDir!;
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, 'levels', 'network'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _networkLevelsDir = dir.path;
    return dir.path;
  }

  /// FNV-1a 63 位哈希，保证同 URL 同哈希
  String _hashUrl(String url) {
    final clean = url.replaceAll(r'\', '/');
    // FNV-1a offset basis; safe on native (non-JS) targets.
    // ignore: avoid_js_rounded_ints
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

  /// 底层通用网络落地私有方法（Single-Flight 并发去重，防止 .part 临时文件竞态损坏）
  Future<String> _downloadToNetworkDirWithSingleFlight(
    String url,
    String targetPath,
  ) {
    final existingFile = File(targetPath);
    if (existingFile.existsSync() && existingFile.lengthSync() > 0) {
      return Future.value(targetPath);
    }

    final inFlight = _inFlight[targetPath];
    if (inFlight != null) return inFlight;

    final future = () async {
      try {
        final hash = p.basenameWithoutExtension(targetPath);
        AppLogger.content.info(
          'LevelImageResolver downloading $hash -> $targetPath url=${AppLogger.sanitizeUrl(url)}',
        );
        final downloaded = await _httpClient.downloadFile(url, targetPath);
        if (downloaded.existsSync() && downloaded.lengthSync() > 0) {
          AppLogger.content.info(
            'LevelImageResolver done $hash bytes=${downloaded.lengthSync()}',
          );
          return downloaded.path;
        }
        return '';
      } catch (e, st) {
        AppLogger.content.warning(
          'LevelImageResolver download failed url=${AppLogger.sanitizeUrl(url)}',
          e,
          st,
        );
        return '';
      } finally {
        unawaited(_inFlight.remove(targetPath));
      }
    }();

    _inFlight[targetPath] = future;
    return future;
  }

  /// 同步快查：若该远端 URL 已经落盘，直接返回本地文件绝对路径；否则返回 null
  String? getUrlLocalPathIfAvailable(String url) {
    if (_networkLevelsDir == null || url.isEmpty || !url.startsWith('http')) {
      return null;
    }
    try {
      final hash = _hashUrl(url);
      final ext = _extensionForUrl(url);
      final targetPath = p.join(_networkLevelsDir!, 'net_$hash$ext');
      final file = File(targetPath);
      if (file.existsSync() && file.lengthSync() > 0) {
        return targetPath;
      }
    } catch (_) {}
    return null;
  }

  /// 通用 URL 异步落盘方法（用于 Event/Collection 封面等网络图片）：
  /// 内部全量 try-catch 保护，Single-Flight 防并发冲突
  Future<String> resolveUrlLocalPath(String url) async {
    if (url.isEmpty || !url.startsWith('http')) return '';
    try {
      final dir = await _getNetworkLevelsDir();
      final hash = _hashUrl(url);
      final ext = _extensionForUrl(url);
      final targetPath = p.join(dir, 'net_$hash$ext');
      return await _downloadToNetworkDirWithSingleFlight(url, targetPath);
    } catch (e, st) {
      AppLogger.content.warning(
        'LevelImageResolver resolveUrlLocalPath failed url=${AppLogger.sanitizeUrl(url)}',
        e,
        st,
      );
      return '';
    }
  }

  /// 解析关卡本地路径：本地/资产直接返回；网络则后台下载落盘（幂等单飞，保留管线逻辑）
  Future<String> resolveLevelLocalPath(PuzzleLevelItem level) async {
    // 1. 本地文件快路径：有 localPath 就优先用 localPath
    final local = level.localPath;
    if (local != null && local.isNotEmpty) {
      if (local.startsWith('assets/') || File(local).existsSync()) {
        return local;
      }
      // 管线已标记本地但文件被误删，回退到网络下载
    }

    // 2. 远端 URL 解析与下载
    final remoteUrl = level.url;
    if (remoteUrl.startsWith('assets/')) return remoteUrl;

    if (remoteUrl.startsWith('http://') || remoteUrl.startsWith('https://')) {
      // 尝试主线管线已缓存（避免与通用目录重复）
      try {
        final mainLevels = AppContent.instance.isInitialized
            ? AppContent.instance.manager.mainPipeline.levels
            : <PuzzleLevelItem>[];
        final existing = mainLevels.where((l) => l.id == level.id).toList();
        if (existing.isNotEmpty &&
            existing.first.localPath != null &&
            File(existing.first.localPath!).existsSync()) {
          return existing.first.localPath!;
        }
      } catch (e, st) {
        AppLogger.content.fine(
          'LevelImageResolver main-cache probe failed id=${level.id}',
          e,
          st,
        );
      }

      // 3. 通用网络关卡落地（懒下载，幂等）
      try {
        // P1-1 双重守卫：仅主线关卡可走 main 管线。sourceModule 默认值即
        // prefixMain，单条件会被漏传字段的非主线关卡击穿，故必须同时校验 id 前缀。
        final isMainLevel =
            level.sourceModule == CanonicalId.prefixMain &&
            level.id.startsWith('${CanonicalId.prefixMain}:');
        // 若管线侧 ensure 已支持，直接复用（保持 _levelsMap 同步）
        if (isMainLevel && AppContent.instance.isInitialized) {
          try {
            final ensured = await AppContent.instance.manager
                .ensureMainLevelDownloaded(level);
            if (ensured.localPath != null &&
                File(ensured.localPath!).existsSync()) {
              return ensured.localPath!;
            }
          } catch (e, st) {
            // 回退通用目录
            AppLogger.content.warning(
              'LevelImageResolver ensureMainLevelDownloaded failed, '
              'fallback to generic dir id=${level.id}',
              e,
              st,
            );
          }
        }

        final dir = await _getNetworkLevelsDir();
        final hash = _hashUrl(remoteUrl);
        final ext = _extensionForUrl(remoteUrl);
        final targetPath = p.join(dir, 'net_$hash$ext');
        final downloadedPath = await _downloadToNetworkDirWithSingleFlight(
          remoteUrl,
          targetPath,
        );
        if (downloadedPath.isNotEmpty) {
          return downloadedPath;
        }
      } catch (e, st) {
        AppLogger.content.warning(
          'LevelImageResolver failed url=${AppLogger.sanitizeUrl(remoteUrl)}',
          e,
          st,
        );
      }

      // 失败回退原 URL（让上层显示占位）
      return remoteUrl;
    }

    return level.displayPath;
  }

  /// 同步快路径：仅判断是否已落地，不触发下载（用于预检）
  bool isLocallyAvailable(PuzzleLevelItem level) {
    final local = level.localPath;
    if (local != null && local.isNotEmpty) {
      if (local.startsWith('assets/')) return true;
      if (File(local).existsSync()) return true;
    }
    final remoteUrl = level.url;
    if (remoteUrl.startsWith('assets/')) return true;
    if (remoteUrl.startsWith('http')) {
      return getUrlLocalPathIfAvailable(remoteUrl) != null;
    }
    return false;
  }
}
