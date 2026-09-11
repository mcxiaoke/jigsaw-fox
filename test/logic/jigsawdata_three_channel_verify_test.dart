import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jigsawpuzzle/logic/content/models/puzzle_collection_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/models/root_manifest.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';

/// 三平台 assets 通道验证（R2 主 / Gitee 备 / GitHub 备）
///
/// 目标：用 App 真实的网络客户端（[ContentHttpClient]）与数据模型
/// （RootManifest / PuzzleLevelItem / PuzzleEventItem / PuzzleCollectionItem）
/// 消费三平台 URL，验证「客户端可消费、不报错」，并校验：
///   1. manifest → 各模块 index.json → main 批次/关卡 全链路解析不抛错；
///   2. 所有 json 与图片在三通道均可达；
///   3. zip 主地址 = 相对 zipUrl 以 index.json 为基准解析（v2 同构目录契约），
///      R2 通道该地址必然可达且为合法 zip，字节数与 fileSizeBytes 一致；
///   4. zipUrls 为绝对兜底镜像（Gitee / GitHub Release），主备回退契约成立。
///
/// 用法（默认关闭，不参与常规 CI）：
///   flutter test test/logic/jigsawdata_three_channel_verify_test.dart \
///     --dart-define=CHANNELS_VERIFY=true
///
/// 可选参数：
///   --dart-define=CHANNELS_BRANCH=release   仓库内的发布前缀目录（默认 release）
///   --dart-define=CHANNELS_FULL_ZIP=true    下载全部 zip（默认仅每模块首个）
///   --dart-define=CHANNELS_FULL_MIRRORS=true 严格要求全部兜底镜像可达
///                                            （默认仅要求首个镜像 + 至少一个候选可达，
///                                             因 GitHub Release 在国内网络可能被重置）
///   --dart-define=R2_BASE=... / GITEE_BASE=... / GITHUB_BASE=...  覆盖通道基址
///
/// 全量 hash 对比（每个 json / zip 的 sha256 与本地产物逐一比对）由发布侧
/// `scripts/publish/verify_channels.py` 承担；本测试聚焦客户端消费契约。
const bool _enabled = bool.fromEnvironment('CHANNELS_VERIFY');

/// 仓库内的发布前缀目录（v2 同构目录：远端 `<base>/release/…` 与本地 `jigsaw-data/release/` 一致）
const String _branch = String.fromEnvironment(
  'CHANNELS_BRANCH',
  defaultValue: 'release',
);
const bool _fullZip = bool.fromEnvironment('CHANNELS_FULL_ZIP');
const bool _fullMirrors = bool.fromEnvironment('CHANNELS_FULL_MIRRORS');

Map<String, String> _channelBases() => {
  'r2': const String.fromEnvironment(
    'R2_BASE',
    defaultValue: 'https://jigsawdata.umao.top/$_branch/',
  ),
  'gitee': const String.fromEnvironment(
    'GITEE_BASE',
    defaultValue: 'https://gitee.com/macitee/jigsaw-data/raw/master/$_branch/',
  ),
  'github': const String.fromEnvironment(
    'GITHUB_BASE',
    defaultValue:
        'https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/$_branch/',
  ),
};

/// 与 app 端 AppContent 支持的 schema 区间保持一致。
const int _minSchema = 3;
const int _maxSchema = 4;

Future<void> _expectReachable(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    await res.drain<void>();
    expect(
      res.statusCode,
      200,
      reason: 'URL 不可达 (${res.statusCode}): $url',
    );
  } finally {
    client.close();
  }
}

/// 返回 HTTP 状态码（网络异常返回 0），用于不抛错的候选可达性探测。
Future<int> _status(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  } catch (_) {
    return 0;
  } finally {
    client.close();
  }
}

/// flutter test 环境下系统代理偶发抖动，重试可显著提高通过率。
Future<dynamic> _fetchWithRetry(
  ContentHttpClient client,
  String url, {
  int attempts = 5,
}) async {
  Object? last;
  for (var i = 1; i <= attempts; i++) {
    try {
      return await client.fetchJson(url, timeout: const Duration(seconds: 45));
    } catch (e) {
      last = e;
      debugPrint('fetchJson 尝试 $i/$attempts 失败: $url ($e)');
    }
  }
  throw HttpException('fetchJson 重试 $attempts 次后仍失败: $url ($last)');
}

Future<Map<String, dynamic>> _fetchJson(
  ContentHttpClient client,
  String url,
) async => await _fetchWithRetry(client, url) as Map<String, dynamic>;

/// 下载 zip 并校验：非空、PK magic、字节数与 [expectBytes] 一致。
Future<void> _verifyZip(
  ContentHttpClient client,
  String url, {
  required int? expectBytes,
  required Directory tmpDir,
  required String name,
}) async {
  final file = File('${tmpDir.path}/$name');
  try {
    await client.downloadFile(
      url,
      file.path,
      timeout: const Duration(minutes: 3),
    );
    expect(file.existsSync(), isTrue, reason: 'zip 下载失败: $url');
    final size = file.lengthSync();
    expect(size, greaterThan(0), reason: 'zip 为空: $url');
    final bytes = file.readAsBytesSync();
    expect(
      bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B,
      isTrue,
      reason: '下载内容非合法 zip (PK magic): $url',
    );
    if (expectBytes != null && expectBytes > 0) {
      expect(
        size,
        expectBytes,
        reason: 'zip 字节数与 fileSizeBytes 不符: $url',
      );
    }
    final entries = ZipDecoder()
        .decodeBytes(bytes)
        .files
        .where((f) => f.isFile)
        .toList();
    expect(entries, isNotEmpty, reason: 'zip 内无文件: $url');
    debugPrint('    zip OK $name bytes=$size entries=${entries.length}');
  } finally {
    if (file.existsSync()) file.deleteSync();
  }
}

/// 通用：校验一条 zip 记录的 url 契约与可达性（v2 相对 URL + 绝对兜底镜像）。
///
/// 契约：
///   - [zipUrl] 必须是**相对路径**（如 `zips/202609.zip`），以 [baseUrl]（该模块
///     index.json 所在地址）为基准解析得到主地址；在 `_stage` / `release` 下天然自洽。
///   - [zipUrls] 必须是绝对地址（Gitee / GitHub Release 扁平资产），作为 R2 失效时的兜底。
///   - [expectPrimaryReachable]：R2 通道为 true（同构目录必然命中）；
///     Gitee/GitHub 通道为 false（仓库内不含 zip，主地址按预期 404，由兜底镜像接管）。
Future<void> _verifyZipEntry(
  ContentHttpClient client, {
  required String label,
  required String baseUrl,
  required String? zipUrl,
  required List<String> zipUrls,
  required int? fileSizeBytes,
  required Directory tmpDir,
  required String fileName,
  required bool download,
  required bool expectPrimaryReachable,
}) async {
  expect(zipUrl, isNotNull, reason: '$label zipUrl 缺失');
  expect(
    zipUrl!.startsWith('http://') || zipUrl.startsWith('https://'),
    isFalse,
    reason: '$label zipUrl 应为相对路径（v2 同构目录契约），实际: $zipUrl',
  );
  final primary = ContentHttpClient.resolveUrl(baseUrl, zipUrl);
  expect(
    primary.startsWith('http://') || primary.startsWith('https://'),
    isTrue,
    reason: '$label zipUrl 相对解析失败: $primary',
  );

  expect(zipUrls, isNotEmpty, reason: '$label zipUrls 不应为空');
  for (final u in zipUrls) {
    expect(
      u.startsWith('http://') || u.startsWith('https://'),
      isTrue,
      reason: '$label zipUrls 含非绝对地址: $u',
    );
  }

  // 主地址 + 全部兜底镜像逐个探测
  final primaryStatus = await _status(primary);
  final mirrorStatuses = <int>[];
  for (final u in zipUrls) {
    mirrorStatuses.add(await _status(u));
  }

  // 兜底镜像：首个（Gitee Release，国内主力）必须可达；
  // 其余镜像默认仅记录（GitHub Release 在国内网络可能被重置），
  // 开启 CHANNELS_FULL_MIRRORS=true 后严格要求全部可达。
  expect(
    mirrorStatuses.first,
    200,
    reason: '$label 首个兜底镜像不可达(${mirrorStatuses.first}): ${zipUrls.first}',
  );
  for (var i = 1; i < zipUrls.length; i++) {
    if (_fullMirrors) {
      expect(
        mirrorStatuses[i],
        200,
        reason: '$label 兜底镜像[$i] 不可达(${mirrorStatuses[i]}): ${zipUrls[i]}',
      );
    } else if (mirrorStatuses[i] != 200) {
      debugPrint(
        '  [warn] $label 兜底镜像[$i] 不可达(${mirrorStatuses[i]}): ${zipUrls[i]}',
      );
    }
  }
  if (expectPrimaryReachable) {
    expect(
      primaryStatus,
      200,
      reason: '$label 主地址不可达($primaryStatus)（R2 同构目录应命中）: $primary',
    );
  }

  // 下载走「首个可达候选」，等价于客户端 downloadFileWithMirrors 的真实回退顺序
  final hit = primaryStatus == 200 ? primary : zipUrls.first;
  debugPrint(
    '  [zip] $label primary=$primaryStatus mirrors=$mirrorStatuses hit=$hit',
  );
  if (download) {
    await _verifyZip(
      client,
      hit,
      expectBytes: fileSizeBytes,
      tmpDir: tmpDir,
      name: fileName,
    );
  }
}

void main() {
  final bases = _channelBases();

  for (final entry in bases.entries) {
    final channelId = entry.key;
    final base = entry.value;

    test(
      '三通道消费验证 [$channelId] $base',
      () async {
        if (!_enabled) {
          debugPrint('SKIP: 未设置 --dart-define=CHANNELS_VERIFY=true，跳过');
          return;
        }
        final client = ContentHttpClient();
        final tmpDir = await Directory.systemTemp.createTemp('jigsaw_chan_');

        try {
          // 1. manifest
          final manifestUrl = Uri.parse(
            base,
          ).resolve('manifest.json').toString();
          final rootJson = await _fetchJson(client, manifestUrl);
          final root = RootManifest.fromJson(
            rootJson,
          ).copyWith(baseUri: manifestUrl);
          expect(
            root.schemaVersion >= _minSchema &&
                root.schemaVersion <= _maxSchema,
            isTrue,
            reason: 'schemaVersion ${root.schemaVersion} 超出支持区间',
          );
          for (final u in [
            root.mainModule.url,
            root.dailyModule.url,
            root.eventsModule.url,
            root.collectionsModule.url,
          ]) {
            expect(u, isNotEmpty, reason: 'manifest 模块 url 为空');
          }
          debugPrint('[$channelId] manifest OK schema=${root.schemaVersion}');

          // 2. main：批次 → 关卡
          final mainIndexUrl = ContentHttpClient.resolveUrl(
            manifestUrl,
            root.mainModule.url,
          );
          final mainIndex = await _fetchJson(client, mainIndexUrl);
          expect(mainIndex['module'], 'main');
          var levelCount = 0;
          final batches = (mainIndex['items'] as List? ?? [])
              .cast<Map<String, dynamic>>();
          expect(batches, isNotEmpty, reason: 'main 无批次');
          for (final b in batches) {
            final batchUrl = ContentHttpClient.resolveUrl(
              mainIndexUrl,
              b['url'] as String,
            );
            final batchJson = await _fetchJson(client, batchUrl);
            final levels = (batchJson['items'] as List)
                .cast<Map<String, dynamic>>()
                .map(PuzzleLevelItem.fromJson)
                .toList();
            levelCount += levels.length;
            for (final lv in levels) {
              expect(lv.id, isNotEmpty, reason: '关卡 id 为空');
              expect(lv.tags, isNotEmpty, reason: '关卡 ${lv.id} 缺 tags');
            }
            // 图片抽查：首 / 中 / 尾
            for (final lv in [
              levels.first,
              levels[levels.length ~/ 2],
              levels.last,
            ]) {
              await _expectReachable(
                ContentHttpClient.resolveUrl(batchUrl, lv.url),
              );
            }
          }
          if (root.mainModule.totalCount > 0) {
            expect(
              levelCount,
              root.mainModule.totalCount,
              reason: 'main 关卡数与 manifest.totalCount 不符',
            );
          }
          debugPrint('[$channelId] main OK levels=$levelCount');

          // 3. daily
          final dailyUrl = ContentHttpClient.resolveUrl(
            manifestUrl,
            root.dailyModule.url,
          );
          final dailyJson = await _fetchJson(client, dailyUrl);
          final months = (dailyJson['items'] as List? ?? [])
              .cast<Map<String, dynamic>>();
          expect(months, isNotEmpty, reason: 'daily 无月份条目');
          for (var i = 0; i < months.length; i++) {
            final m = months[i];
            expect(
              RegExp(r'^\d{6}$').hasMatch(m['month'] as String),
              isTrue,
              reason: 'daily month 格式错: ${m['month']}',
            );
            await _verifyZipEntry(
              client,
              label: 'daily ${m['month']}',
              baseUrl: dailyUrl,
              zipUrl: m['zipUrl'] as String?,
              zipUrls: (m['zipUrls'] as List? ?? [])
                  .map((e) => e.toString())
                  .toList(),
              fileSizeBytes: m['fileSizeBytes'] as int?,
              tmpDir: tmpDir,
              fileName: 'daily_${m['month']}.zip',
              download: _fullZip || i == months.length - 1,
              expectPrimaryReachable: channelId == 'r2',
            );
          }
          debugPrint('[$channelId] daily OK months=${months.length}');

          // 4. events
          final eventsUrl = ContentHttpClient.resolveUrl(
            manifestUrl,
            root.eventsModule.url,
          );
          final eventsJson = await _fetchJson(client, eventsUrl);
          final events = (eventsJson['items'] as List? ?? [])
              .cast<Map<String, dynamic>>()
              .map(PuzzleEventItem.fromJson)
              .toList();
          expect(events, isNotEmpty, reason: 'events 为空');
          for (var i = 0; i < events.length; i++) {
            final e = events[i];
            expect(e.id, isNotEmpty);
            expect(e.coverUrl, isNotNull, reason: 'event ${e.id} 缺 coverUrl');
            await _expectReachable(
              ContentHttpClient.resolveUrl(eventsUrl, e.coverUrl!),
            );
            await _verifyZipEntry(
              client,
              label: 'event ${e.id}',
              baseUrl: eventsUrl,
              zipUrl: e.zipUrl,
              zipUrls: e.zipUrls,
              fileSizeBytes: e.fileSizeBytes,
              tmpDir: tmpDir,
              fileName: 'event_${e.id}.zip',
              download: _fullZip || i == 0,
              expectPrimaryReachable: channelId == 'r2',
            );
          }
          debugPrint('[$channelId] events OK count=${events.length}');

          // 5. collections
          final colUrl = ContentHttpClient.resolveUrl(
            manifestUrl,
            root.collectionsModule.url,
          );
          final colJson = await _fetchJson(client, colUrl);
          final cols = (colJson['items'] as List? ?? [])
              .cast<Map<String, dynamic>>()
              .map(PuzzleCollectionItem.fromJson)
              .toList();
          expect(cols, isNotEmpty, reason: 'collections 为空');
          for (var i = 0; i < cols.length; i++) {
            final c = cols[i];
            expect(c.id, isNotEmpty);
            expect(
              c.coverUrl,
              isNotNull,
              reason: 'collection ${c.id} 缺 coverUrl',
            );
            await _expectReachable(
              ContentHttpClient.resolveUrl(colUrl, c.coverUrl!),
            );
            await _verifyZipEntry(
              client,
              label: 'collection ${c.id}',
              baseUrl: colUrl,
              zipUrl: c.zipUrl,
              zipUrls: c.zipUrls,
              fileSizeBytes: c.fileSizeBytes,
              tmpDir: tmpDir,
              fileName: 'col_${c.id}.zip',
              download: _fullZip || i == 0,
              expectPrimaryReachable: channelId == 'r2',
            );
          }
          debugPrint('[$channelId] collections OK count=${cols.length}');

          debugPrint('✅ [$channelId] 三通道消费验证通过 base=$base');
        } finally {
          if (tmpDir.existsSync()) {
            tmpDir.deleteSync(recursive: true);
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );
  }
}

/// 测试输出统一走 print，便于 `flutter test` 直接观察三通道进度。
// ignore: avoid_print
void debugPrint(String message) => print(message);
