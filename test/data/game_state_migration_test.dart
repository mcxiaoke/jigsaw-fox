import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/favorite_store.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/logic/download_manager.dart';
import 'package:jigsawpuzzle/services/achievement_store.dart';
import 'package:jigsawpuzzle/services/economy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helper.dart';

/// Phase 3（app-state-v1 + reset() + resetAllData）DoD 用例（设计 §10.3 / §11）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageManager sm;
  late Directory testRoot;

  setUpAll(() async {
    testRoot = await Directory.systemTemp.createTemp('jigsaw_state_test_');
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

  group('app-state 原生类型（§3.1 / §4.3）', () {
    test('经济/统计原生类型重启后原样读出', () async {
      await EconomyService.instance.reset();
      await GameRepository.instance.recordSnapStats(
        pieceCount: 12,
        durationSeconds: 345,
      );

      await sm.closeAll();
      await sm.openAll();

      expect(sm.state.get('econ:coins'), isA<int>());
      expect(sm.state.get('econ:hintCoupons'), isA<int>());
      expect(sm.state.get('econ:starterGranted'), isA<bool>());
      expect(sm.state.get('stat:totalPiecesSnapped'), 12);
      expect(sm.state.get('stat:totalPlayTimeSeconds'), 345);
      // 无 {"v":...} 包装
      expect(sm.state.get('stat:totalPiecesSnapped'), isNot(isA<Map>()));
    });

    test('经济默认值：key 缺失时读 0，绝不硬编码 100', () async {
      await EconomyService.instance.reset();
      expect(EconomyService.instance.coins, 100); // starter 已补发

      await sm.state.delete('econ:coins');
      await sm.state.delete('econ:hintCoupons');
      expect(EconomyService.instance.coins, 0); // 缺失 → 0 而非 100
      expect(EconomyService.instance.hintCoupons, 0); // 缺失 → 0 而非 5

      // 再次 starter 补发恢复
      await EconomyService.instance.reset();
      expect(EconomyService.instance.coins, 100);
      expect(EconomyService.instance.hintCoupons, 5);
    });
  });

  group('成就缓存加载（§4.3 前缀扫描）', () {
    test('预置 ach:* key → 扫描后 4 内存缓存逐项断言（cid 含冒号不击穿）', () async {
      await AchievementStore.instance.reset();
      // 各类 key 预置
      await sm.state.put('ach:counter:total_wins', 7);
      await sm.state.put('ach:counter:play_seconds', 300);
      await sm.state.put('ach:unlock:first_win', '2026-09-01T10:00:00.000');
      await sm.state.put('ach:claimed:first_win', true);
      await sm.state.put('ach:claimed:not_claimed_one', false); // 未领不载入
      await sm.state.put('ach:starred:main:002', true); // cid 内嵌冒号
      await sm.state.put('ach:starred:pack:nature:001', true); // 多段冒号
      await sm.state.put('ach:starred:main:003', false); // 未计不载入
      // 干扰 key：同前缀但类型不匹配，不应破坏解析
      await sm.state.put('ach:unlock:total_wins', '2026-09-01T10:00:00.000');

      await AchievementStore.instance.reloadForTest();

      expect(AchievementStore.instance.getCounter('total_wins'), 7);
      expect(AchievementStore.instance.getCounter('play_seconds'), 300);
      expect(AchievementStore.instance.getCounter('nope'), 0);

      expect(AchievementStore.instance.isUnlocked('first_win'), isTrue);
      // unlock 前缀取 id 完整（first_win 未被 counter 前缀污染）
      expect(
        AchievementStore.instance.getUnlockedAchievementIds(),
        containsAll(['first_win', 'total_wins']),
      );

      expect(AchievementStore.instance.isClaimed('first_win'), isTrue);
      expect(AchievementStore.instance.isClaimed('not_claimed_one'), isFalse);

      expect(AchievementStore.instance.hasStarred('main:002'), isTrue);
      expect(AchievementStore.instance.hasStarred('pack:nature:001'), isTrue);
      expect(AchievementStore.instance.hasStarred('main:003'), isFalse);
      expect(AchievementStore.instance.starredPuzzleCount, 2);
    });

    test('标记类写入落盘为单条 bool/String/int 并重启读回', () async {
      await AchievementStore.instance.reset();
      await AchievementStore.instance.markUnlocked('first_win');
      await AchievementStore.instance.markClaimed('first_win');
      await AchievementStore.instance.addStarred('main:002');
      await AchievementStore.instance.incrementCounter('total_wins');
      await AchievementStore.instance.incrementCounter('total_wins');

      await sm.closeAll();
      await sm.openAll();
      await AchievementStore.instance.reloadForTest();

      expect(AchievementStore.instance.isUnlocked('first_win'), isTrue);
      expect(AchievementStore.instance.isClaimed('first_win'), isTrue);
      expect(AchievementStore.instance.hasStarred('main:002'), isTrue);
      expect(AchievementStore.instance.getCounter('total_wins'), 2);
    });
  });

  group('resetAllData 重置语义（§7.6）', () {
    test('box 清空、设置保留、样例重植、内存重置、金币 100、聚合刷新、广播', () async {
      // 预置一条用户设置（须保留）
      SharedPreferences.setMockInitialValues({'jigsaw_setting_sound': false});

      await GameRepository.instance.init(); // 植入 3 样例 + 100 关卡
      await EconomyService.instance.init();
      await AchievementStore.instance.init();
      await FavoriteStore.instance.init();

      // 造齐数据
      await ProgressStore.instance.recordDifficultyCompletion(
        canonicalId: 'main:001',
        difficultyKey: '5x5',
        stars: 3,
        timeSeconds: 40,
        hintsUsed: 0,
      );
      await FavoriteStore.instance.toggleFavorite('main:001');
      await AchievementStore.instance.markUnlocked('first_win');
      await AchievementStore.instance.addStarred('main:001');
      await GameRepository.instance.recordSnapStats(
        pieceCount: 10,
        durationSeconds: 66,
      );
      await EconomyService.instance.addCoins(30); // 100 + 30 = 130

      var notifyCount = 0;
      ProgressStore.instance.progressNotifier.addListener(() => notifyCount++);

      await GameRepository.instance.resetAllData();

      // 1. progress box 清空；collections 仅剩步骤 5 重新植入的 3 个样例
      expect(sm.progress.isEmpty, isTrue);
      final customKeys =
          sm.collections.keys
              .cast<String>()
              .where((k) => k.startsWith('custom:'))
              .toList()
            ..sort();
      expect(customKeys, [
        'custom:sample_01',
        'custom:sample_02',
        'custom:sample_03',
      ]);
      expect(sm.collections.length, 3);
      // state box：步骤 4 后只剩 starter 经济三键；成就/统计已清零
      expect(sm.state.get('econ:coins'), 100);
      expect(sm.state.get('econ:hintCoupons'), 5);
      expect(sm.state.get('econ:starterGranted'), true);
      expect(
        sm.state.keys.where((k) => '$k'.startsWith('ach:')).toList(),
        isEmpty,
      );
      expect(
        sm.state.keys.where((k) => '$k'.startsWith('stat:')).toList(),
        isEmpty,
      );

      // 6. 设置 key 保留（resetAllData 只清进度不清设置）
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('jigsaw_setting_sound'), isFalse);

      // 4. 金币/券 starter 重发：当前会话立即生效，无需重启
      expect(EconomyService.instance.coins, 100);
      expect(EconomyService.instance.hintCoupons, 5);

      // 成就/收藏/统计内存已重置
      expect(AchievementStore.instance.isUnlocked('first_win'), isFalse);
      expect(AchievementStore.instance.isClaimed('first_win'), isFalse);
      expect(AchievementStore.instance.starredPuzzleCount, 0);
      expect(FavoriteStore.instance.isFavorite('main:001'), isFalse);
      expect(GameRepository.instance.totalPiecesSnapped, 0);
      expect(GameRepository.instance.totalPlayTimeSeconds, 0);

      // 3. ProgressStore 聚合缓存已刷新 + 已广播
      expect(await ProgressStore.instance.getTotalSolved(), 0);
      expect(await ProgressStore.instance.getTotalStars(), 0);
      expect(notifyCount, greaterThan(0));

      // 5. 样例重新植入（恢复出厂语义，现状行为一致）
      expect(GameRepository.instance.levels, hasLength(100));
      expect(GameRepository.instance.customPuzzles, hasLength(3));
      expect(sm.state.get('custom:presetsInitialized'), isTrue);
    });

    test('重置后 download_cache 无残留文件 + 素材索引清空', () async {
      // 预置素材：物理文件 + material: key
      final cacheDir = await DownloadManager.downloadCacheDir();
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final localFile = File('${cacheDir.path}/mat_local_1.jpg');
      final netFile = File('${cacheDir.path}/img_net_1.jpg');
      await localFile.writeAsBytes(List.generate(64, (i) => i));
      await netFile.writeAsBytes(List.generate(64, (i) => i));
      await putJson(sm.collections, 'material:local_1', {
        'id': 'local_1',
        'sourceUrl': '',
        'localPath': localFile.path,
        'sourcePlatform': '本地相册',
        'width': 800,
        'height': 600,
        'downloadedAt': DateTime.now().toIso8601String(),
        'fileSizeBytes': 64,
      });

      await GameRepository.instance.init();
      await GameRepository.instance.resetAllData();

      // mat_* 与 img_* 全部清除（§7.6：不做脆弱前缀匹配，整目录归零）
      expect(await localFile.exists(), isFalse);
      expect(await netFile.exists(), isFalse);
      // 素材 box 索引已清
      expect(
        sm.collections.keys.where((k) => '$k'.startsWith('material:')),
        isEmpty,
      );
    });
  });
}
