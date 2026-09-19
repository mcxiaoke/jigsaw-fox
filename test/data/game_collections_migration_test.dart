// P1-4：测试有意触发失败路径以验证容错逻辑，统一豁免
// ignore_for_file: avoid_catches_without_on_clauses
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
        .setMockMethodCallHandler(channel, (methodCall) async {
          return testRoot.path;
        });
  });

  tearDownAll(() async {
    try {
      if (testRoot.existsSync()) await testRoot.delete(recursive: true);
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
      if (!cacheDir.existsSync()) await cacheDir.create(recursive: true);
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
    test('首次启动不植入样例并置 presetsInitialized=true', () async {
      await GameRepository.instance.init();
      expect(GameRepository.instance.customPuzzles, isEmpty);
      expect(sm.state.get('custom:presetsInitialized'), isTrue);
      final keys = sm.collections.keys
          .cast<String>()
          .where((k) => k.startsWith('custom:'))
          .length;
      expect(keys, 0);
    });

    test('删光后重启不重生成（标志已置 true）', () async {
      await GameRepository.instance.init();
      final tiers = PuzzleAspectRatio.square1x1.tiers;
      await GameRepository.instance.addCustomPuzzle(
        CustomPuzzleItem(
          id: 'test_p1',
          imagePathOrUrl: 'assets/bg/tile_000.webp',
          isLocalFile: false,
          difficulty: tiers.first.difficulty,
        ),
      );
      expect(GameRepository.instance.customPuzzles, hasLength(1));
      await GameRepository.instance.deleteCustomPuzzle('test_p1');
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
      final tiers = PuzzleAspectRatio.square1x1.tiers;
      await GameRepository.instance.addCustomPuzzle(
        CustomPuzzleItem(
          id: 'ugc_custom_01',
          imagePathOrUrl: 'assets/bg/tile_000.webp',
          isLocalFile: false,
          difficulty: tiers.first.difficulty,
        ),
      );
      await ProgressStore.instance.updateProgress(
        canonicalId: 'ugc:ugc_custom_01',
        isCompleted: true,
        progressPercent: 100,
        bestTimeSeconds: 42,
        completedPieceCount: 16,
      );

      // 模拟重启
      await ProgressStore.instance.reloadForTest();
      await GameRepository.instance.init();
      final s1 = GameRepository.instance.customPuzzles.firstWhere(
        (p) => p.id == 'ugc_custom_01',
      );
      expect(s1.isCompleted, isTrue);
      expect(s1.progressPercent, 100);
      expect(s1.bestTimeSeconds, 42);
      expect(s1.completedPieceCounts, contains(16));
    });

    test('deleteCustomPuzzle 级联删除 ugc:{id} 进度', () async {
      await GameRepository.instance.init();
      final tiers = PuzzleAspectRatio.square1x1.tiers;
      await GameRepository.instance.addCustomPuzzle(
        CustomPuzzleItem(
          id: 'ugc_custom_02',
          imagePathOrUrl: 'assets/bg/tile_000.webp',
          isLocalFile: false,
          difficulty: tiers.first.difficulty,
        ),
      );
      await ProgressStore.instance.updateProgress(
        canonicalId: 'ugc:ugc_custom_02',
        isCompleted: true,
        progressPercent: 100,
        completedPieceCount: 36,
      );
      expect(getJson(sm.progress, 'ugc:ugc_custom_02'), isNotNull);

      await GameRepository.instance.deleteCustomPuzzle('ugc_custom_02');

      expect(sm.collections.get('custom:ugc_custom_02'), isNull);
      expect(getJson(sm.progress, 'ugc:ugc_custom_02'), isNull);
    });

    test('启动时自动物理清理历史残留 sample_ 示例及其进度与快照', () async {
      // 模拟旧版本用户本地残留的 sample_01 示例与进度
      final tiers = PuzzleAspectRatio.square1x1.tiers;
      final legacyItem = CustomPuzzleItem(
        id: 'sample_01',
        title: 'Sample 1',
        imagePathOrUrl: 'assets/sample/sample_01.jpg',
        isLocalFile: false,
        difficulty: tiers.first.difficulty,
      );
      await putJson(sm.collections, 'custom:sample_01', legacyItem.toJson());
      await ProgressStore.instance.updateProgress(
        canonicalId: 'ugc:sample_01',
        isCompleted: true,
      );
      expect(sm.collections.get('custom:sample_01'), isNotNull);

      // 执行初始化
      await GameRepository.instance.init();

      // 验证已被自动物理删除
      expect(sm.collections.get('custom:sample_01'), isNull);
      expect(getJson(sm.progress, 'ugc:sample_01'), isNull);
      expect(
        GameRepository.instance.customPuzzles.where((p) => p.id == 'sample_01'),
        isEmpty,
      );
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
