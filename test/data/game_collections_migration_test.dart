import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/favorite_store.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/models/custom_puzzle_item.dart';
import 'package:jigsawpuzzle/data/models/downloaded_image_item.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/logic/download_manager.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';

import '../test_helper.dart';

/// Phase 2（game-collections-v1）DoD 用例（设计 §10.3 / §11）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageManager sm;
  late Directory testRoot;

  setUpAll(() async {
    testRoot = await Directory.systemTemp.createTemp('jigsaw_col_test_');
    // mock path_provider：DownloadManager 的 download_cache 目录定位
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return testRoot.path;
        });
  });

  tearDownAll(() async {
    try {
      if (await testRoot.exists()) await testRoot.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    sm = await initTestAppStorage();
  });

  tearDown(() async {
    await tearDownTestStorage(sm);
  });

  group('收藏 favorite:{cid}（§5.3 / §3.3）', () {
    String entryJson({
      required String canonicalId,
      required DateTime favoritedAt,
      required String title,
    }) => jsonEncode({
      'canonicalId': canonicalId,
      'favoritedAt': favoritedAt.toIso8601String(),
      'titleSnapshot': title,
      'sourceLabelSnapshot': '主线',
      'isLocalFileSnapshot': false,
      'aspectRatioLabel': 'square1x1',
      'sortOrder': 0,
    });

    test('拆条落盘，重启读回且按 favoritedAt 倒序', () async {
      final store = FavoriteStore.instance;
      await store.init();

      final tOld = DateTime.now().subtract(const Duration(minutes: 2));
      final tNew = DateTime.now().subtract(const Duration(minutes: 1));
      await sm.collections.put(
        'favorite:main:001',
        entryJson(canonicalId: 'main:001', favoritedAt: tOld, title: 'A'),
      );
      await sm.collections.put(
        'favorite:ugc:x1',
        entryJson(canonicalId: 'ugc:x1', favoritedAt: tNew, title: 'B'),
      );

      // 模拟重启
      await sm.closeAll();
      await sm.openAll();
      await store.reset();
      await store.init();

      expect(store.isFavorite('main:001'), isTrue);
      expect(store.isFavorite('ugc:x1'), isTrue);
      final sorted = await store.favoritesSortedByTime();
      expect(sorted.first.canonicalId, 'ugc:x1'); // 较新者在前（降序）
      expect(sorted.last.canonicalId, 'main:001');

      // box 键为 favorite: 前缀单条
      final keys = sm.collections.keys.cast<String>().toList()..sort();
      expect(keys, containsAll(['favorite:main:001', 'favorite:ugc:x1']));
    });

    test('取消收藏删除对应 box 键', () async {
      final store = FavoriteStore.instance;
      await store.init();
      await store.toggleFavorite('main:009');
      expect(sm.collections.get('favorite:main:009'), isNotNull);

      await store.toggleFavorite('main:009'); // 再 toggle = 取消
      expect(store.isFavorite('main:009'), isFalse);
      expect(sm.collections.get('favorite:main:009'), isNull);
    });

    test('pruneOrphans 先收集后批量删，无漏删', () async {
      final store = FavoriteStore.instance;
      await store.init();
      await store.toggleFavorite('main:001');
      await store.toggleFavorite('main:002');
      await store.pruneOrphans({'main:001'});

      expect(store.isFavorite('main:001'), isTrue);
      expect(store.isFavorite('main:002'), isFalse);
      expect(sm.collections.get('favorite:main:002'), isNull);
    });
  });

  group('素材库 material:{id}（§5.4）', () {
    late Directory cacheDir;

    setUp(() async {
      cacheDir = await DownloadManager.downloadCacheDir();
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    });

    Map<String, dynamic> makeItemJson(String id, String localPath) =>
        DownloadedImageItem(
          id: id,
          sourceUrl: 'https://example.com/$id.jpg',
          localPath: localPath,
          sourcePlatform: '测试',
          width: 800,
          height: 600,
          downloadedAt: DateTime.now(),
          fileSizeBytes: 32,
        ).toJson();

    test('init 前缀读入 + downloadedAt 降序排序', () async {
      final f1 = File('${cacheDir.path}/img_t1.jpg');
      final f2 = File('${cacheDir.path}/img_t2.jpg');
      await f1.writeAsBytes(List.generate(32, (i) => i));
      await f2.writeAsBytes(List.generate(32, (i) => i));

      final old = DateTime.now().subtract(const Duration(hours: 2));
      final recent = DateTime.now();
      await sm.collections.put(
        'material:t1',
        jsonEncode({
          ...makeItemJson('t1', f1.path),
          'downloadedAt': old.toIso8601String(),
        }),
      );
      await sm.collections.put(
        'material:t2',
        jsonEncode({
          ...makeItemJson('t2', f2.path),
          'downloadedAt': recent.toIso8601String(),
        }),
      );

      await DownloadManager.instance.init();
      final items = DownloadManager.instance.items;
      expect(items, hasLength(2));
      expect(items.first.id, 't2'); // downloadedAt 降序：最新在前
      expect(items.last.id, 't1');
    });

    test('失效过滤：localPath 不存在的项剔除且 box 键同步删除（先收集后批量删）', () async {
      final f1 = File('${cacheDir.path}/img_ok.jpg');
      await f1.writeAsBytes(List.generate(32, (i) => i));
      await sm.collections.put(
        'material:ok',
        jsonEncode(makeItemJson('ok', f1.path)),
      );
      await sm.collections.put(
        'material:ghost',
        jsonEncode(makeItemJson('ghost', '${cacheDir.path}/img_missing.jpg')),
      );

      await DownloadManager.instance.init();
      final items = DownloadManager.instance.items;
      expect(items.map((e) => e.id), ['ok']);
      // 幽灵索引不会永久驻留 box
      expect(sm.collections.get('material:ghost'), isNull);
    });
  });

  group('自制拼图 custom:{id}（§4.4 / §5.2 / §7.3）', () {
    test('首次启动植入 3 个样例并置 presetsInitialized=true', () async {
      await GameRepository.instance.init();
      expect(GameRepository.instance.customPuzzles, hasLength(3));
      expect(sm.state.get('custom:presetsInitialized'), isTrue);
      // 元数据以 custom:{id} 逐条落盘
      expect(
        getJson(sm.collections, 'custom:sample_01')?['title'],
        '巴黎埃菲尔铁塔晨曦',
      );
      final keys = sm.collections.keys
          .cast<String>()
          .where((k) => k.startsWith('custom:'))
          .length;
      expect(keys, 3);
    });

    test('删光后重启不重生成（标志已置 true）', () async {
      await GameRepository.instance.init();
      await GameRepository.instance.deleteCustomPuzzle('sample_01');
      await GameRepository.instance.deleteCustomPuzzle('sample_02');
      await GameRepository.instance.deleteCustomPuzzle('sample_03');
      expect(GameRepository.instance.customPuzzles, isEmpty);

      // 模拟重启
      await GameRepository.instance.init();
      expect(GameRepository.instance.customPuzzles, isEmpty);
      expect(sm.state.get('custom:presetsInitialized'), isTrue);
    });

    test('标志为 true 时即使 box 为空也不植入', () async {
      await sm.state.put('custom:presetsInitialized', true);
      await GameRepository.instance.init();
      expect(GameRepository.instance.customPuzzles, isEmpty);
    });

    test('ugc:{id} 进度水合：重启后 isCompleted/progressPercent 回填', () async {
      await GameRepository.instance.init();
      await ProgressStore.instance.updateProgress(
        canonicalId: 'ugc:sample_01',
        isCompleted: true,
        progressPercent: 100,
        bestTimeSeconds: 42,
        completedPieceCount: 16,
      );

      // 模拟重启
      await ProgressStore.instance.reloadForTest();
      await GameRepository.instance.init();
      final s1 = GameRepository.instance.customPuzzles.firstWhere(
        (p) => p.id == 'sample_01',
      );
      expect(s1.isCompleted, isTrue);
      expect(s1.progressPercent, 100);
      expect(s1.bestTimeSeconds, 42);
      expect(s1.completedPieceCounts, contains(16));
    });

    test('deleteCustomPuzzle 级联删除 ugc:{id} 进度', () async {
      await GameRepository.instance.init();
      await ProgressStore.instance.updateProgress(
        canonicalId: 'ugc:sample_02',
        isCompleted: true,
        progressPercent: 100,
        completedPieceCount: 36,
      );
      expect(getJson(sm.progress, 'ugc:sample_02'), isNotNull);

      await GameRepository.instance.deleteCustomPuzzle('sample_02');

      expect(sm.collections.get('custom:sample_02'), isNull);
      expect(getJson(sm.progress, 'ugc:sample_02'), isNull);
    });

    test('addCustomPuzzle 单条落盘（不再整 JSON 数组重写）', () async {
      await GameRepository.instance.init();
      final tiers = PuzzleAspectRatio.square1x1.tiers;
      final item = CustomPuzzleItem(
        id: 'my_puzzle_1',
        title: '测试自制',
        imagePathOrUrl: 'assets/bg/tile_000.webp',
        isLocalFile: false,
        difficulty: tiers.first.difficulty,
      );
      await GameRepository.instance.addCustomPuzzle(item);

      final m = getJson(sm.collections, 'custom:my_puzzle_1');
      expect(m?['title'], '测试自制');
      expect(GameRepository.instance.customPuzzles.first.id, 'my_puzzle_1');
    });
  });
}
