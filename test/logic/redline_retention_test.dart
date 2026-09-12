// P1-4：测试有意触发失败路径以验证容错逻辑，统一豁免
// ignore_for_file: avoid_catches_without_on_clauses
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/favorite_store.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/logic/cache/level_image_resolver.dart';
import 'package:jigsawpuzzle/logic/cache/local_image_locator.dart';
import 'package:jigsawpuzzle/logic/catalog_index.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/content_manager.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_collection_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/content/network/content_http_client.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/collections_content_pipeline.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/events_content_pipeline.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/main_content_pipeline.dart';
import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';
import 'package:jigsawpuzzle/logic/unified_puzzle_resolver.dart';
import 'package:path/path.dart' as p;

import '../test_helper.dart';

/// 红线回归：可控假网络客户端（不发起任何真实请求）。
class _FakeHttpClient extends ContentHttpClient {
  _FakeHttpClient();

  Map<String, dynamic> jsonByUrl = {};
  Map<String, List<int>> fileByUrl = {};
  List<int>? zipBytes;
  bool failDownload = false;

  @override
  Future<dynamic> fetchJson(String url, {Duration? timeout}) async {
    final v = jsonByUrl[url];
    if (v == null) throw HttpException('404 $url');
    return v;
  }

  @override
  Future<File> downloadFile(
    String url,
    String destinationPath, {
    Duration? timeout,
    void Function(int received, int total)? onProgress,
  }) async {
    if (failDownload) throw HttpException('offline $url');
    final bytes = fileByUrl[url];
    if (bytes == null) throw HttpException('404 $url');
    final f = File(destinationPath);
    if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  @override
  Future<File> downloadFileWithMirrors(
    List<String> urls,
    String destinationPath, {
    Duration? timeout,
    void Function(int received, int total)? onProgress,
  }) async {
    if (failDownload) throw HttpException('offline ${urls.firstOrNull}');
    final bytes = zipBytes;
    if (bytes == null) throw HttpException('404 ${urls.firstOrNull}');
    final f = File(destinationPath);
    if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }
}

List<int> _zipWithFiles(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('R1 retention: empty remote never deletes local data (P0-2)', () {
    late Directory tempDir;
    late _FakeHttpClient http;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('jigsaw_redline_');
      http = _FakeHttpClient();
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      'events: items [] keeps map entries, dirs and marks delisted',
      () async {
        final pipeline = EventsContentPipeline(
          cacheFilePath: p.join(tempDir.path, 'events_cache.json'),
          eventsStorageBaseDir: p.join(tempDir.path, 'events'),
          httpClient: http,
        );
        const remoteUrl = 'https://x/events.json';
        http.jsonByUrl[remoteUrl] = {
          'items': [
            {
              'id': 'e1',
              'title': 'E1',
              'status': 'active',
              'type': 'zip',
              'zipUrl': 'https://x/e1.zip',
            },
            {
              'id': 'e2',
              'title': 'E2',
              'status': 'active',
              'type': 'array',
              'levels': ['https://x/a.webp'],
            },
          ],
        };
        expect(await pipeline.syncWithRemote(remoteUrl: remoteUrl), isTrue);
        expect(pipeline.allEvents.length, equals(2));

        // 模拟已下载数据
        final dir = Directory(p.join(tempDir.path, 'events', 'e1'))
          ..createSync(recursive: true);
        File(p.join(dir.path, '01.webp')).writeAsBytesSync([1, 2, 3]);

        // 远端返回空列表
        http.jsonByUrl[remoteUrl] = {
          'items': <Map<String, dynamic>>[],
        };
        expect(await pipeline.syncWithRemote(remoteUrl: remoteUrl), isTrue);

        expect(pipeline.allEvents.length, equals(2));
        expect(
          pipeline.allEvents.every((e) => e.isDelisted),
          isTrue,
          reason: 'missing ids must be marked delisted, not removed',
        );
        expect(dir.existsSync(), isTrue);
        expect(File(p.join(dir.path, '01.webp')).existsSync(), isTrue);

        // 重新上架自动清除标记
        http.jsonByUrl[remoteUrl] = {
          'items': [
            {
              'id': 'e1',
              'title': 'E1',
              'status': 'active',
              'type': 'zip',
              'zipUrl': 'https://x/e1.zip',
            },
          ],
        };
        expect(await pipeline.syncWithRemote(remoteUrl: remoteUrl), isTrue);
        expect(
          pipeline.allEvents.firstWhere((e) => e.id == 'e1').isDelisted,
          isFalse,
        );
      },
    );

    test(
      'collections: items [] keeps map entries, dirs and marks delisted',
      () async {
        final pipeline = CollectionsContentPipeline(
          cacheFilePath: p.join(tempDir.path, 'collections_cache.json'),
          collectionsStorageBaseDir: p.join(tempDir.path, 'collections'),
          httpClient: http,
        );
        const remoteUrl = 'https://x/collections.json';
        http.jsonByUrl[remoteUrl] = {
          'items': [
            {
              'id': 'c1',
              'title': 'C1',
              'status': 'active',
              'type': 'zip',
              'zipUrl': 'https://x/c1.zip',
            },
          ],
        };
        expect(await pipeline.syncWithRemote(remoteUrl: remoteUrl), isTrue);

        final dir = Directory(p.join(tempDir.path, 'collections', 'c1'))
          ..createSync(recursive: true);
        File(p.join(dir.path, '01.jpg')).writeAsBytesSync([4, 5, 6]);

        http.jsonByUrl[remoteUrl] = {
          'items': <Map<String, dynamic>>[],
        };
        expect(await pipeline.syncWithRemote(remoteUrl: remoteUrl), isTrue);

        expect(pipeline.allCollections.length, equals(1));
        expect(pipeline.allCollections.single.isDelisted, isTrue);
        expect(File(p.join(dir.path, '01.jpg')).existsSync(), isTrue);
      },
    );
  });

  group('P1-7: empty pack is not marked downloaded', () {
    late Directory tempDir;
    late _FakeHttpClient http;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('jigsaw_empty_pack_');
      http = _FakeHttpClient();
      http.zipBytes = _zipWithFiles({
        'notes.txt': [104, 105],
      });
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      'events zip with no images returns false and stays undownloaded',
      () async {
        final pipeline = EventsContentPipeline(
          cacheFilePath: p.join(tempDir.path, 'events_cache.json'),
          eventsStorageBaseDir: p.join(tempDir.path, 'events'),
          httpClient: http,
        );
        const event = PuzzleEventItem(
          id: 'empty_pack',
          title: 'Empty',
          status: 'active',
          type: 'zip',
          zipUrl: 'https://x/empty.zip',
        );
        expect(await pipeline.ensureEventDownloaded(event), isFalse);
        expect(pipeline.isEventDownloaded(event), isFalse);
      },
    );

    test(
      'collections zip with no images returns false and stays undownloaded',
      () async {
        final pipeline = CollectionsContentPipeline(
          cacheFilePath: p.join(tempDir.path, 'collections_cache.json'),
          collectionsStorageBaseDir: p.join(tempDir.path, 'collections'),
          httpClient: http,
        );
        const collection = PuzzleCollectionItem(
          id: 'empty_pack',
          title: 'Empty',
          zipUrl: 'https://x/empty.zip',
        );
        expect(
          await pipeline.ensureCollectionDownloaded(collection),
          isFalse,
        );
      },
    );
  });

  group('P1-1: non-main levels never pollute main pipeline', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('jigsaw_p11_');
    });

    tearDown(() {
      AppContent.instance.setManagerForTest(null);
      LevelImageResolver.instance.resetForTest(
        httpClientOverride: ContentHttpClient(),
      );
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('ensureMainLevelDownloaded rejects non-main ids', () async {
      final pipeline = MainContentPipeline(
        cacheFilePath: p.join(tempDir.path, 'main_cache.json'),
        imagesStorageDir: p.join(tempDir.path, 'main'),
      );
      // 漏传 sourceModule（默认即 main）但 id 为 collection: 的关键用例
      const level = PuzzleLevelItem(
        id: 'collection:art:01',
        url: 'https://x/01.webp',
      );
      expect(
        pipeline.ensureLevelImageDownloaded(level),
        throwsArgumentError,
      );
      expect(pipeline.levels.where((l) => l.id == level.id), isEmpty);
    });

    test('resolveLevelLocalPath does not write into main pipeline', () async {
      final manager = ContentManager(
        bootstrapUrls: const [],
        appSupportDir: tempDir.path,
      );
      AppContent.instance.setManagerForTest(manager);
      final failing = _FakeHttpClient()..failDownload = true;
      LevelImageResolver.instance.resetForTest(
        networkLevelsDirOverride: p.join(tempDir.path, 'network'),
        httpClientOverride: failing,
      );
      const level = PuzzleLevelItem(
        id: 'collection:art:01',
        url: 'https://x/01.webp',
      );
      final resolved = await LevelImageResolver.instance.resolveLevelLocalPath(
        level,
      );
      expect(resolved, equals('https://x/01.webp'));
      expect(
        manager.mainPipeline.levels.where((l) => l.id == level.id),
        isEmpty,
      );
    });
  });

  group('P0-6: hash change keeps old image when refresh fails', () {
    late Directory tempDir;
    late _FakeHttpClient http;
    late MainContentPipeline pipeline;

    const indexUrl = 'https://x/main-index.json';
    const batch1Url = 'https://x/b1.json';
    const batch2Url = 'https://x/b2.json';
    const imageUrl = 'https://x/101.webp';

    Map<String, dynamic> batchDoc(String hash) => {
      'items': [
        {
          'id': 'main:101',
          'url': imageUrl,
          'hash': hash,
          'order': 101,
          'fileSizeBytes': 4,
        },
      ],
    };

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('jigsaw_p06_');
      http = _FakeHttpClient();
      pipeline = MainContentPipeline(
        cacheFilePath: p.join(tempDir.path, 'main_cache.json'),
        imagesStorageDir: p.join(tempDir.path, 'main'),
        httpClient: http,
      );
      http.jsonByUrl[indexUrl] = {
        'version': 1,
        'items': [
          {'batchId': 'b1', 'url': batch1Url},
        ],
      };
      http.jsonByUrl[batch1Url] = batchDoc('aaa');
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('failed refresh retains old file and retries next sync', () async {
      expect(
        await pipeline.syncWithRemote(
          remoteUrl: indexUrl,
          remoteVersion: 1,
        ),
        isTrue,
      );
      // 落盘旧图并经 ensure 确认可玩
      final target = File(p.join(tempDir.path, 'main', 'main_101.webp'));
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync([1, 2, 3, 4]);
      final ensured = await pipeline.ensureLevelImageDownloaded(
        pipeline.levels.singleWhere((l) => l.id == 'main:101'),
      );
      expect(ensured.isLocalFile, isTrue);

      // 远端 hash 变更 + 断网（下载失败）。新图哈希取自即将到来的真实字节，
      // 使恢复网络后的重试能通过 sha 校验。
      const newBytes = [5, 6, 7, 8];
      final newHash = sha256.convert(newBytes).toString();
      http.failDownload = true;
      http.jsonByUrl[indexUrl] = {
        'version': 2,
        'items': [
          {'batchId': 'b2', 'url': batch2Url},
        ],
      };
      http.jsonByUrl[batch2Url] = batchDoc(newHash);
      await pipeline.syncWithRemote(remoteUrl: indexUrl, remoteVersion: 2);

      expect(target.existsSync(), isTrue);
      expect(target.readAsBytesSync(), equals([1, 2, 3, 4]));
      final entry = pipeline.levels.singleWhere((l) => l.id == 'main:101');
      expect(entry.isLocalFile, isTrue);
      expect(entry.localPath, isNotNull);
      expect(File(entry.localPath!).existsSync(), isTrue);
      // 外部评审①：失败不得推进 hash，否则下次 sync 因两边一致而永不重试
      expect(entry.hash, equals('aaa'));

      // 恢复网络后同版本 sync 必须重试（待重试集合阻止版本短路）
      http.failDownload = false;
      http.fileByUrl[imageUrl] = newBytes;
      await pipeline.syncWithRemote(remoteUrl: indexUrl, remoteVersion: 2);
      expect(target.readAsBytesSync(), equals(newBytes));
      expect(
        pipeline.levels.singleWhere((l) => l.id == 'main:101').hash,
        equals(newHash),
      );
      // 重试成功后待重试清空，同版本 sync 恢复短路（不再空转）
      expect(
        await pipeline.syncWithRemote(remoteUrl: indexUrl, remoteVersion: 2),
        isFalse,
      );
    });
  });

  group('P0-7: LocalImageLocator is read-only', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('jigsaw_locator_');
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('hits by stem, misses null, no writes', () {
      final dir = Directory(p.join(tempDir.path, 'c1'))..createSync();
      File(p.join(dir.path, '01.webp')).writeAsBytesSync([9, 9]);
      File(p.join(dir.path, 'notes.txt')).writeAsStringSync('x');
      final before = dir.listSync().map((e) => e.path).toSet();

      expect(
        LocalImageLocator.locateInDirectory(dir.path, '01'),
        endsWith('01.webp'),
      );
      expect(LocalImageLocator.locateInDirectory(dir.path, 'missing'), isNull);

      final after = dir.listSync().map((e) => e.path).toSet();
      expect(after, equals(before));
    });
  });

  group('R2 + P0-2 index + P1-4 + P2-10 (needs app storage)', () {
    late StorageManager sm;
    late Directory tempDir;

    setUp(() async {
      sm = await initTestAppStorage();
      await GameRepository.instance.init();
      await ProgressStore.instance.init();
      await FavoriteStore.instance.init();
      tempDir = Directory.systemTemp.createTempSync('jigsaw_index_');
      addTearDown(() async {
        AppContent.instance.setManagerForTest(null);
        try {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        } catch (_) {}
        await tearDownTestStorage(sm);
      });
    });

    test('orphan card keeps progress and snapshot flags (playable basis)', () {
      const index = UnifiedCatalogIndex({});
      const resolver = UnifiedPuzzleResolver(index);
      final card = resolver.resolve(
        canonicalId: 'event:ghost:01',
        progress: const LevelProgress(
          canonicalId: 'event:ghost:01',
          progressPercent: 50,
          hasSnapshot: true,
          activeDifficultyKey: '6x6',
        ),
      );
      expect(card.isOrphan, isTrue);
      expect(card.progressPercent, equals(50));
      expect(card.hasActiveSnapshot, isTrue);
    });

    test('delisted but downloaded event stays indexed', () async {
      final http = _FakeHttpClient();
      final manager = ContentManager(
        bootstrapUrls: const [],
        appSupportDir: tempDir.path,
      );
      AppContent.instance.setManagerForTest(manager);

      final standalone = EventsContentPipeline(
        cacheFilePath: p.join(tempDir.path, 'events_cache.json'),
        eventsStorageBaseDir: p.join(tempDir.path, 'events'),
        httpClient: http,
      );
      const remoteUrl = 'https://x/events.json';
      http.jsonByUrl[remoteUrl] = {
        'items': [
          {
            'id': 'e1',
            'title': 'E1',
            'status': 'active',
            'type': 'zip',
            'zipUrl': 'https://x/e1.zip',
          },
        ],
      };
      expect(await standalone.syncWithRemote(remoteUrl: remoteUrl), isTrue);
      final dir = Directory(p.join(tempDir.path, 'events', 'e1'))
        ..createSync(recursive: true);
      File(p.join(dir.path, '01.webp')).writeAsBytesSync([7, 7, 7]);
      // 第二轮同步确认已下载标记
      expect(await standalone.syncWithRemote(remoteUrl: remoteUrl), isTrue);
      expect(standalone.allEvents.single.isLocalDownloaded, isTrue);
      // 下架后仍满足「可见 ∪ 已下载」中的已下载分支
      http.jsonByUrl[remoteUrl] = {
        'items': <Map<String, dynamic>>[],
      };
      expect(await standalone.syncWithRemote(remoteUrl: remoteUrl), isTrue);
      final delisted = standalone.allEvents.single;
      expect(delisted.isDelisted, isTrue);
      final visibleOrDownloaded =
          (!delisted.isDisabled && !delisted.isDelisted) ||
          standalone.isEventDownloaded(delisted);
      expect(visibleOrDownloaded, isTrue);
    });

    test('PuzzleBoardState defaults fall back instead of orphan keys', () {
      PieceState piece(int id) => PieceState(
        id: id,
        r: id ~/ 2,
        c: id % 2,
        nx: (id % 2) / 2,
        ny: (id ~/ 2) / 2,
        clusterId: id,
      );
      final state = PuzzleBoardState.fromJson({
        'rows': 2,
        'cols': 2,
        'seed': 1,
        'pieces': [
          piece(0),
          piece(1),
          piece(2),
          piece(3),
        ].map((e) => e.toJson()).toList(),
        'levelId': 'main:101',
      });
      // 未注入归属时回落到 levelId，而非 default_level 孤儿键
      expect(state.effectiveCanonicalId, equals('main:101'));
      // 旧快照兼容链不变
      final legacy = PuzzleBoardState.fromJson({
        'rows': 2,
        'cols': 2,
        'seed': 1,
        'canonicalId': 'default_level',
        'levelId': 'default_level',
        'pieces': [
          piece(0),
          piece(1),
          piece(2),
          piece(3),
        ].map((e) => e.toJson()).toList(),
      });
      expect(legacy.effectiveCanonicalId, equals('default_level'));
    });

    test('concurrent UnifiedCatalogIndex.current() shares one build', () async {
      final manager = ContentManager(
        bootstrapUrls: const [],
        appSupportDir: tempDir.path,
      );
      AppContent.instance.setManagerForTest(manager);
      UnifiedCatalogIndex.invalidate();
      final f1 = UnifiedCatalogIndex.current();
      final f2 = UnifiedCatalogIndex.current();
      final results = await Future.wait([f1, f2]);
      expect(identical(results[0], results[1]), isTrue);
    });
  });
}
