import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive_ce.dart';

import '../services/app_logger.dart';
import 'snapshot_store.dart';
import 'storage_manager.dart';

/// 单档位通关记录（v3.3.1 设计）
class DifficultyRecord {
  const DifficultyRecord({
    this.bestStars = 0,
    this.bestTimeSeconds = 0,
    this.isCompleted = false,
    this.playCount = 0,
    this.minHintsUsed = -1,
    this.firstCompletedAt,
    this.lastCompletedAt,
    this.firstPlayedAt,
    this.lastPlayedAt,
    this.minMoves = -1,
    this.extra = const {},
  });

  final int bestStars;
  final int bestTimeSeconds;
  final bool isCompleted;
  final int playCount;
  final int minHintsUsed; // 历史最少提示次数（初始 -1）
  final DateTime? firstCompletedAt;
  final DateTime? lastCompletedAt;
  final DateTime? firstPlayedAt;
  final DateTime? lastPlayedAt;
  final int minMoves; // 历史最少有效步数（初始 -1）
  final Map<String, dynamic> extra;

  /// 纯粹通关判断（3星且0提示）
  bool get isPerfect => bestStars >= 3 && minHintsUsed == 0;

  DifficultyRecord copyWith({
    int? bestStars,
    int? bestTimeSeconds,
    bool? isCompleted,
    int? playCount,
    int? minHintsUsed,
    DateTime? firstCompletedAt,
    DateTime? lastCompletedAt,
    DateTime? firstPlayedAt,
    DateTime? lastPlayedAt,
    int? minMoves,
    Map<String, dynamic>? extra,
  }) {
    return DifficultyRecord(
      bestStars: bestStars ?? this.bestStars,
      bestTimeSeconds: bestTimeSeconds ?? this.bestTimeSeconds,
      isCompleted: isCompleted ?? this.isCompleted,
      playCount: playCount ?? this.playCount,
      minHintsUsed: minHintsUsed ?? this.minHintsUsed,
      firstCompletedAt: firstCompletedAt ?? this.firstCompletedAt,
      lastCompletedAt: lastCompletedAt ?? this.lastCompletedAt,
      firstPlayedAt: firstPlayedAt ?? this.firstPlayedAt,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      minMoves: minMoves ?? this.minMoves,
      extra: extra ?? this.extra,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'bestStars': bestStars,
      'bestTimeSeconds': bestTimeSeconds,
      'isCompleted': isCompleted,
      'playCount': playCount,
      'minHintsUsed': minHintsUsed,
    };
    if (firstCompletedAt != null) {
      m['firstCompletedAt'] = firstCompletedAt!.toIso8601String();
    }
    if (lastCompletedAt != null) {
      m['lastCompletedAt'] = lastCompletedAt!.toIso8601String();
    }
    if (firstPlayedAt != null) {
      m['firstPlayedAt'] = firstPlayedAt!.toIso8601String();
    }
    if (lastPlayedAt != null) {
      m['lastPlayedAt'] = lastPlayedAt!.toIso8601String();
    }
    if (minMoves >= 0) {
      m['minMoves'] = minMoves;
    }
    extra.forEach((k, v) {
      if (!m.containsKey(k)) m[k] = v;
    });
    return m;
  }

  factory DifficultyRecord.fromJson(Map<String, dynamic> json) {
    const known = {
      'bestStars',
      'bestTimeSeconds',
      'isCompleted',
      'playCount',
      'minHintsUsed',
      'firstCompletedAt',
      'lastCompletedAt',
      'firstPlayedAt',
      'lastPlayedAt',
      'minMoves',
    };
    final extra = <String, dynamic>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) extra[e.key] = e.value;
    }
    return DifficultyRecord(
      bestStars: (json['bestStars'] as int?) ?? 0,
      bestTimeSeconds: (json['bestTimeSeconds'] as int?) ?? 0,
      isCompleted: (json['isCompleted'] as bool?) ?? false,
      playCount: (json['playCount'] as int?) ?? 0,
      minHintsUsed: (json['minHintsUsed'] as int?) ?? -1,
      firstCompletedAt: json['firstCompletedAt'] != null
          ? DateTime.tryParse(json['firstCompletedAt'] as String)
          : null,
      lastCompletedAt: json['lastCompletedAt'] != null
          ? DateTime.tryParse(json['lastCompletedAt'] as String)
          : null,
      firstPlayedAt: json['firstPlayedAt'] != null
          ? DateTime.tryParse(json['firstPlayedAt'] as String)
          : null,
      lastPlayedAt: json['lastPlayedAt'] != null
          ? DateTime.tryParse(json['lastPlayedAt'] as String)
          : null,
      minMoves: (json['minMoves'] as int?) ?? -1,
      extra: extra,
    );
  }
}

/// 档位记录更新结果
class DifficultyRecordUpdateResult {
  const DifficultyRecordUpdateResult({
    required this.stars,
    required this.isNewBestStars,
    required this.deltaStars,
    required this.isFirstNoHintWin,
    required this.record,
  });

  final int stars;
  final bool isNewBestStars;
  final int deltaStars;
  final bool isFirstNoHintWin;
  final DifficultyRecord record;
}

/// 轻量进度索引（按 canonicalId 单条 Hive `game-progress-v1` JSON String）
///
/// 与重型快照文件（SnapshotStore）分离，列表页无需读大文件即可展示
/// 进度、星级、最佳用时与“是否有存档”标记。
/// 支持嵌套档位记录 `Map<difficultyKey, DifficultyRecord>`，避免 N+1 查询。
///
/// 存储迁移（设计 §2.2 / §3.3）：
/// - 值统一为 `jsonEncode(LevelProgress.toJson())` 的 **JSON String**，
///   根除未注册 TypeAdapter 的嵌套 Map 重启后退化为 Map[dynamic,dynamic] 的崩溃；
/// - 冷启动一次性 `jsonDecode` 建全量内存索引 `_index[cid]`，热路径 O(1) 命中；
/// - 主线进度 SSOT：原 `jigsaw level {i}` 整条 LevelItem 读写路径已删除，
///   与 `jigsaw progress v3 聚合` 聚合索引收敛为同一份（§2.3）。
class ProgressStore {
  ProgressStore._();
  static final ProgressStore instance = ProgressStore._();

  int _cachedDistinct3Star = 0;
  int _cachedTotalSolved = 0;
  int _cachedTotalStars = 0;

  /// 全量内存索引（null 表示尚未 init；空 map 表示已 init 但无数据）
  Map<String, LevelProgress>? _index;

  /// 全局响应式进度通知器（当任何关卡产生进度、通关或清档时自增触发）
  final ValueNotifier<int> progressNotifier = ValueNotifier<int>(0);

  void _notifyProgressChanged() {
    progressNotifier.value++;
  }

  int get cachedDistinct3StarCount => _cachedDistinct3Star;
  int get cachedTotalSolvedCount => _cachedTotalSolved;
  int get cachedTotalStarsCount => _cachedTotalStars;

  Box<dynamic> get _box => StorageManager.instance.progress;

  Future<void> _ensureInit() async {
    if (_index != null) return;
    await init();
  }

  /// 冷启动一次性解码建索引（§3.3）
  Future<void> init() async {
    if (_index != null) return; // 幂等守卫（等价原 `if (_prefs != null) return`）
    final map = <String, LevelProgress>{};
    try {
      for (final key in _box.keys.cast<String>()) {
        final raw = _box.get(key) as String?;
        if (raw == null) continue;
        try {
          final p = LevelProgress.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
          final cid = p.canonicalId.isNotEmpty ? p.canonicalId : key;
          map[cid] = p;
        } catch (e, st) {
          AppLogger.repo.warning(
            'ProgressStore.init parse fail key=$key',
            e,
            st,
          );
        }
      }
    } catch (e, st) {
      AppLogger.repo.severe('ProgressStore.init failed', e, st);
    }
    _index = map;
    await refreshAggregatesCache();
    AppLogger.repo.info('ProgressStore.init loaded ${map.length} records');
  }

  /// 纯内存遍历重算（§八）：聚合值是 _index 的纯函数，不落盘
  Future<void> refreshAggregatesCache() async {
    final idx = _index;
    if (idx == null) return;
    var count3Star = 0;
    var countSolved = 0;
    var sumStars = 0;
    for (final p in idx.values) {
      if (p.hasAny3Star) count3Star++;
      if (p.isCompleted || p.records.values.any((r) => r.isCompleted)) {
        countSolved++;
      }
      if (p.records.isNotEmpty) {
        for (final r in p.records.values) {
          sumStars += r.bestStars;
        }
      } else {
        sumStars += p.stars;
      }
    }
    _cachedDistinct3Star = count3Star;
    _cachedTotalSolved = countSolved;
    _cachedTotalStars = sumStars;
  }

  Future<LevelProgress> load(String canonicalId) async {
    await _ensureInit();
    return _index![canonicalId] ?? LevelProgress(canonicalId: canonicalId);
  }

  /// 同步读取单关卡通用进度（内存 O(1) 命中，供 UI 水合使用）
  LevelProgress getLevelProgress(String canonicalId) {
    final idx = _index;
    if (idx == null) return LevelProgress(canonicalId: canonicalId);
    return idx[canonicalId] ?? LevelProgress(canonicalId: canonicalId);
  }

  /// 批量加载全部 LevelProgress（直接返回内存索引副本，O(N) 零解码）
  Future<Map<String, LevelProgress>> loadAllProgress() async {
    await _ensureInit();
    return Map<String, LevelProgress>.from(_index!);
  }

  Future<void> save(LevelProgress p) async {
    await _ensureInit();
    final cid = p.canonicalId;
    if (cid.isEmpty) {
      AppLogger.repo.warning('ProgressStore.save skip empty canonicalId');
      return;
    }
    try {
      // 内存优先（UI 立即响应），再落 box——维持写侧内存一致性（§3.3）
      _index![cid] = p;
      await putJson(_box, cid, p.toJson());
      _notifyProgressChanged();
    } catch (e, st) {
      AppLogger.repo.warning('ProgressStore.save fail cid=$cid', e, st);
    }
  }

  /// 删除指定关卡的进度记录并通知更新
  Future<void> delete(String canonicalId) async {
    await _ensureInit();
    try {
      _index!.remove(canonicalId);
      await _box.delete(canonicalId);
      await refreshAggregatesCache();
      _notifyProgressChanged();
    } catch (e, st) {
      AppLogger.repo.warning(
        'ProgressStore.delete fail cid=$canonicalId',
        e,
        st,
      );
    }
  }

  /// 获取全部已存储的 canonicalId 列表
  Future<List<String>> listAllCanonicalIds() async {
    await _ensureInit();
    return _index!.keys.toList();
  }

  /// 账号资产：获得 3 星的不同图数量（任一档位拿过 3 星即计入，按 canonicalId 去重）
  Future<int> getDistinctImagesWith3Star() async {
    await _ensureInit();
    return _cachedDistinct3Star;
  }

  /// 账号资产：所有 canonicalId × 所有档位 bestStars 求和（读缓存，O(1) 性能）
  Future<int> getTotalStars() async {
    await _ensureInit();
    return _cachedTotalStars;
  }

  /// 账号资产：累计已通关的不同图数量或局数（读缓存，O(1) 性能）
  Future<int> getTotalSolved() async {
    await _ensureInit();
    return _cachedTotalSolved;
  }

  /// 账号资产：累计游玩总局数（跨所有图 × 所有档位）
  ///
  /// 改造后走内存索引遍历，避免每次聚合都重复 jsonDecode（§八）
  Future<int> getTotalPlayCount() async {
    await _ensureInit();
    return _index!.values.fold<int>(0, (sum, p) => sum + p.totalPlayCount);
  }

  /// 记录单图单档位的通关成绩，原子更新嵌套 records 并维护 minHintsUsed 与时间戳
  Future<DifficultyRecordUpdateResult> recordDifficultyCompletion({
    required String canonicalId,
    required String difficultyKey,
    required int stars,
    required int timeSeconds,
    required int hintsUsed,
    int? completedPieceCount,
    int? moves,
  }) async {
    final cur = await load(canonicalId);
    final existingMap = Map<String, DifficultyRecord>.from(cur.records);
    final oldRecord = existingMap[difficultyKey] ?? const DifficultyRecord();

    final isNewBestStars = stars > oldRecord.bestStars;
    final deltaStars = isNewBestStars ? (stars - oldRecord.bestStars) : 0;
    final newBestStars = math.max(oldRecord.bestStars, stars);

    final newBestTime = oldRecord.bestTimeSeconds == 0
        ? timeSeconds
        : (timeSeconds > 0
              ? math.min(oldRecord.bestTimeSeconds, timeSeconds)
              : oldRecord.bestTimeSeconds);

    // minHintsUsed 状态机：初始 -1；取更小值；首次变为 0 时触发 isFirstNoHintWin
    final isFirstNoHintWin =
        hintsUsed == 0 &&
        (oldRecord.minHintsUsed == -1 || oldRecord.minHintsUsed > 0);
    final newMinHints = oldRecord.minHintsUsed == -1
        ? hintsUsed
        : math.min(oldRecord.minHintsUsed, hintsUsed);

    // minMoves 状态机：初始 -1；若有步数传入则维护最小值
    final newMinMoves = (moves != null && moves > 0)
        ? (oldRecord.minMoves <= 0
              ? moves
              : math.min(oldRecord.minMoves, moves))
        : oldRecord.minMoves;

    final now = DateTime.now();
    final updatedRecord = oldRecord.copyWith(
      bestStars: newBestStars,
      bestTimeSeconds: newBestTime,
      isCompleted: true,
      playCount: oldRecord.playCount + 1,
      minHintsUsed: newMinHints,
      minMoves: newMinMoves,
      lastCompletedAt: now,
      firstCompletedAt: oldRecord.firstCompletedAt ?? now,
      lastPlayedAt: now,
      firstPlayedAt: oldRecord.firstPlayedAt ?? now,
    );
    existingMap[difficultyKey] = updatedRecord;

    final updatedCounts = Set<int>.from(cur.completedPieceCounts);
    if (completedPieceCount != null) {
      updatedCounts.add(completedPieceCount);
    }

    final next = cur.copyWith(
      isCompleted: true,
      progressPercent: 100,
      completedPieceCounts: updatedCounts.toList(),
      records: existingMap,
      stars: math.max(cur.stars, newBestStars),
      bestTimeSeconds: cur.bestTimeSeconds == 0
          ? newBestTime
          : math.min(cur.bestTimeSeconds, newBestTime),
      hasSnapshot: false,
      lastSavedAt: now,
      lastCompletedAt: now,
      firstCompletedAt: cur.firstCompletedAt ?? now,
      firstPlayedAt: cur.firstPlayedAt ?? now,
    );
    await save(next);

    // 结算后刷新缓存，避免面板首帧读到旧值
    await refreshAggregatesCache();

    AppLogger.repo.info(
      'ProgressStore.recordDifficultyCompletion cid=$canonicalId dkey=$difficultyKey stars=$stars (best=$newBestStars delta=$deltaStars) time=${timeSeconds}s minHints=$newMinHints firstNoHint=$isFirstNoHintWin',
    );

    return DifficultyRecordUpdateResult(
      stars: stars,
      isNewBestStars: isNewBestStars,
      deltaStars: deltaStars,
      isFirstNoHintWin: isFirstNoHintWin,
      record: updatedRecord,
    );
  }

  Future<void> updateProgress({
    required String canonicalId,
    int? progressPercent,
    bool? isCompleted,
    int? completedPieceCount,
    int? stars,
    int? bestTimeSeconds,
    String? activeDifficultyKey,
    List<String>? snapshotKeys,
    bool? hasSnapshot,
    Map<String, DifficultyRecord>? records,
  }) async {
    final cur = await load(canonicalId);
    final updatedCounts = Set<int>.from(cur.completedPieceCounts);
    if (isCompleted == true && completedPieceCount != null) {
      updatedCounts.add(completedPieceCount);
    }

    final now = DateTime.now();

    // 同步更新 records 字典（若指定了 activeDifficultyKey 且已通关）
    var nextRecords =
        records ?? Map<String, DifficultyRecord>.from(cur.records);
    if (isCompleted == true &&
        activeDifficultyKey != null &&
        activeDifficultyKey.isNotEmpty) {
      final oldR = nextRecords[activeDifficultyKey] ?? const DifficultyRecord();
      final newStars = math.max(oldR.bestStars, stars ?? 0);
      final newTime = oldR.bestTimeSeconds == 0
          ? (bestTimeSeconds ?? 0)
          : ((bestTimeSeconds ?? 0) > 0
                ? math.min(oldR.bestTimeSeconds, bestTimeSeconds!)
                : oldR.bestTimeSeconds);
      nextRecords[activeDifficultyKey] = oldR.copyWith(
        bestStars: newStars,
        bestTimeSeconds: newTime,
        isCompleted: true,
        lastCompletedAt: now,
        firstCompletedAt: oldR.firstCompletedAt ?? now,
        lastPlayedAt: now,
        firstPlayedAt: oldR.firstPlayedAt ?? now,
      );
    }

    final nextStars = (isCompleted == true && stars != null)
        ? math.max(cur.stars, stars)
        : (stars ?? cur.stars);
    final nextBestTime = (isCompleted == true && bestTimeSeconds != null)
        ? (cur.bestTimeSeconds == 0 || bestTimeSeconds < cur.bestTimeSeconds
              ? bestTimeSeconds
              : cur.bestTimeSeconds)
        : (bestTimeSeconds ?? cur.bestTimeSeconds);

    final isFirstPlay = cur.firstPlayedAt == null && cur.lastSavedAt == null;
    final isNowCompleted = isCompleted == true;
    final isFirstCompletion =
        isNowCompleted && cur.firstCompletedAt == null && !cur.isCompleted;

    final next = cur.copyWith(
      progressPercent: progressPercent ?? cur.progressPercent,
      isCompleted: isCompleted ?? cur.isCompleted,
      completedPieceCounts: updatedCounts.toList(),
      stars: nextStars,
      bestTimeSeconds: nextBestTime,
      activeDifficultyKey: activeDifficultyKey ?? cur.activeDifficultyKey,
      snapshotKeys: snapshotKeys ?? cur.snapshotKeys,
      hasSnapshot: hasSnapshot ?? cur.hasSnapshot,
      records: nextRecords,
      lastSavedAt: now,
      firstPlayedAt: isFirstPlay ? now : cur.firstPlayedAt,
      lastCompletedAt: isNowCompleted ? now : cur.lastCompletedAt,
      firstCompletedAt: isFirstCompletion ? now : cur.firstCompletedAt,
    );
    await save(next);
    // 仅当通关状态或星级真正提高时刷新聚合缓存，避免普通 autosave 造成高频 O(N) 扫描
    if ((!cur.isCompleted && next.isCompleted) ||
        (stars != null && stars > cur.stars)) {
      await refreshAggregatesCache();
    }
    AppLogger.repo.fine(
      'ProgressStore.update cid=$canonicalId p=$progressPercent completed=$isCompleted stars=$stars time=$bestTimeSeconds dkey=$activeDifficultyKey hasSnap=$hasSnapshot records=${nextRecords.length}',
    );
  }

  Future<void> setHasSnapshot(
    String canonicalId,
    String difficultyKey,
    bool has,
  ) async {
    final cur = await load(canonicalId);
    final keys = Set<String>.from(cur.snapshotKeys);
    if (has) {
      keys.add(difficultyKey);
    } else {
      keys.remove(difficultyKey);
    }
    final next = cur.copyWith(
      hasSnapshot: keys.isNotEmpty,
      snapshotKeys: keys.toList(),
      activeDifficultyKey: has
          ? difficultyKey
          : (keys.isNotEmpty ? keys.first : cur.activeDifficultyKey),
    );
    await save(next);
  }

  Future<void> clearSnapshot(String canonicalId, String difficultyKey) async {
    await setHasSnapshot(canonicalId, difficultyKey, false);
    final cur = await load(canonicalId);
    // 若该难度是 active，则尝试切换到剩余的第一个
    if (cur.activeDifficultyKey == difficultyKey) {
      final remaining = cur.snapshotKeys
          .where((k) => k != difficultyKey)
          .toList();
      final nextActive = remaining.isNotEmpty ? remaining.first : '';
      await save(
        cur.copyWith(
          activeDifficultyKey: nextActive,
          hasSnapshot: remaining.isNotEmpty,
        ),
      );
    }
  }

  Future<void> clearAllSnapshots(String canonicalId) async {
    final cur = await load(canonicalId);
    await save(
      cur.copyWith(
        hasSnapshot: false,
        snapshotKeys: const [],
        activeDifficultyKey: '',
      ),
    );
  }

  Future<bool> hasSnapshot(String canonicalId) async {
    final p = await load(canonicalId);
    return p.hasSnapshot;
  }

  /// 自动对账：根据 SnapshotStore 的实际快照文件纠正索引状态
  Future<void> reconcile(String canonicalId) async {
    final keys = await SnapshotStore.instance.listDifficultyKeys(canonicalId);
    final has = keys.isNotEmpty;
    final cur = await load(canonicalId);
    if (cur.hasSnapshot != has ||
        (has && !keys.contains(cur.activeDifficultyKey))) {
      final nextActive = has
          ? (keys.contains(cur.activeDifficultyKey)
                ? cur.activeDifficultyKey
                : keys.first)
          : '';
      await save(
        cur.copyWith(
          hasSnapshot: has,
          snapshotKeys: keys,
          activeDifficultyKey: nextActive,
        ),
      );
      AppLogger.repo.info(
        'ProgressStore.reconcile cid=$canonicalId has=$has keys=$keys active=$nextActive',
      );
    }
  }

  /// 重置（§7.6 步骤 3）：清空内存索引、重算聚合缓存并广播。
  ///
  /// **必须存在**——`init()` 有 `if (_index != null) return` 幂等守卫，
  /// `resetAllData()` 里再调 `init()` 不会重建索引，聚合统计会停留在旧值。
  Future<void> reset() async {
    _index = <String, LevelProgress>{};
    await refreshAggregatesCache();
    // 末尾必须广播：「我的」中心等界面靠监听 progressNotifier 重绘，
    // 只清 _index 不通知 → UI 继续显示旧统计（总星数/通关数）
    _notifyProgressChanged();
    AppLogger.repo.info('ProgressStore.reset done');
  }

  /// 测试专用：置空内存索引并从 box 重新加载（模拟冷启动重启，§10.3 往返用例）
  @visibleForTesting
  Future<void> reloadForTest() async {
    _index = null;
    await init();
  }

  /// 校正 _index 中 hasSnapshot/snapshotKeys 与物理快照的一致性（§7.6 步骤 7）。
  ///
  /// 在 init()/恢复/重置后调用，消除幽灵索引（索引称有快照但文件已无）
  /// 与 snapshotKeys 漂移。仅修快照索引，不删进度记录本身。
  Future<void> reconcileSnapshots() async {
    final idx = _index;
    if (idx == null) return;
    var dirty = false;
    for (final cid in idx.keys.toList()) {
      final p = idx[cid]!;
      if (!p.hasSnapshot) continue;
      // SnapshotStore 按 canonicalId 管理快照文件
      final actualKeys = await SnapshotStore.instance.listDifficultyKeys(cid);
      final indexedKeys = p.snapshotKeys;
      final mismatch =
          (actualKeys.isEmpty && p.hasSnapshot) ||
          actualKeys.length != indexedKeys.length ||
          !actualKeys.toSet().containsAll(indexedKeys);
      if (mismatch) {
        final corrected = p.copyWith(
          hasSnapshot: actualKeys.isNotEmpty,
          snapshotKeys: actualKeys,
          activeDifficultyKey: actualKeys.isNotEmpty
              ? p.activeDifficultyKey
              : '',
        );
        idx[cid] = corrected;
        await putJson(_box, cid, corrected.toJson());
        dirty = true;
      }
    }
    if (dirty) {
      await refreshAggregatesCache();
      _notifyProgressChanged();
      AppLogger.repo.info('ProgressStore.reconcileSnapshots corrected');
    }
  }
}

/// 单关卡通用进度（覆盖 main/daily/pack/event/ugc）
class LevelProgress {
  const LevelProgress({
    required this.canonicalId,
    this.progressPercent = 0,
    this.isCompleted = false,
    this.completedPieceCounts = const [],
    this.bestTimeSeconds = 0,
    this.stars = 0,
    this.hasSnapshot = false,
    this.activeDifficultyKey = '',
    this.snapshotKeys = const [],
    this.records = const {},
    this.lastSavedAt,
    this.firstCompletedAt,
    this.lastCompletedAt,
    this.firstPlayedAt,
    this.extra = const {},
  });

  final String canonicalId;
  final int progressPercent;
  final bool isCompleted;
  final List<int> completedPieceCounts;
  final int bestTimeSeconds;
  final int stars;
  final bool hasSnapshot;
  final String activeDifficultyKey;
  final List<String> snapshotKeys;
  final Map<String, DifficultyRecord> records;
  final DateTime? lastSavedAt;
  final DateTime? firstCompletedAt;
  final DateTime? lastCompletedAt;
  final DateTime? firstPlayedAt;
  final Map<String, dynamic> extra;

  /// 语义别名：最近游玩时间（供“我的”Tab 排序消费）
  DateTime? get lastPlayedAt => lastSavedAt;

  /// 单图最高星级
  int get maxStars {
    var m = stars;
    for (final r in records.values) {
      if (r.bestStars > m) m = r.bestStars;
    }
    return m;
  }

  /// 是否在任一档位获得过 3 星
  bool get hasAny3Star =>
      maxStars >= 3 || records.values.any((r) => r.bestStars >= 3);

  /// 跨所有难度的总游玩次数聚合
  int get totalPlayCount =>
      records.values.fold<int>(0, (sum, r) => sum + r.playCount);

  /// 已通关难度档位数
  int get completedDifficultyCount =>
      records.values.where((r) => r.isCompleted).length;

  /// 所有难度对应的最高星级映射
  Map<String, int> get allDifficultyStars =>
      records.map((k, v) => MapEntry(k, v.bestStars));

  /// 战绩最佳的难度键（最高星级对应难度）
  String get bestDifficultyKey {
    if (records.isEmpty) return '';
    var bestKey = '';
    var bestStars = -1;
    for (final e in records.entries) {
      if (e.value.bestStars > bestStars) {
        bestStars = e.value.bestStars;
        bestKey = e.key;
      }
    }
    return bestKey;
  }

  LevelProgress copyWith({
    String? canonicalId,
    int? progressPercent,
    bool? isCompleted,
    List<int>? completedPieceCounts,
    int? bestTimeSeconds,
    int? stars,
    bool? hasSnapshot,
    String? activeDifficultyKey,
    List<String>? snapshotKeys,
    Map<String, DifficultyRecord>? records,
    DateTime? lastSavedAt,
    DateTime? firstCompletedAt,
    DateTime? lastCompletedAt,
    DateTime? firstPlayedAt,
    Map<String, dynamic>? extra,
  }) {
    return LevelProgress(
      canonicalId: canonicalId ?? this.canonicalId,
      progressPercent: progressPercent ?? this.progressPercent,
      isCompleted: isCompleted ?? this.isCompleted,
      completedPieceCounts: completedPieceCounts ?? this.completedPieceCounts,
      bestTimeSeconds: bestTimeSeconds ?? this.bestTimeSeconds,
      stars: stars ?? this.stars,
      hasSnapshot: hasSnapshot ?? this.hasSnapshot,
      activeDifficultyKey: activeDifficultyKey ?? this.activeDifficultyKey,
      snapshotKeys: snapshotKeys ?? this.snapshotKeys,
      records: records ?? this.records,
      lastSavedAt: lastSavedAt ?? this.lastSavedAt,
      firstCompletedAt: firstCompletedAt ?? this.firstCompletedAt,
      lastCompletedAt: lastCompletedAt ?? this.lastCompletedAt,
      firstPlayedAt: firstPlayedAt ?? this.firstPlayedAt,
      extra: extra ?? this.extra,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'canonicalId': canonicalId,
      'progressPercent': progressPercent,
      'isCompleted': isCompleted,
      'completedPieceCounts': completedPieceCounts,
      'bestTimeSeconds': bestTimeSeconds,
      'stars': stars,
      'hasSnapshot': hasSnapshot,
      'activeDifficultyKey': activeDifficultyKey,
      'snapshotKeys': snapshotKeys,
    };
    if (records.isNotEmpty) {
      m['records'] = records.map((k, v) => MapEntry(k, v.toJson()));
    }
    if (lastSavedAt != null) m['lastSavedAt'] = lastSavedAt!.toIso8601String();
    if (firstCompletedAt != null) {
      m['firstCompletedAt'] = firstCompletedAt!.toIso8601String();
    }
    if (lastCompletedAt != null) {
      m['lastCompletedAt'] = lastCompletedAt!.toIso8601String();
    }
    if (firstPlayedAt != null) {
      m['firstPlayedAt'] = firstPlayedAt!.toIso8601String();
    }
    extra.forEach((k, v) {
      if (!m.containsKey(k)) m[k] = v;
    });
    return m;
  }

  factory LevelProgress.fromJson(Map<String, dynamic> json) {
    const known = {
      'canonicalId',
      'progressPercent',
      'isCompleted',
      'completedPieceCounts',
      'bestTimeSeconds',
      'stars',
      'hasSnapshot',
      'activeDifficultyKey',
      'snapshotKeys',
      'records',
      'lastSavedAt',
      'firstCompletedAt',
      'lastCompletedAt',
      'firstPlayedAt',
    };
    final extra = <String, dynamic>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) extra[e.key] = e.value;
    }

    final rawRecords = json['records'] as Map<String, dynamic>?;
    final parsedRecords = <String, DifficultyRecord>{};
    if (rawRecords != null) {
      for (final e in rawRecords.entries) {
        if (e.value is Map<String, dynamic>) {
          parsedRecords[e.key] = DifficultyRecord.fromJson(
            e.value as Map<String, dynamic>,
          );
        }
      }
    }

    return LevelProgress(
      canonicalId: json['canonicalId'] as String? ?? '',
      progressPercent: (json['progressPercent'] as int?) ?? 0,
      isCompleted: (json['isCompleted'] as bool?) ?? false,
      completedPieceCounts:
          (json['completedPieceCounts'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toList() ??
          const [],
      bestTimeSeconds: (json['bestTimeSeconds'] as int?) ?? 0,
      stars: (json['stars'] as int?) ?? 0,
      hasSnapshot: (json['hasSnapshot'] as bool?) ?? false,
      activeDifficultyKey: (json['activeDifficultyKey'] as String?) ?? '',
      snapshotKeys:
          (json['snapshotKeys'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      records: parsedRecords,
      lastSavedAt: json['lastSavedAt'] != null
          ? DateTime.tryParse(json['lastSavedAt'] as String)
          : null,
      firstCompletedAt: json['firstCompletedAt'] != null
          ? DateTime.tryParse(json['firstCompletedAt'] as String)
          : null,
      lastCompletedAt: json['lastCompletedAt'] != null
          ? DateTime.tryParse(json['lastCompletedAt'] as String)
          : null,
      firstPlayedAt: json['firstPlayedAt'] != null
          ? DateTime.tryParse(json['firstPlayedAt'] as String)
          : null,
      extra: extra,
    );
  }

  /// 供 UI 判断是否显示“继续”
  bool get canResume => hasSnapshot && !isCompleted;
}
