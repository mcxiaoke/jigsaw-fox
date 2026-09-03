import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/image_source.dart';
import '../logic/models/puzzle_state.dart';
import '../logic/puzzle_model.dart';
import '../services/achievement_store.dart';
import '../services/app_logger.dart';
import '../services/economy_service.dart';
import '../logic/download_manager.dart';
import 'favorite_store.dart';
import 'models/custom_puzzle_item.dart';
import 'models/level_item.dart';
import 'progress_store.dart';
import 'snapshot_store.dart';
import 'storage_manager.dart';

/// Central game data repository managing main levels, daily challenges, UGC custom puzzles, and persistent state.
class GameRepository {
  GameRepository._();
  static final GameRepository instance = GameRepository._();

  static const List<String> kBackgroundAssets = [
    'assets/bg/tile_000.webp',
    'assets/bg/tile_001.webp',
    'assets/bg/tile_002.webp',
    'assets/bg/tile_003.webp',
    'assets/bg/tile_004.webp',
    'assets/bg/tile_005.webp',
    'assets/bg/tile_006.webp',
    'assets/bg/tile_007.webp',
    'assets/bg/tile_008.webp',
    'assets/bg/tile_009.webp',
    'assets/bg/tile_010.webp',
    'assets/bg/tile_011.webp',
  ];

  // 主线进度已收敛至 game-progress-v1（§2.3）：`jigsaw level {i}` 整条
  // LevelItem 读写路径已删除，不再有 prefs 键前缀常量。
  // 自制拼图元数据在 game-collections-v1 的 `custom:{id}`（§2.2）；
  // presetsInitialized 标志在 app-state-v1（同前缀跨 box，§4.4 注意事项）
  static const String _customKeyPrefix = 'custom:';
  static const String kKeyPresetsInitialized = 'custom:presetsInitialized';
  static const String _keySoundEnabled = 'jigsaw_setting_sound';
  static const String _keyHapticEnabled = 'jigsaw_setting_haptic';
  static const String _keyGridPreviewEnabled = 'jigsaw_setting_grid_preview';
  static const String _keyPieceScatterMode =
      'jigsaw_setting_piece_scatter_mode';
  static const String _keySelectedBackground =
      'jigsaw_setting_selected_background';

  // 全局统计（§2.2 / §4.3）：app-state-v1 原生 int
  static const String _keyStatPiecesSnapped = 'stat:totalPiecesSnapped';
  static const String _keyStatPlayTime = 'stat:totalPlayTimeSeconds';

  SharedPreferences? _prefs;
  List<LevelItem> _levels = [];
  List<CustomPuzzleItem> _customPuzzles = [];

  final ValueNotifier<List<CustomPuzzleItem>> customPuzzlesNotifier =
      ValueNotifier<List<CustomPuzzleItem>>([]);

  List<LevelItem> get levels => List.unmodifiable(_levels);
  List<CustomPuzzleItem> get customPuzzles => List.unmodifiable(_customPuzzles);

  bool get soundEnabled => _prefs?.getBool(_keySoundEnabled) ?? true;
  set soundEnabled(bool v) => _prefs?.setBool(_keySoundEnabled, v);

  bool get hapticEnabled => _prefs?.getBool(_keyHapticEnabled) ?? true;
  set hapticEnabled(bool v) => _prefs?.setBool(_keyHapticEnabled, v);

  bool get gridPreviewEnabled =>
      _prefs?.getBool(_keyGridPreviewEnabled) ?? true;
  set gridPreviewEnabled(bool v) => _prefs?.setBool(_keyGridPreviewEnabled, v);

  /// 碎片初始排布模式：'tray'（底部托盘收纳，默认/移动端友好）或 'tabletop'（桌面环形发散散落，适合宽屏/平板）
  String get pieceScatterMode =>
      _prefs?.getString(_keyPieceScatterMode) ?? 'tray';
  set pieceScatterMode(String v) => _prefs?.setString(_keyPieceScatterMode, v);

  String get selectedBackground =>
      _prefs?.getString(_keySelectedBackground) ?? kBackgroundAssets[0];
  set selectedBackground(String v) =>
      _prefs?.setString(_keySelectedBackground, v);

  /// 累计通关数（历史累加字段，全库已统一以 ProgressStore.instance.getTotalSolved() 去重图数为 SSOT；
  /// 原 prefs 累加 key 已按 §2.3 丢弃，恒返回 0）
  @Deprecated(
    'Use ProgressStore.instance.getTotalSolved() for distinct solved count',
  )
  int get totalCompletedLevels => 0;

  /// 注意：以下两个 stat getter 直接读 app-state-v1 box（fail-fast），
  /// **前置条件：必须先执行 StorageManager.openAll()**——main() 中在 runApp 前
  /// 已 `await openAllWithMemoryFallback()`，生产路径安全；仅测试/误用场景
  /// 会在未打开时抛 StateError，用于尽早暴露初始化顺序错误。
  int get totalPiecesSnapped =>
      (StorageManager.instance.state.get(_keyStatPiecesSnapped) as int?) ?? 0;
  int get totalPlayTimeSeconds =>
      (StorageManager.instance.state.get(_keyStatPlayTime) as int?) ?? 0;

  /// Initializes persistent store and generates predefined levels, daily challenge series, and UGC presets.
  Future<void> init() async {
    AppLogger.repo.info('init start');
    final sw = Stopwatch()..start();
    _prefs = await SharedPreferences.getInstance();
    // 初始化新一代文件级快照与轻量进度索引（无迁移，直接可用）
    try {
      await SnapshotStore.instance.init();
      await ProgressStore.instance.init();
    } catch (e, st) {
      AppLogger.repo.warning('init Snapshot/Progress failed', e, st);
    }
    _initLevels();
    await _initCustomPuzzles();
    AppLogger.repo.info(
      'init done ${sw.elapsedMilliseconds}ms levels=${_levels.length} custom=${_customPuzzles.length}',
    );
  }

  // --- CanonicalId helpers ---
  static String canonicalForLevel(int index) =>
      'main:${index.toString().padLeft(3, '0')}';
  static String canonicalForDaily(String dateStr) =>
      'daily:${dateStr.replaceAll('-', '')}';
  static String canonicalForCustom(String id) => 'ugc:$id';
  static String canonicalForPack(String packId, String fileName) =>
      'pack:$packId:$fileName';

  void _initLevels() {
    final list = <LevelItem>[];
    const totalLevels = 100;

    for (var i = 1; i <= totalLevels; i++) {
      final assetPath = assetSamples[(i - 1) % assetSamples.length];

      // 主线 100 关阶梯难度配置（对齐 v3.3.1 设计 §3）
      // 1~10: L1(25) | 11~35: L1.5(36) | 36~60: L2(64) | 61~80: L3(100) | 81~93: L4(144) | 94~100: L5(225)
      final squareTiers = PuzzleAspectRatio.square1x1.tiers;
      PuzzleDifficulty diff;
      if (i <= 10) {
        diff = squareTiers[0].difficulty; // L1: 5x5 (25)
      } else if (i <= 35) {
        diff = squareTiers[1].difficulty; // L1.5: 6x6 (36)
      } else if (i <= 60) {
        diff = squareTiers[2].difficulty; // L2: 8x8 (64)
      } else if (i <= 80) {
        diff = squareTiers[3].difficulty; // L3: 10x10 (100)
      } else if (i <= 93) {
        diff = squareTiers[4].difficulty; // L4: 12x12 (144)
      } else {
        diff = squareTiers[5].difficulty; // L5: 15x15 (225)
      }

      // 水合（§7.3 step3）：静态生成 LevelItem，再从 ProgressStore 的
      // `main:{NNN}` 回填进度字段。原「读 prefs `jigsaw level {i}` 整条 JSON」
      // 分支已整体删除——进度 SSOT 唯一，不再有 prefs 副本。
      final prog = ProgressStore.instance.getLevelProgress(
        canonicalForLevel(i),
      );

      // 全量可浏览：无解锁墙，首期全部可玩（Phase0）
      // 后续如需象征性解锁，通过 manifest unlockCoins/unlockCode 字段扩展
      final now = DateTime.now();
      final addedAt = i > 90
          ? now.subtract(Duration(days: 100 - i))
          : now.subtract(const Duration(days: 30));
      list.add(
        LevelItem(
          id: 'level_$i',
          index: i,
          title: '第 $i 关',
          assetPath: assetPath,
          difficulty: diff,
          isUnlocked: true,
          isCompleted: prog.isCompleted,
          progressPercent: prog.progressPercent,
          stars: prog.stars,
          bestTimeSeconds: prog.bestTimeSeconds,
          completedPieceCounts: prog.completedPieceCounts,
          addedAt: addedAt,
        ),
      );
    }
    _levels = list;
    AppLogger.repo.info(
      'initLevels ${list.length} levels completed=${list.where((l) => l.isCompleted).length} unlocked=${list.where((l) => l.isUnlocked).length}',
    );
  }

  /// 自制拼图初始化（§4.4 / §7.3）：
  /// - 元数据：`game-collections-v1` 的 `custom:{id}` 逐条存储；
  /// - 「全删后死灰复燃」防护：`app-state-v1` 的 `custom:presetsInitialized`
  ///   显式标志区分「首次启动」与「用户删光」；
  /// - 进度水合：加载元数据后立即从 ProgressStore 的 `ugc:{id}` 回填，
  ///   否则通关状态重启后全部「回退」为未完成。
  Future<void> _initCustomPuzzles() async {
    final stateBox = StorageManager.instance.state;
    final collectionsBox = StorageManager.instance.collections;
    final presetsInitialized = stateBox.get(kKeyPresetsInitialized) as bool?;

    final rawItems = <CustomPuzzleItem>[];
    // 先收集后处理（§5.4）
    final keys = collectionsBox.keys
        .cast<String>()
        .where((k) => k.startsWith(_customKeyPrefix))
        .toList();
    for (final key in keys) {
      final m = getJson(collectionsBox, key);
      if (m == null) continue;
      try {
        rawItems.add(CustomPuzzleItem.fromJson(m));
      } catch (e, st) {
        AppLogger.repo.warning('Failed to parse custom item key=$key', e, st);
      }
    }

    if (presetsInitialized != true && rawItems.isEmpty) {
      // Default preset samples for "My Puzzles"
      final squareTiers = PuzzleAspectRatio.square1x1.tiers;
      final samples = [
        CustomPuzzleItem(
          id: 'sample_01',
          title: '巴黎埃菲尔铁塔晨曦',
          imagePathOrUrl: assetSamples[0],
          isLocalFile: false,
          sourcePlatform: '网络',
          difficulty: squareTiers[0].difficulty, // 16
          createdAt: DateTime.now().subtract(const Duration(days: 2)),
        ),
        CustomPuzzleItem(
          id: 'sample_02',
          title: '午后阳光与香浓拿铁',
          imagePathOrUrl: assetSamples[1],
          isLocalFile: false,
          sourcePlatform: '网络',
          difficulty: squareTiers[2].difficulty, // 36
          createdAt: DateTime.now().subtract(const Duration(days: 1)),
        ),
        CustomPuzzleItem(
          id: 'sample_03',
          title: '草地上奔跑的小柴犬',
          imagePathOrUrl: assetSamples[2],
          isLocalFile: false,
          sourcePlatform: '网络',
          difficulty: squareTiers[3].difficulty, // 64
          createdAt: DateTime.now(),
        ),
      ];
      // 失败语义（§4.4）：全部成功才置 true，任一失败保持 false，
      // 下次启动重新植入完整样例，避免「半套样例 + 永久跳过」的脏状态
      var allOk = true;
      for (final s in samples) {
        try {
          await _saveCustomPuzzle(s);
        } catch (e, st) {
          allOk = false;
          AppLogger.repo.warning('Failed to plant sample ${s.id}', e, st);
        }
      }
      if (allOk) {
        rawItems.addAll(samples);
        await stateBox.put(kKeyPresetsInitialized, true);
        AppLogger.repo.info('initCustom created default 3 samples');
      }
    } else {
      if (presetsInitialized != true) {
        // 有历史数据但标志缺失（理论不可达，防御性补写）
        await stateBox.put(kKeyPresetsInitialized, true);
      }
    }

    // ugc:{id} 进度水合（§7.3 v4.3）——空判断用「无任何落盘痕迹」
    _customPuzzles = rawItems.map((item) {
      final prog = ProgressStore.instance.getLevelProgress(
        canonicalForCustom(item.id),
      );
      final hasRecord =
          prog.lastSavedAt != null ||
          prog.isCompleted ||
          prog.progressPercent > 0;
      if (!hasRecord) return item;
      return item.copyWith(
        isCompleted: prog.isCompleted,
        progressPercent: prog.progressPercent,
        bestTimeSeconds: prog.bestTimeSeconds,
        completedPieceCounts: prog.completedPieceCounts,
      );
    }).toList();

    customPuzzlesNotifier.value = List.unmodifiable(_customPuzzles);
    AppLogger.repo.info(
      'initCustom loaded ${_customPuzzles.length} from hive (initialized=$presetsInitialized)',
    );
  }

  /// 单条落盘（原 `jigsaw custom list` 整 JSON 数组全量重写已被逐条 put 取代）。
  /// 只写元数据（§5.2）：进度字段委托 ugc:{id}，不在此冗余落盘。
  Future<void> _saveCustomPuzzle(CustomPuzzleItem item) async {
    await putJson(
      StorageManager.instance.collections,
      '$_customKeyPrefix${item.id}',
      item.toMetadataJson(),
    );
  }

  /// 删除单条元数据
  Future<void> _deleteCustomPuzzleKey(String id) async {
    await StorageManager.instance.collections.delete('$_customKeyPrefix$id');
  }

  /// Adds a new user custom puzzle.
  Future<void> addCustomPuzzle(CustomPuzzleItem item) async {
    AppLogger.repo.info(
      'addCustomPuzzle id=${item.id} title=${item.title} isLocal=${item.isLocalFile}',
    );
    _customPuzzles.insert(0, item);
    customPuzzlesNotifier.value = List.unmodifiable(_customPuzzles);
    await _saveCustomPuzzle(item);
  }

  /// Deletes a custom puzzle and cleans up local image file if present.
  Future<void> deleteCustomPuzzle(String id) async {
    final idx = _customPuzzles.indexWhere((p) => p.id == id);
    if (idx != -1) {
      final item = _customPuzzles[idx];
      AppLogger.repo.info(
        'deleteCustomPuzzle id=$id path=${AppLogger.sanitizePath(item.imagePathOrUrl)} isLocal=${item.isLocalFile}',
      );
      if (item.isLocalFile && !item.imagePathOrUrl.startsWith('assets/')) {
        try {
          final file = File(item.imagePathOrUrl);
          if (await file.exists()) {
            await file.delete();
            AppLogger.repo.info(
              'Deleted local file ${AppLogger.sanitizePath(item.imagePathOrUrl)}',
            );
          }
        } catch (e, st) {
          AppLogger.repo.warning(
            'Failed to delete local file ${AppLogger.sanitizePath(item.imagePathOrUrl)}',
            e,
            st,
          );
        }
      }
      // 清理该自制对应的全部难度快照
      try {
        await SnapshotStore.instance.deleteAllFor(canonicalForCustom(id));
        await ProgressStore.instance.clearAllSnapshots(canonicalForCustom(id));
      } catch (_) {}
      _customPuzzles.removeAt(idx);
      customPuzzlesNotifier.value = List.unmodifiable(_customPuzzles);
      await _deleteCustomPuzzleKey(id);
      // 级联删进度记录（§7.3 v4.3）：防止孤儿 ugc:{id} 进度永久残留、
      // 且重新创建同 id 拼图时旧进度错误复活
      try {
        await ProgressStore.instance.delete(canonicalForCustom(id));
      } catch (e, st) {
        AppLogger.repo.warning(
          'deleteCustomPuzzle cascade progress failed id=$id',
          e,
          st,
        );
      }
    } else {
      AppLogger.repo.warning('deleteCustomPuzzle not found id=$id');
    }
  }

  /// Updates progress or completion state of a main level.
  Future<void> updateLevelProgress({
    required int levelIndex,
    required int progressPercent,
    String? snapshotJson,
    bool isCompleted = false,
    int? completedPieceCount,
    String? difficultyKey,
    int stars = 0,
    int timeSeconds = 0,
  }) async {
    final idx = levelIndex - 1;
    if (idx < 0 || idx >= _levels.length) {
      AppLogger.repo.warning(
        'updateLevelProgress invalid index $levelIndex len=${_levels.length}',
      );
      return;
    }
    AppLogger.repo.info(
      'updateLevelProgress level=$levelIndex progress=$progressPercent% completed=$isCompleted pieceCount=$completedPieceCount stars=$stars time=${timeSeconds}s',
    );

    var current = _levels[idx];
    final newStars = isCompleted
        ? (stars > current.stars ? stars : current.stars)
        : current.stars;
    final newBestTime = isCompleted
        ? (current.bestTimeSeconds == 0 || timeSeconds < current.bestTimeSeconds
              ? timeSeconds
              : current.bestTimeSeconds)
        : current.bestTimeSeconds;

    final updatedCompletedCounts = Set<int>.from(current.completedPieceCounts);
    if (isCompleted && completedPieceCount != null) {
      updatedCompletedCounts.add(completedPieceCount);
    }

    // 内存 Item 立即更新（UI 同步响应），持久化走 ProgressStore →
    // game-progress-v1 单条（原 prefs `jigsaw level {i}` 整条写入已删除，§2.3）
    _levels[idx] = current.copyWith(
      progressPercent: progressPercent,
      isCompleted:
          isCompleted ||
          current.isCompleted ||
          updatedCompletedCounts.isNotEmpty,
      stars: newStars,
      bestTimeSeconds: newBestTime,
      savedSnapshotJson: null,
      clearSnapshot: true,
      completedPieceCounts: updatedCompletedCounts.toList(),
    );

    // 同步到新一代文件级快照与轻量索引
    final canonicalId = canonicalForLevel(levelIndex);
    final shouldClear =
        isCompleted || (snapshotJson == null && progressPercent == 0);
    try {
      if (snapshotJson != null && !isCompleted) {
        final map = jsonDecode(snapshotJson) as Map<String, dynamic>;
        final state = PuzzleBoardState.fromJson(map);
        final enriched = state.copyWith(
          canonicalId: canonicalId,
          difficultyKey: state.effectiveDifficultyKey,
          updatedAt: DateTime.now(),
          createdAt: state.createdAt ?? DateTime.now(),
        );
        await SnapshotStore.instance.save(enriched);
        await ProgressStore.instance.updateProgress(
          canonicalId: canonicalId,
          progressPercent: progressPercent,
          hasSnapshot: true,
          activeDifficultyKey: enriched.effectiveDifficultyKey,
          snapshotKeys: [enriched.effectiveDifficultyKey],
        );
      } else if (shouldClear) {
        // 清档或通关：优先按显式 difficultyKey 精确删除，消除 pieceCount 横竖歧义
        if (difficultyKey != null && difficultyKey.isNotEmpty) {
          await SnapshotStore.instance.delete(canonicalId, difficultyKey);
          await ProgressStore.instance.clearSnapshot(
            canonicalId,
            difficultyKey,
          );
        } else if (completedPieceCount != null) {
          // 兜底：按 pieceCount 反查（存在横竖歧义，仅兼容旧调用）
          final diff = PuzzleDifficulty.presets.firstWhere(
            (d) => d.pieceCount == completedPieceCount,
            orElse: () => current.difficulty,
          );
          await SnapshotStore.instance.delete(
            canonicalId,
            SnapshotStore.difficultyKeyFor(diff),
          );
          await ProgressStore.instance.clearSnapshot(
            canonicalId,
            SnapshotStore.difficultyKeyFor(diff),
          );
        } else if (snapshotJson == null && !isCompleted) {
          // 放弃进度：若当前有 activeDifficultyKey 则删之
          final prog = await ProgressStore.instance.load(canonicalId);
          if (prog.activeDifficultyKey.isNotEmpty) {
            await SnapshotStore.instance.delete(
              canonicalId,
              prog.activeDifficultyKey,
            );
            await ProgressStore.instance.clearSnapshot(
              canonicalId,
              prog.activeDifficultyKey,
            );
          } else {
            await SnapshotStore.instance.deleteAllFor(canonicalId);
            await ProgressStore.instance.clearAllSnapshots(canonicalId);
          }
        } else {
          await SnapshotStore.instance.deleteAllFor(canonicalId);
          await ProgressStore.instance.clearAllSnapshots(canonicalId);
        }
      } else if (!isCompleted && progressPercent > 0) {
        await ProgressStore.instance.updateProgress(
          canonicalId: canonicalId,
          progressPercent: progressPercent,
        );
      }

      if (isCompleted && completedPieceCount != null) {
        await ProgressStore.instance.updateProgress(
          canonicalId: canonicalId,
          isCompleted: true,
          completedPieceCount: completedPieceCount,
          stars: newStars,
          bestTimeSeconds: newBestTime,
          hasSnapshot: false,
        );
      }
    } catch (e, st) {
      AppLogger.repo.warning(
        'updateLevelProgress snapshot sync failed level=$levelIndex',
        e,
        st,
      );
    }

    // Phase0：全量可玩，无关卡墙；保留空实现以兼容旧存档，后续如启用金币解锁再在此扩展
    // 后续象征性解锁示例：if (nextLevel.unlockCoins != null) check coins
    if (isCompleted && levelIndex < _levels.length) {
      final nextIdx = levelIndex;
      if (!_levels[nextIdx].isUnlocked) {
        // Phase0 恒为 true，此分支实际不触发；即使触发也仅更新内存——
        // isUnlocked 不持久化（§2.3 §4.5），无需写 prefs/box
        _levels[nextIdx] = _levels[nextIdx].copyWith(isUnlocked: true);
      }
    }

    if (isCompleted) {
      AppLogger.repo.info('Level $levelIndex completed');
    }
  }

  /// 读取文件级快照（新链路）
  Future<PuzzleBoardState?> loadLevelSnapshot(
    int levelIndex,
    PuzzleDifficulty difficulty,
  ) async {
    return SnapshotStore.instance.load(
      canonicalForLevel(levelIndex),
      SnapshotStore.difficultyKeyFor(difficulty),
    );
  }

  Future<bool> hasLevelSnapshot(
    int levelIndex,
    PuzzleDifficulty difficulty,
  ) async {
    return SnapshotStore.instance.hasSnapshot(
      canonicalForLevel(levelIndex),
      SnapshotStore.difficultyKeyFor(difficulty),
    );
  }

  Future<String?> loadLevelSnapshotJson(
    int levelIndex,
    PuzzleDifficulty difficulty,
  ) async {
    return SnapshotStore.instance.loadJsonString(
      canonicalForLevel(levelIndex),
      SnapshotStore.difficultyKeyFor(difficulty),
    );
  }

  Future<PuzzleBoardState?> loadDailySnapshot(
    String dateStr,
    PuzzleDifficulty difficulty,
  ) async {
    return SnapshotStore.instance.load(
      canonicalForDaily(dateStr),
      SnapshotStore.difficultyKeyFor(difficulty),
    );
  }

  Future<String?> loadDailySnapshotJson(
    String dateStr,
    PuzzleDifficulty difficulty,
  ) async {
    return SnapshotStore.instance.loadJsonString(
      canonicalForDaily(dateStr),
      SnapshotStore.difficultyKeyFor(difficulty),
    );
  }

  /// Updates custom puzzle progress.
  Future<void> updateCustomProgress({
    required String id,
    required int progressPercent,
    String? snapshotJson,
    bool isCompleted = false,
    int? completedPieceCount,
    String? difficultyKey,
    int timeSeconds = 0,
  }) async {
    AppLogger.repo.info(
      'updateCustomProgress id=$id progress=$progressPercent% completed=$isCompleted pieceCount=$completedPieceCount time=${timeSeconds}s',
    );
    final idx = _customPuzzles.indexWhere((p) => p.id == id);
    if (idx == -1) {
      AppLogger.repo.warning('updateCustomProgress not found id=$id');
      return;
    }

    var current = _customPuzzles[idx];
    final newBestTime = isCompleted
        ? (current.bestTimeSeconds == 0 || timeSeconds < current.bestTimeSeconds
              ? timeSeconds
              : current.bestTimeSeconds)
        : current.bestTimeSeconds;

    final updatedCompletedCounts = Set<int>.from(current.completedPieceCounts);
    if (isCompleted && completedPieceCount != null) {
      updatedCompletedCounts.add(completedPieceCount);
    }

    final shouldClear =
        isCompleted || (snapshotJson == null && progressPercent == 0);
    _customPuzzles[idx] = current.copyWith(
      progressPercent: progressPercent,
      isCompleted:
          isCompleted ||
          current.isCompleted ||
          updatedCompletedCounts.isNotEmpty,
      bestTimeSeconds: newBestTime,
      savedSnapshotJson: null,
      clearSnapshot: true,
      completedPieceCounts: updatedCompletedCounts.toList(),
    );

    customPuzzlesNotifier.value = List.unmodifiable(_customPuzzles);
    // 内存 Item 立即更新（UI 同步响应）；进度字段已委托 game-progress-v1 的
    // ugc:{id}，元数据落盘只写 custom:{id}（§5.2）
    await _saveCustomPuzzle(_customPuzzles[idx]);

    final canonicalId = canonicalForCustom(id);
    try {
      if (snapshotJson != null && !isCompleted) {
        final state = PuzzleBoardState.fromJson(
          jsonDecode(snapshotJson) as Map<String, dynamic>,
        );
        final enriched = state.copyWith(
          canonicalId: canonicalId,
          difficultyKey: state.effectiveDifficultyKey,
          updatedAt: DateTime.now(),
          createdAt: state.createdAt ?? DateTime.now(),
        );
        await SnapshotStore.instance.save(enriched);
        await ProgressStore.instance.updateProgress(
          canonicalId: canonicalId,
          progressPercent: progressPercent,
          hasSnapshot: true,
          activeDifficultyKey: enriched.effectiveDifficultyKey,
          snapshotKeys: [enriched.effectiveDifficultyKey],
        );
      } else if (shouldClear) {
        if (difficultyKey != null && difficultyKey.isNotEmpty) {
          await SnapshotStore.instance.delete(canonicalId, difficultyKey);
          await ProgressStore.instance.clearSnapshot(
            canonicalId,
            difficultyKey,
          );
        } else if (completedPieceCount != null) {
          final diff = PuzzleDifficulty.presets.firstWhere(
            (d) => d.pieceCount == completedPieceCount,
            orElse: () => current.difficulty,
          );
          await SnapshotStore.instance.delete(
            canonicalId,
            SnapshotStore.difficultyKeyFor(diff),
          );
          await ProgressStore.instance.clearSnapshot(
            canonicalId,
            SnapshotStore.difficultyKeyFor(diff),
          );
        } else if (snapshotJson == null && !isCompleted) {
          final prog = await ProgressStore.instance.load(canonicalId);
          if (prog.activeDifficultyKey.isNotEmpty) {
            await SnapshotStore.instance.delete(
              canonicalId,
              prog.activeDifficultyKey,
            );
            await ProgressStore.instance.clearSnapshot(
              canonicalId,
              prog.activeDifficultyKey,
            );
          } else {
            await SnapshotStore.instance.deleteAllFor(canonicalId);
            await ProgressStore.instance.clearAllSnapshots(canonicalId);
          }
        } else {
          await SnapshotStore.instance.deleteAllFor(canonicalId);
          await ProgressStore.instance.clearAllSnapshots(canonicalId);
        }
      } else if (!isCompleted && progressPercent > 0) {
        await ProgressStore.instance.updateProgress(
          canonicalId: canonicalId,
          progressPercent: progressPercent,
        );
      }

      if (isCompleted && completedPieceCount != null) {
        await ProgressStore.instance.updateProgress(
          canonicalId: canonicalId,
          isCompleted: true,
          completedPieceCount: completedPieceCount,
          bestTimeSeconds: newBestTime,
          hasSnapshot: false,
        );
      }
    } catch (e, st) {
      AppLogger.repo.warning(
        'updateCustomProgress snapshot sync failed id=$id',
        e,
        st,
      );
    }

    if (isCompleted) {
      AppLogger.repo.info('Custom $id completed');
    }
  }

  Future<PuzzleBoardState?> loadCustomSnapshot(
    String id,
    PuzzleDifficulty difficulty,
  ) async {
    return SnapshotStore.instance.load(
      canonicalForCustom(id),
      SnapshotStore.difficultyKeyFor(difficulty),
    );
  }

  Future<String?> loadCustomSnapshotJson(
    String id,
    PuzzleDifficulty difficulty,
  ) async {
    return SnapshotStore.instance.loadJsonString(
      canonicalForCustom(id),
      SnapshotStore.difficultyKeyFor(difficulty),
    );
  }

  // --- 通用 pack/event 入口（新增） ---

  Future<void> updateGenericProgress({
    required String canonicalId,
    required int progressPercent,
    String? snapshotJson,
    bool isCompleted = false,
    int? completedPieceCount,
    String? difficultyKey,
    int timeSeconds = 0,
    PuzzleDifficulty? difficultyHint,
  }) async {
    try {
      if (snapshotJson != null && !isCompleted) {
        final state = PuzzleBoardState.fromJson(
          jsonDecode(snapshotJson) as Map<String, dynamic>,
        );
        final enriched = state.copyWith(
          canonicalId: canonicalId,
          difficultyKey: state.effectiveDifficultyKey,
          updatedAt: DateTime.now(),
          createdAt: state.createdAt ?? DateTime.now(),
        );
        await SnapshotStore.instance.save(enriched);
        await ProgressStore.instance.updateProgress(
          canonicalId: canonicalId,
          progressPercent: progressPercent,
          hasSnapshot: true,
          activeDifficultyKey: enriched.effectiveDifficultyKey,
          snapshotKeys: [enriched.effectiveDifficultyKey],
        );
      } else if (isCompleted ||
          (snapshotJson == null && progressPercent == 0)) {
        if (difficultyKey != null && difficultyKey.isNotEmpty) {
          await SnapshotStore.instance.delete(canonicalId, difficultyKey);
          await ProgressStore.instance.clearSnapshot(
            canonicalId,
            difficultyKey,
          );
        } else if (completedPieceCount != null && difficultyHint != null) {
          await SnapshotStore.instance.delete(
            canonicalId,
            SnapshotStore.difficultyKeyFor(difficultyHint),
          );
          await ProgressStore.instance.clearSnapshot(
            canonicalId,
            SnapshotStore.difficultyKeyFor(difficultyHint),
          );
        } else if (snapshotJson == null && !isCompleted) {
          final prog = await ProgressStore.instance.load(canonicalId);
          if (prog.activeDifficultyKey.isNotEmpty) {
            await SnapshotStore.instance.delete(
              canonicalId,
              prog.activeDifficultyKey,
            );
            await ProgressStore.instance.clearSnapshot(
              canonicalId,
              prog.activeDifficultyKey,
            );
          } else {
            await SnapshotStore.instance.deleteAllFor(canonicalId);
            await ProgressStore.instance.clearAllSnapshots(canonicalId);
          }
        } else {
          await SnapshotStore.instance.deleteAllFor(canonicalId);
          await ProgressStore.instance.clearAllSnapshots(canonicalId);
        }
      } else if (!isCompleted && progressPercent > 0) {
        await ProgressStore.instance.updateProgress(
          canonicalId: canonicalId,
          progressPercent: progressPercent,
        );
      }

      if (isCompleted) {
        await ProgressStore.instance.updateProgress(
          canonicalId: canonicalId,
          isCompleted: true,
          completedPieceCount: completedPieceCount,
          bestTimeSeconds: timeSeconds,
          hasSnapshot: false,
        );
        AppLogger.repo.info('Generic $canonicalId completed');
      }
    } catch (e, st) {
      AppLogger.repo.warning(
        'updateGenericProgress failed cid=$canonicalId',
        e,
        st,
      );
    }
  }

  Future<PuzzleBoardState?> loadGenericSnapshot(
    String canonicalId,
    PuzzleDifficulty difficulty,
  ) => SnapshotStore.instance.load(
    canonicalId,
    SnapshotStore.difficultyKeyFor(difficulty),
  );

  Future<String?> loadGenericSnapshotJson(
    String canonicalId,
    PuzzleDifficulty difficulty,
  ) => SnapshotStore.instance.loadJsonString(
    canonicalId,
    SnapshotStore.difficultyKeyFor(difficulty),
  );

  /// Adds statistics for snapped piece and play duration.
  /// 原 stat 前缀 / stat 前缀
  /// prefs key 已迁至 app-state-v1 的 `stat:*`（§2.2 / §4.3）。
  Future<void> recordSnapStats({
    int pieceCount = 1,
    int durationSeconds = 0,
  }) async {
    try {
      final stateBox = StorageManager.instance.state;
      if (pieceCount > 0) {
        await stateBox.put(
          _keyStatPiecesSnapped,
          totalPiecesSnapped + pieceCount,
        );
      }
      if (durationSeconds > 0) {
        await stateBox.put(
          _keyStatPlayTime,
          totalPlayTimeSeconds + durationSeconds,
        );
      }
      if (pieceCount > 0 || durationSeconds > 0) {
        AppLogger.repo.fine(
          'recordSnapStats pieceCount=$pieceCount duration=${durationSeconds}s totalSnapped=${totalPiecesSnapped + pieceCount}',
        );
      }
    } catch (e, st) {
      AppLogger.repo.warning('recordSnapStats failed', e, st);
    }
  }

  /// 重置全部进度数据（§7.6）：仅清进度，**保留设置**（行为变更，有意为之——
  /// 现状 `_prefs.clear()` 连设置一起清掉，与文案不符）。
  ///
  /// 注意：本方法在 GameRepository.init() 完成后才可调用（入口 settings_page）。
  Future<void> resetAllData() async {
    AppLogger.repo.warning(
      'resetAllData clearing all hive boxes and snapshots and reinitializing',
    );
    // 1. 清空 3 个 Hive box（clear()，不 deleteFromDisk）
    await Future.wait([
      StorageManager.instance.progress.clear(),
      StorageManager.instance.collections.clear(),
      StorageManager.instance.state.clear(),
    ]);
    // 2. 清文件级快照
    try {
      await SnapshotStore.instance.clearAll();
    } catch (e, st) {
      AppLogger.repo.warning('resetAllData snapshot clear failed', e, st);
    }
    // 3. ProgressStore 重置：清 _index + 刷新聚合 + 广播
    try {
      await ProgressStore.instance.reset();
    } catch (e, st) {
      AppLogger.repo.warning('resetAllData progress reset failed', e, st);
    }
    // 4. 各单例内存状态重置
    try {
      await EconomyService.instance.reset(); // starter 资产重发：金币 100 / 券 5
    } catch (e, st) {
      AppLogger.repo.warning('resetAllData economy reset failed', e, st);
    }
    try {
      await AchievementStore.instance.reset();
    } catch (e, st) {
      AppLogger.repo.warning('resetAllData achievement reset failed', e, st);
    }
    try {
      await FavoriteStore.instance.reset();
    } catch (e, st) {
      AppLogger.repo.warning('resetAllData favorite reset failed', e, st);
    }
    try {
      await DownloadManager.instance.reset(); // 清空 download_cache 物理文件
    } catch (e, st) {
      AppLogger.repo.warning('resetAllData download reset failed', e, st);
    }
    // 5. 重新生成（含 §7.3 的进度水合——此刻 box 已空，样例重新植入，恢复出厂语义）
    _initLevels();
    await _initCustomPuzzles();
    // 6. 仅设置入口保留设置；此处不触碰 SharedPreferences 设置 key
    // 7. 快照索引对账（防幽灵索引）
    try {
      await ProgressStore.instance.reconcileSnapshots();
    } catch (e, st) {
      AppLogger.repo.warning('resetAllData reconcile failed', e, st);
    }
    AppLogger.repo.info('resetAllData done');
  }
}
