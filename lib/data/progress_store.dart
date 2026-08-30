import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_logger.dart';
import 'snapshot_store.dart';

/// 轻量进度索引（按 canonicalId 单条 SharedPreferences JSON）
///
/// 与重型快照文件（SnapshotStore）分离，列表页无需读大文件即可展示
/// 进度、星级、最佳用时与“是否有存档”标记。
/// 设计上对新增字段前瞻兼容：fromJson 忽略未知键，toJson 透传 extra。
class ProgressStore {
  ProgressStore._();
  static final ProgressStore instance = ProgressStore._();

  static const String _keyPrefix = 'jigsaw_progress_v3_';
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
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
  }) async {
    final cur = await load(canonicalId);
    final updatedCounts = Set<int>.from(cur.completedPieceCounts);
    if (isCompleted == true && completedPieceCount != null) {
      updatedCounts.add(completedPieceCount);
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
      lastSavedAt: DateTime.now(),
    );
    await save(next);
    AppLogger.repo.fine('ProgressStore.update cid=$canonicalId p=$progressPercent completed=$isCompleted stars=$stars time=$bestTimeSeconds dkey=$activeDifficultyKey hasSnap=$hasSnapshot');
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
  final DateTime? lastSavedAt;
  final Map<String, dynamic> extra;

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
      'lastSavedAt',
    };
    final extra = <String, dynamic>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) extra[e.key] = e.value;
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
      lastSavedAt: json['lastSavedAt'] != null
          ? DateTime.tryParse(json['lastSavedAt'] as String)
          : null,
      extra: extra,
    );
  }

  /// 供 UI 判断是否显示“继续”
  bool get canResume => hasSnapshot && !isCompleted;
}
