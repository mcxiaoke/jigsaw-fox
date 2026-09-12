// P1-4：发布参考实现（离线工具），统一豁免
// ignore_for_file: avoid_catches_without_on_clauses
// content_selector.dart — 国内外分流 + 主备切换（manifest 竞速选路 + 粘性 + 熔断）
//
// 取代现有 ManifestRouter「顺序轮询、单 URL 4s 超时」的慢路径：
//  - 首启用并行竞速（哪个通道 manifest 先回来就用哪个，显著缩短首启耗时）；
//  - 选中的通道按区域粘性缓存到磁盘，后续启动直连，不再竞速；
//  - 若粘性通道连续失败，触发重新竞速（自适应网络变化）。

import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'channel_config.dart';

class SourceSelector {
  SourceSelector({
    required this.resolver,
    required this.region,
    Dio? dio,
    this.raceTimeout = const Duration(seconds: 6),
    this.stickyFile,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               responseType: ResponseType.plain,
               connectTimeout: const Duration(seconds: 6),
             ),
           );

  final ChannelResolver resolver;
  final String region; // 'cn' | 'global'
  final Duration raceTimeout;
  final Dio _dio;

  /// 粘性缓存文件（默认 appSupportDir/manifest_channel_<region>.txt）
  File? stickyFile;

  Channel? _sticky;

  Future<File> _defaultStickyFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/manifest_channel_$region.txt');
  }

  /// 返回 (选中的通道, manifest 原始字符串)。优先粘性通道，失败则竞速。
  Future<(Channel, String)> selectManifest() async {
    final file = stickyFile ?? await _defaultStickyFile();

    // 1. 粘性：直接用上次胜出的通道（快速秒开）
    final cachedId = await _readSticky(file);
    Channel? candidate = cachedId == null
        ? null
        : resolver.channels.where((c) => c.id == cachedId).firstOrNull;
    if (candidate != null) {
      final body = await _tryFetch(candidate.keyToUrl('manifest.json', ''));
      if (body != null) {
        _sticky = candidate;
        return (candidate, body);
      }
      // 粘性失败 -> 重新竞速
    }

    // 2. 竞速：并行请求所有候选通道，先到先用
    final urls = manifestCandidates(resolver, region);
    final futures = urls
        .map(
          (u) => _dio.get<String>(
            u,
            options: Options(receiveTimeout: raceTimeout),
          ),
        )
        .toList();
    try {
      final resp = await Future.any(futures);
      final ch = _channelOfUrl(resp.realUri.toString());
      if (ch != null && resp.data != null && resp.statusCode == 200) {
        await _writeSticky(file, ch.id);
        _sticky = ch;
        return (ch, resp.data!);
      }
    } on TimeoutException {
      // ignore，落到默认
    } catch (_) {
      // 单个失败被 Future.any 忽略
    }

    // 3. 兜底：顺序再试一遍（竞速全失败时）
    for (final ch in resolver.ordered(region)) {
      final body = await _tryFetch(ch.keyToUrl('manifest.json', ''));
      if (body != null) {
        await _writeSticky(file, ch.id);
        _sticky = ch;
        return (ch, body);
      }
    }
    throw StateError('所有 manifest 通道均不可用 (region=$region)');
  }

  /// 主动重新竞速（如连续失败、定时自检）
  Future<Channel?> rerace() async {
    final file = stickyFile ?? await _defaultStickyFile();
    for (final ch in resolver.ordered(region)) {
      final body = await _tryFetch(ch.keyToUrl('manifest.json', ''));
      if (body != null) {
        await _writeSticky(file, ch.id);
        _sticky = ch;
        return ch;
      }
    }
    return null;
  }

  Channel? get sticky => _sticky;

  Future<String?> _tryFetch(String url) async {
    try {
      final r = await _dio.get<String>(
        url,
        options: Options(receiveTimeout: raceTimeout),
      );
      if (r.statusCode == 200 && r.data != null) return r.data!;
    } catch (_) {}
    return null;
  }

  Channel? _channelOfUrl(String url) {
    for (final c in resolver.channels) {
      if (url.startsWith(c.base)) return c;
    }
    return null;
  }

  Future<String?> _readSticky(File f) async {
    try {
      if (await f.exists()) return (await f.readAsString()).trim();
    } catch (_) {}
    return null;
  }

  Future<void> _writeSticky(File f, String id) async {
    try {
      await f.writeAsString(id);
    } catch (_) {}
  }
}

/// 由 canonical zipKey 合成多平台镜像列表（运行时，不依赖 JSON 写死）。
/// 若 item 带 `zipKey` 且 resolver 就绪 -> 用通道表合成；
/// 否则退回 item 自带的 zipUrl/zipUrls（旧端兼容）。
List<String> buildZipMirrors({
  required Map<String, dynamic> item,
  required ChannelResolver resolver,
  required String region,
}) {
  final zipKey = item['zipKey'] as String?;
  if (zipKey != null && zipKey.isNotEmpty) {
    return resolver.zipMirrors(zipKey, region);
  }
  // 旧端兼容：JSON 自带 zipUrl / zipUrls
  final primary = item['zipUrl'] as String?;
  final extras =
      (item['zipUrls'] as List?)?.map((e) => e.toString()).toList() ?? [];
  final all = <String>[
    if (primary != null && primary.isNotEmpty) primary,
    ...extras,
  ];
  return all.where((u) => u.isNotEmpty).toSet().toList();
}
