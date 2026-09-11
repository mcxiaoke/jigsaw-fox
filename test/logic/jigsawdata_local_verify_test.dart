import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_collection_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/models/root_manifest.dart';
import 'package:path/path.dart' as p;

/// jigsaw-data 本地发布产物离线契约测试（0 网络，直接测试本地目录）
///
/// 目标：在向任何远端（R2 _stage / Release 附件 / Git）推送前，
/// 用 App 真实的数据模型反序列化本地 release/ 目录下的所有 JSON 数据，
/// 验证客户端解析 0 异常、关卡图片与封面本地真实存在、zipUrl 契约合规。
///
/// 用法：
///   flutter test test/logic/jigsawdata_local_verify_test.dart \
///     --dart-define=LOCAL_DATA_DIR="F:/Pictures/JigsawGame/jigsaw-data/release"
const String _localDataDirEnv = String.fromEnvironment('LOCAL_DATA_DIR');

const int _minSchema = 3;
const int _maxSchema = 4;

void main() {
  test('jigsaw-data 本地发布产物客户端模型解析全量契约测试', () {
    final dirPath = _localDataDirEnv.isNotEmpty
        ? _localDataDirEnv
        : 'F:/Pictures/JigsawGame/jigsaw-data/release';

    final releaseDir = Directory(dirPath);
    if (!releaseDir.existsSync()) {
      debugPrint(
        'SKIP: 本地发布产物目录不存在: $dirPath（可通过 --dart-define=LOCAL_DATA_DIR 指定）',
      );
      return;
    }

    debugPrint('[LocalContractTest] 正在核验本地发布目录: $dirPath');

    // 1. Root Manifest
    final manifestFile = File(p.join(releaseDir.path, 'manifest.json'));
    expect(manifestFile.existsSync(), isTrue, reason: '缺少 manifest.json');

    final manifestJson =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final root = RootManifest.fromJson(manifestJson);

    expect(
      root.schemaVersion >= _minSchema && root.schemaVersion <= _maxSchema,
      isTrue,
      reason:
          'schemaVersion ${root.schemaVersion} 超出支持区间 [$_minSchema..$_maxSchema]',
    );
    expect(root.mainModule.url, isNotEmpty);
    expect(root.dailyModule.url, isNotEmpty);
    expect(root.eventsModule.url, isNotEmpty);
    expect(root.collectionsModule.url, isNotEmpty);
    debugPrint(
      '  [1/5] RootManifest 解析通过 (schemaVersion=${root.schemaVersion})',
    );

    // 2. Main 模块 (批次 -> 关卡反序列化与图片存在性)
    final mainIndexFile = File(p.join(releaseDir.path, root.mainModule.url));
    expect(mainIndexFile.existsSync(), isTrue, reason: '缺少 main/index.json');

    final mainIndexJson =
        jsonDecode(mainIndexFile.readAsStringSync()) as Map<String, dynamic>;
    expect(mainIndexJson['module'], 'main');

    final batches = (mainIndexJson['items'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    expect(batches, isNotEmpty, reason: 'main 无任何批次');

    var totalLevels = 0;
    for (final b in batches) {
      final batchRelUrl = b['url'] as String;
      final batchFile = File(p.join(mainIndexFile.parent.path, batchRelUrl));
      expect(batchFile.existsSync(), isTrue, reason: '批次文件不存在: $batchRelUrl');

      final batchJson =
          jsonDecode(batchFile.readAsStringSync()) as Map<String, dynamic>;
      final levelsRaw = (batchJson['items'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      expect(levelsRaw, isNotEmpty, reason: '批次 $batchRelUrl 内无关卡');

      final levels = levelsRaw.map(PuzzleLevelItem.fromJson).toList();
      totalLevels += levels.length;

      for (final lv in levels) {
        expect(lv.id, isNotEmpty, reason: '关卡 id 为空');
        expect(lv.tags, isNotEmpty, reason: '关卡 ${lv.id} 缺少 tags');
        expect(lv.url, isNotEmpty, reason: '关卡 ${lv.id} 缺少 url');

        // 图片文件本地存在性校验
        final imgFile = File(
          p.normalize(p.join(batchFile.parent.path, lv.url)),
        );
        expect(
          imgFile.existsSync(),
          isTrue,
          reason: '关卡 ${lv.id} 本地图片不存在: ${imgFile.path}',
        );
        expect(
          imgFile.lengthSync(),
          greaterThan(0),
          reason: '关卡 ${lv.id} 本地图片为空文件: ${imgFile.path}',
        );
      }
    }
    if (root.mainModule.totalCount > 0) {
      expect(
        totalLevels,
        root.mainModule.totalCount,
        reason: 'main 总关卡数与 manifest 声明不一致',
      );
    }
    debugPrint('  [2/5] Main 模块解析通过 ($totalLevels 关卡已验证模型与本地图片)');

    // 3. Daily 模块 (月份条目与 zip 契约)
    final dailyIndexFile = File(p.join(releaseDir.path, root.dailyModule.url));
    expect(dailyIndexFile.existsSync(), isTrue, reason: '缺少 daily/index.json');

    final dailyIndexJson =
        jsonDecode(dailyIndexFile.readAsStringSync()) as Map<String, dynamic>;
    final dailyItems = (dailyIndexJson['items'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    expect(dailyItems, isNotEmpty, reason: 'daily 模块无月份条目');

    for (final it in dailyItems) {
      final month = it['month'] as String?;
      expect(month, isNotNull, reason: 'daily 项缺少 month');
      final zipUrl = it['zipUrl'] as String?;
      expect(zipUrl, isNotNull, reason: 'daily $month 缺少 zipUrl');
      expect(
        zipUrl!.startsWith('http://') || zipUrl.startsWith('https://'),
        isFalse,
        reason: 'daily $month zipUrl 应为相对路径，实际: $zipUrl',
      );

      final zipFile = File(p.join(dailyIndexFile.parent.path, zipUrl));
      expect(
        zipFile.existsSync(),
        isTrue,
        reason: 'daily $month 本地 zip 不存在: ${zipFile.path}',
      );
      expect(
        zipFile.lengthSync(),
        greaterThan(0),
        reason: 'daily $month zip 为空文件',
      );

      final zipUrls = it['zipUrls'] as List?;
      expect(zipUrls, isNotNull, reason: 'daily $month 缺少 zipUrls 兜底镜像');
      expect(zipUrls!.isNotEmpty, isTrue, reason: 'daily $month zipUrls 列表为空');
      for (final u in zipUrls) {
        expect(
          (u as String).startsWith('http://') || u.startsWith('https://'),
          isTrue,
          reason: 'daily $month zipUrls 需为绝对镜像地址: $u',
        );
      }
    }
    debugPrint('  [3/5] Daily 模块解析通过 (${dailyItems.length} 个月份 zip 契约合规)');

    // 4. Events 模块 (PuzzleEventItem 反序列化与 cover 存在性)
    final eventsIndexFile = File(
      p.join(releaseDir.path, root.eventsModule.url),
    );
    expect(
      eventsIndexFile.existsSync(),
      isTrue,
      reason: '缺少 events/index.json',
    );

    final eventsIndexJson =
        jsonDecode(eventsIndexFile.readAsStringSync()) as Map<String, dynamic>;
    final eventsRaw = (eventsIndexJson['items'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    expect(eventsRaw, isNotEmpty, reason: 'events 模块无活动条目');

    final events = eventsRaw.map(PuzzleEventItem.fromJson).toList();
    for (final e in events) {
      expect(e.id, isNotEmpty, reason: 'event id 为空');
      expect(e.title, isNotEmpty, reason: 'event ${e.id} title 为空');
      final coverRel = e.coverUrl;
      final coverFile = File(p.join(eventsIndexFile.parent.path, coverRel));
      expect(
        coverFile.existsSync(),
        isTrue,
        reason: 'event ${e.id} 本地封面不存在: ${coverFile.path}',
      );
      expect(
        coverFile.lengthSync(),
        greaterThan(0),
        reason: 'event ${e.id} 封面为空文件',
      );
    }
    debugPrint('  [4/5] Events 模块解析通过 (${events.length} 个活动已验证模型与本地封面)');

    // 5. Collections 模块 (PuzzleCollectionItem 反序列化与 cover 存在性)
    final collectionsIndexFile = File(
      p.join(releaseDir.path, root.collectionsModule.url),
    );
    expect(
      collectionsIndexFile.existsSync(),
      isTrue,
      reason: '缺少 collections/index.json',
    );

    final collectionsIndexJson =
        jsonDecode(collectionsIndexFile.readAsStringSync())
            as Map<String, dynamic>;
    final collectionsRaw = (collectionsIndexJson['items'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    expect(collectionsRaw, isNotEmpty, reason: 'collections 模块无图集条目');

    final collections = collectionsRaw
        .map(PuzzleCollectionItem.fromJson)
        .toList();
    for (final c in collections) {
      expect(c.id, isNotEmpty, reason: 'collection id 为空');
      expect(c.title, isNotEmpty, reason: 'collection ${c.id} title 为空');
      final coverRel = c.coverUrl;
      final coverFile = File(
        p.join(collectionsIndexFile.parent.path, coverRel),
      );
      expect(
        coverFile.existsSync(),
        isTrue,
        reason: 'collection ${c.id} 本地封面不存在: ${coverFile.path}',
      );
      expect(
        coverFile.lengthSync(),
        greaterThan(0),
        reason: 'collection ${c.id} 封面为空文件',
      );
    }
    debugPrint(
      '  [5/5] Collections 模块解析通过 (${collections.length} 个图集已验证模型与本地封面)',
    );

    debugPrint('🎉 [LocalContractTest] 本地发布产物全部客户端模型契约校验通过！');
  });
}
