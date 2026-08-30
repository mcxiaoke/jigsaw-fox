import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_logger.dart';
import 'snapshot_store.dart';

/// 单档位通关记录（v3.3.1 设计）
class DifficultyRecord {
  const DifficultyRecord({
    this.bestStars = 0,
    this.bestTimeSeconds = 0,
    this.isCompleted = false,
    this.playCount = 0,
    this.minHintsUsed = -1,
    this.extra = const {},
  });

  final int bestStars;
  final int bestTimeSeconds;
  final bool isCompleted;
  final int playCount;
  final int minHintsUsed; // 历史最少提示次数（初始 -1）
  final Map<String, dynamic> extra;

  DifficultyRecord copyWith({
    int? bestStars,
    int? bestTimeSeconds,
    bool? isCompleted,
    int? playCount,
    int? minHintsUsed,
    Map<String, dynamic>? extra,
  }) {
    return DifficultyRecord(
      bestStars: bestStars ?? this.bestStars,
      bestTimeSeconds: bestTimeSeconds ?? this.bestTimeSeconds,
      isCompleted: isCompleted ?? this.isCompleted,
      playCount: playCount ?? this.playCount,
      minHintsUsed: minHintsUsed ?? this.minHintsUsed,
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
    extra.forEach((k, v) {
      if (!m.containsKey(k)) m[k] = v;
    });
    return m;
  }

  factory DifficultyRecord.fromJson(Map<String, dynamic> json) {
    const known = {'bestStars', 'bestTimeSeconds', 'isCompleted', 'playCount', 'minHintsUsed'};
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

/// 轻量进度索引（按 canonicalId 单条 SharedPreferences JSON）
///
/// 与重型快照文件（SnapshotStore）分离，列表页无需读大文件即可展示
/// 进度、星级、最佳用时与“是否有存档”标记。
/// 支持嵌套档位记录 `Map<difficultyKey, DifficultyRecord>`，避免 N+1 查询。
class ProgressStore {
  ProgressStore._();
  static final ProgressStore instance = ProgressStore._();

  static const String _keyPrefix = 'jigsaw_progress_v3_';
  SharedPreferences? _prefs;
  int _cachedDistinct3Star = 0;
  int get cachedDistinct3StarCount => _cachedDistinct3Star;

  Future<void> init() async {
    if (_prefs != null) return;
    _prefs = await SharedPreferences.getInstance();
    await refreshAggregatesCache();
  }

  Future<void> refreshAggregatesCache() async {
    final keys = _prefs?.getKeys() ?? const {};
    var count = 0;
    for (final k in keys) {
      if (k.startsWith(_keyPrefix)) {
        final raw = _prefs?.getString(k);
        if (raw != null) {
          try {
            final m = jsonDecode(raw) as Map<String, dynamic>;
            final p = LevelProgress.fromJson(m);
            if (p.hasAny3Star) count++;
          } catch (_) {}
        }
      }
    }
    _cachedDistinct3Star = count;
  }

  String _keyFor(String canonicalId) {
    final safe = canonicalId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return '$_keyPrefix$safe';
  }

  Future<LevelProgress> load(String canonicalId) async {
    await init();
    final str = _prefs?.getString(_keyFor(canonicalId));
    if (str == null) return LevelProgress(canonicalId: canonicalId);
    try {
      final map = jsonDecode(str) as Map<String, dynamic>;
      return LevelProgress.fromJson(map);
    } catch (e, st) {
      AppLogger.repo.warning('ProgressStore.load parse fail cid=$canonicalId', e, st);
      return LevelProgress(canonicalId: canonicalId);
    }
  }

  Future<void> save(LevelProgress p) async {
    await init();
    try {
      await _prefs?.setString(_keyFor(p.canonicalId), jsonEncode(p.toJson()));
    } catch (e, st) {
      AppLogger.repo.warning('ProgressStore.save fail cid=${p.canonicalId}', e, st);
    }
  }

  /// 获取全部已存储的 canonicalId 列表
  Future<List<String>> listAllCanonicalIds() async {
    await init();
    final keys = _prefs?.getKeys() ?? <String>{};
    final list = <String>[];
    for (final k in keys) {
      if (k.startsWith(_keyPrefix)) {
        final raw = _prefs?.getString(k);
        if (raw != null) {
          try {
            final m = jsonDecode(raw) as Map<String, dynamic>;
            final cid = m['canonicalId'] as String?;
            if (cid != null && cid.isNotEmpty) {
              list.add(cid);
            }
          } catch (_) {}
        }
      }
    }
    return list;
  }

  /// 账号资产：获得 3 星的不同图数量（任一档位拿过 3 星即计入，按 canonicalId 去重）
  Future<int> getDistinctImagesWith3Star() async {
    final cids = await listAllCanonicalIds();
    var count = 0;
    for (final cid in cids) {
      final p = await load(cid);
      if (p.hasAny3Star) {
        count++;
      }
    }
    return count;
  }

  /// 账号资产：所有 canonicalId × 所有档位 bestStars 求和
  Future<int> getTotalStars() async {
    final cids = await listAllCanonicalIds();
    var sum = 0;
    for (final cid in cids) {
      final p = await load(cid);
      if (p.records.isNotEmpty) {
        for (final r in p.records.values) {
          sum += r.bestStars;
        }
      } else {
        sum += p.stars;
      }
    }
    return sum;
  }

  /// 账号资产：累计已通关的不同图数量或局数
  Future<int> getTotalSolved() async {
    final cids = await listAllCanonicalIds();
    var count = 0;
    for (final cid in cids) {
      final p = await load(cid);
      if (p.isCompleted || p.records.values.any((r) => r.isCompleted)) {
        count++;
      }
    }
    return count;
  }

  /// 记录单图单档位的通关成绩，原子更新嵌套 records 并维护 minHintsUsed 状态机
  Future<DifficultyRecordUpdateResult> recordDifficultyCompletion({
    required String canonicalId,
    required String difficultyKey,
    required int stars,
    required int timeSeconds,
    required int hintsUsed,
    int? completedPieceCount,
  }) async {
    final cur = await load(canonicalId);
    final existingMap = Map<String, DifficultyRecord>.from(cur.records);
    final oldRecord = existingMap[difficultyKey] ?? const DifficultyRecord();

    final isNewBestStars = stars > oldRecord.bestStars;
    final deltaStars = isNewBestStars ? (stars - oldRecord.bestStars) : 0;
    final newBestStars = math.max(oldRecord.bestStars, stars);

    final newBestTime = oldRecord.bestTimeSeconds == 0
        ? timeSeconds
        : (timeSeconds > 0 ? math.min(oldRecord.bestTimeSeconds, timeSeconds) : oldRecord.bestTimeSeconds);

    // minHintsUsed 状态机：初始 -1；取更小值；首次变为 0 时触发 isFirstNoHintWin
    final isFirstNoHintWin = hintsUsed == 0 && (oldRecord.minHintsUsed == -1 || oldRecord.minHintsUsed > 0);
    final newMinHints = oldRecord.minHintsUsed == -1
        ? hintsUsed
        : math.min(oldRecord.minHintsUsed, hintsUsed);

    final updatedRecord = oldRecord.copyWith(
      bestStars: newBestStars,
      bestTimeSeconds: newBestTime,
      isCompleted: true,
      playCount: oldRecord.playCount + 1,
      minHintsUsed: newMinHints,
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
      bestTimeSeconds: cur.bestTimeSeconds == 0 ? newBestTime : math.min(cur.bestTimeSeconds, newBestTime),
      hasSnapshot: false,
      lastSavedAt: DateTime.now(),
    );
    await save(next);

    // 结算后刷新 3 星图数缓存，避免解锁面板首帧读到旧值（dsf P2-1）
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

    // 同步更新 records 字典（若指定了 activeDifficultyKey 且已通关）
    var nextRecords = records ?? Map<String, DifficultyRecord>.from(cur.records);
    if (isCompleted == true && activeDifficultyKey != null && activeDifficultyKey.isNotEmpty) {
      final oldR = nextRecords[activeDifficultyKey] ?? const DifficultyRecord();
      final newStars = math.max(oldR.bestStars, stars ?? 0);
      final newTime = oldR.bestTimeSeconds == 0
          ? (bestTimeSeconds ?? 0)
          : ((bestTimeSeconds ?? 0) > 0 ? math.min(oldR.bestTimeSeconds, bestTimeSeconds!) : oldR.bestTimeSeconds);
      nextRecords[activeDifficultyKey] = oldR.copyWith(
        bestStars: newStars,
        bestTimeSeconds: newTime,
        isCompleted: true,
      );
    }

    final next = cur.copyWith(
      progressPercent: progressPercent ?? cur.progressPercent,
      isCompleted: isCompleted ?? cur.isCompleted,
      completedPieceCounts: updatedCounts.toList(),
      stars: stars ?? cur.stars,
      bestTimeSeconds: bestTimeSeconds ?? cur.bestTimeSeconds,
      activeDifficultyKey: activeDifficultyKey ?? cur.activeDifficultyKey,
      snapshotKeys: snapshotKeys ?? cur.snapshotKeys,
      hasSnapshot: hasSnapshot ?? cur.hasSnapshot,
      records: nextRecords,
      lastSavedAt: DateTime.now(),
    );
    await save(next);
    AppLogger.repo.fine(
      'ProgressStore.update cid=$canonicalId p=$progressPercent completed=$isCompleted stars=$stars time=$bestTimeSeconds dkey=$activeDifficultyKey hasSnap=$hasSnapshot records=${nextRecords.length}',
    );
  }

  Future<void> setHasSnapshot(String canonicalId, String difficultyKey, bool has) async {
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
      activeDifficultyKey: has ? difficultyKey : (keys.isNotEmpty ? keys.first : cur.activeDifficultyKey),
    );
    await save(next);
  }

  Future<void> clearSnapshot(String canonicalId, String difficultyKey) async {
    await setHasSnapshot(canonicalId, difficultyKey, false);
    final cur = await load(canonicalId);
    // 若该难度是 active，则尝试切换到剩余的第一个
    if (cur.activeDifficultyKey == difficultyKey) {
      final remaining = cur.snapshotKeys.where((k) => k != difficultyKey).toList();
      final nextActive = remaining.isNotEmpty ? remaining.first : '';
      await save(cur.copyWith(activeDifficultyKey: nextActive, hasSnapshot: remaining.isNotEmpty));
    }
  }

  Future<void> clearAllSnapshots(String canonicalId) async {
    final cur = await load(canonicalId);
    await save(cur.copyWith(hasSnapshot: false, snapshotKeys: const [], activeDifficultyKey: ''));
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
    if (cur.hasSnapshot != has || (has && !keys.contains(cur.activeDifficultyKey))) {
      final nextActive = has
          ? (keys.contains(cur.activeDifficultyKey) ? cur.activeDifficultyKey : keys.first)
          : '';
      await save(cur.copyWith(
        hasSnapshot: has,
        snapshotKeys: keys,
        activeDifficultyKey: nextActive,
      ));
      AppLogger.repo.info('ProgressStore.reconcile cid=$canonicalId has=$has keys=$keys active=$nextActive');
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
  final Map<String, dynamic> extra;

  /// 单图最高星级
  int get maxStars {
    var m = stars;
    for (final r in records.values) {
      if (r.bestStars > m) m = r.bestStars;
    }
    return m;
  }

  /// 是否在任一档位获得过 3 星
  bool get hasAny3Star => maxStars >= 3 || records.values.any((r) => r.bestStars >= 3);

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
          parsedRecords[e.key] = DifficultyRecord.fromJson(e.value as Map<String, dynamic>);
        }
      }
    }

    return LevelProgress(
      canonicalId: json['canonicalId'] as String? ?? '',
      progressPercent: (json['progressPercent'] as int?) ?? 0,
      isCompleted: (json['isCompleted'] as bool?) ?? false,
      completedPieceCounts: (json['completedPieceCounts'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toList() ??
          const [],
      bestTimeSeconds: (json['bestTimeSeconds'] as int?) ?? 0,
      stars: (json['stars'] as int?) ?? 0,
      hasSnapshot: (json['hasSnapshot'] as bool?) ?? false,
      activeDifficultyKey: (json['activeDifficultyKey'] as String?) ?? '',
      snapshotKeys: (json['snapshotKeys'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      records: parsedRecords,
      lastSavedAt: json['lastSavedAt'] != null
          ? DateTime.tryParse(json['lastSavedAt'] as String)
          : null,
      extra: extra,
    );
  }

  /// 供 UI 判断是否显示“继续”
  bool get canResume => hasSnapshot && !isCompleted;
}
