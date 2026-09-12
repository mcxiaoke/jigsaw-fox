// P1-4：测试有意触发失败路径以验证容错逻辑，统一豁免
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jigsawpuzzle/logic/content/models/puzzle_collection_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/models/root_manifest.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';

/// jigsaw-data 远端全链路验证（部署后手动执行）
///
/// 用法：
///   flutter test test/logic/jigsawdata_remote_verify_test.dart \
///     --dart-define=JIGSAWDATA_MANIFEST=https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/manifest.json
///
/// 未提供 JIGSAWDATA_MANIFEST 时测试自动跳过（不参与常规 CI）。
/// 使用与 App 相同的网络客户端(ContentHttpClient/Dio)与数据模型
/// （RootManifest/PuzzleLevelItem/PuzzleEventItem/PuzzleCollectionItem）
/// 对远端真实数据做全链路解析断言。
const String _manifestEnv = String.fromEnvironment('JIGSAWDATA_MANIFEST');

const Set<String> _mainTags = {
  'Landscapes',
  'Nature',
  'Flowers',
  'Animals',
  'Pets',
  'Cities',
  'Structures',
  'Vehicles',
  'People',
  'Objects',
  'Food',
  'Art',
  'Fantasy',
  'Holidays',
  'Colors',
  'Composition',
  'Others',
};

Future<void> _expectHttpReachable(String url) async {
  final client = HttpClient(); // 遵循本机系统代理（127.0.0.1:7890 一类）
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 200, reason: 'URL 不可达: $url');
  } finally {
    client.close();
  }
}

/// 模拟 ManifestRouter 的多 URL 容灾：对同一 URL 至多重试 5 次。
/// flutter test 环境下本地系统代理偶发抖动造成瞬时失败，重试可显著提高通过率。
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

void main() {
  test(
    'jigsaw-data 远端全链路: manifest → main/daily/events/collections 解析',
    () async {
      final manifestUrl = _manifestEnv;
      if (manifestUrl.isEmpty) {
        debugPrint(
          'SKIP: 未提供 --dart-define=JIGSAWDATA_MANIFEST，跳过远端验证',
        );
        return;
      }
      // 网络遵循本机系统代理（raw/jsDelivr/proxy 各通道由外部巡检脚本
      // validate_remote.py 单独验证，此处聚焦 App 数据模型解析契约）。
      final client = ContentHttpClient();

      // 1. Root Manifest
      final rootJson =
          await _fetchWithRetry(client, manifestUrl) as Map<String, dynamic>;
      final root = RootManifest.fromJson(
        rootJson,
      ).copyWith(baseUri: manifestUrl);
      expect(root.schemaVersion, 4, reason: 'schemaVersion 应为 4');
      expect(root.mainModule.url, 'main/index.json');
      expect(root.dailyModule.url, 'daily/index.json');
      expect(root.eventsModule.url, 'events/index.json');
      expect(root.collectionsModule.url, 'collections/index.json');
      final mainIndexBase = ContentHttpClient.resolveUrl(
        manifestUrl,
        root.mainModule.url,
      );
      final dailyIndexBase = ContentHttpClient.resolveUrl(
        manifestUrl,
        root.dailyModule.url,
      );
      final eventsIndexBase = ContentHttpClient.resolveUrl(
        manifestUrl,
        root.eventsModule.url,
      );
      final collectionsIndexBase = ContentHttpClient.resolveUrl(
        manifestUrl,
        root.collectionsModule.url,
      );
      debugPrint(
        'manifest OK schemaVersion=${root.schemaVersion} '
        'mainVersion=${root.mainModule.version}',
      );

      // 2. Main 主线（批次 → 关卡模型）
      final mainIndex =
          await _fetchWithRetry(client, mainIndexBase) as Map<String, dynamic>;
      expect(mainIndex['module'], 'main');
      expect(mainIndex['totalCount'], greaterThanOrEqualTo(30));
      int levelCount = 0;
      for (final b in (mainIndex['items'] as List)) {
        final batch = b as Map<String, dynamic>;
        final batchUrl = ContentHttpClient.resolveUrl(
          mainIndexBase,
          batch['url'] as String,
        );
        final batchJson =
            await _fetchWithRetry(client, batchUrl) as Map<String, dynamic>;
        final levels = (batchJson['items'] as List)
            .cast<Map<String, dynamic>>()
            .map(PuzzleLevelItem.fromJson)
            .toList();
        levelCount += levels.length;
        for (final lv in levels) {
          expect(lv.id, startsWith('main:'), reason: '关卡 id 前缀 main:');
          expect(lv.tags, isNotEmpty, reason: '关卡 ${lv.id} 需带 tags');
          for (final t in lv.tags) {
            expect(
              _mainTags,
              contains(t),
              reason: '关卡 ${lv.id} tag 超出预定义集合: $t',
            );
          }
          expect(
            lv.url,
            startsWith('../images/'),
            reason: '关卡 ${lv.id} url 应为 ../images/ 形态',
          );
        }
        // 抽查图片可达性：首/中/尾 各一张
        final probe = [
          levels.first,
          levels[levels.length ~/ 2],
          levels.last,
        ];
        for (final lv in probe) {
          final imgUrl = ContentHttpClient.resolveUrl(batchUrl, lv.url);
          await _expectHttpReachable(imgUrl);
        }
        debugPrint(
          'main batch ${batch['batchId']} OK '
          'levels=${levels.length} (${levels.first.id}..${levels.last.id})',
        );
      }
      expect(levelCount, 30, reason: 'main 总关卡数应为 30');

      // 3. Daily（月份条目 + 真实下载解压最新月）
      final dailyJson =
          await _fetchWithRetry(client, dailyIndexBase) as Map<String, dynamic>;
      final months = (dailyJson['items'] as List).cast<Map<String, dynamic>>();
      expect(months.length, 3, reason: 'daily 月份数应为 3');
      for (final m in months) {
        expect(RegExp(r'^\d{6}$').hasMatch(m['month'] as String), isTrue);
        final zipUrl = m['zipUrl'] as String;
        expect(
          zipUrl,
          startsWith('https://github.com/'),
          reason: 'daily ${m['month']} zipUrl 应为 Release 绝对 URL',
        );
      }
      final latest = months.first;
      final zipUrl = latest['zipUrl'] as String;
      final tmpDir = await Directory.systemTemp.createTemp('jigsawdata_dl_');
      // 直连 GitHub release 在国内常被阻断（302 → objects.githubusercontent.com），
      // 失败时依次尝试 gh 代理前缀通道，模拟 App 配置代理后的下载行为。
      const proxyHosts = ['https://ghfast.top', 'https://gh-proxy.com'];
      File? zipFile;
      String? channel;
      for (final candidate in [
        zipUrl,
        for (final h in proxyHosts) '$h/$zipUrl',
      ]) {
        try {
          zipFile = await client.downloadFile(
            candidate,
            '${tmpDir.path}/${latest['month']}.zip',
          );
          channel = candidate == zipUrl ? 'direct' : candidate;
          break;
        } catch (e) {
          debugPrint(
            'zip 下载失败(${candidate == zipUrl ? 'direct' : candidate}): $e',
          );
        }
      }
      expect(zipFile, isNotNull, reason: '直连与代理通道均无法下载 zip（release 资产不可达）');
      expect(await zipFile!.length(), greaterThan(0));
      final bytes = await zipFile.readAsBytes();
      expect(
        bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B,
        isTrue,
        reason: '下载内容应为合法 zip (PK magic)',
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      final entries = archive.files
          .where((f) => !f.isFile == false && f.isFile)
          .toList();
      final totalCount = latest['totalCount'] as int;
      expect(entries.length, totalCount, reason: 'zip 条目数应与 totalCount 一致');
      final names = entries.map((f) => f.name).toList()..sort();
      final expectNames = [
        for (var d = 1; d <= totalCount; d++)
          '${latest['month']}${d.toString().padLeft(2, '0')}.webp',
      ];
      expect(names, expectNames, reason: 'daily zip 内部命名应为日期连续');
      debugPrint(
        'daily OK months=${months.length} '
        'zip=${latest['month']}.zip entries=${entries.length} '
        'channel=$channel',
      );
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}

      // 4. Events
      final eventsJson =
          await _fetchWithRetry(client, eventsIndexBase)
              as Map<String, dynamic>;
      final events = (eventsJson['items'] as List)
          .cast<Map<String, dynamic>>()
          .map(PuzzleEventItem.fromJson)
          .toList();
      expect(events.length, 3, reason: 'events 应 3 个');
      for (final e in events) {
        expect(e.zipUrl, startsWith('https://github.com/'));
        expect(e.coverUrl, isNotEmpty);
        expect(e.totalCount, greaterThanOrEqualTo(10));
      }
      await _expectHttpReachable(
        ContentHttpClient.resolveUrl(eventsIndexBase, events.first.coverUrl!),
      );
      debugPrint('events OK count=${events.length}');

      // 5. Collections
      final colJson =
          await _fetchWithRetry(client, collectionsIndexBase)
              as Map<String, dynamic>;
      final cols = (colJson['items'] as List)
          .cast<Map<String, dynamic>>()
          .map(PuzzleCollectionItem.fromJson)
          .toList();
      expect(cols.length, 5, reason: 'collections 应 5 个');
      final mainTagsLower = _mainTags.map((t) => t.toLowerCase()).toSet();
      for (final c in cols) {
        expect(c.zipUrl, startsWith('https://github.com/'));
        expect(
          mainTagsLower,
          contains(c.collectionType),
          reason: 'collection ${c.id} category 超集',
        );
        expect(c.totalCount, greaterThanOrEqualTo(10));
        expect(c.unlockCoins, greaterThanOrEqualTo(0));
      }
      await _expectHttpReachable(
        ContentHttpClient.resolveUrl(
          collectionsIndexBase,
          cols.first.coverUrl!,
        ),
      );
      debugPrint('collections OK count=${cols.length}');
      debugPrint('✅ jigsaw-data 远端全链路验证通过 (manifest=$manifestUrl)');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

void debugPrint(String message) {
  // ignore: avoid_print
  print(message);
}
