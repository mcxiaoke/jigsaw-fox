import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// 成就系统持久化存储（内存缓存 + 异步后台落盘）
class AchievementStore {
  AchievementStore._();
  static final AchievementStore instance = AchievementStore._();

  static const String _keyCounters = 'jigsaw_achievement_counters';
  static const String _keyUnlocked = 'jigsaw_achievement_unlocked';
  static const String _keyClaimed = 'jigsaw_achievement_claimed';
  static const String _keyStarred = 'jigsaw_achievement_starred_puzzles';

  SharedPreferences? _prefs;
  bool _initialized = false;

  // 100% 纯内存缓存，避免频繁 jsonDecode 与 I/O
  final Map<String, int> _countersCache = {};
  final Map<String, String> _unlockedCache = {};
  final Set<String> _claimedCache = {};
  final Set<String> _starredCache = {}; // 已计 3 星的 canonicalId 集合（设计 §8.3 去重）

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _countersCache.clear();
    _unlockedCache.clear();
    _claimedCache.clear();
    _starredCache.clear();

    // 1. Counters
    final rawCounters = _prefs?.getString(_keyCounters);
    if (rawCounters != null) {
      try {
        final map = jsonDecode(rawCounters) as Map<String, dynamic>;
        map.forEach((k, v) {
          if (v is int) _countersCache[k] = v;
        });
      } catch (_) {}
    }

    // 2. Unlocked
    final rawUnlocked = _prefs?.getString(_keyUnlocked);
    if (rawUnlocked != null) {
      try {
        final map = jsonDecode(rawUnlocked) as Map<String, dynamic>;
        map.forEach((k, v) {
          if (v != null) _unlockedCache[k] = v.toString();
        });
      } catch (_) {}
    }

    // 3. Claimed
    final list = _prefs?.getStringList(_keyClaimed) ?? [];
    _claimedCache.addAll(list);

    // 4. Starred puzzles（threeStar 按 canonicalId 去重）
    final starred = _prefs?.getStringList(_keyStarred) ?? [];
    _starredCache.addAll(starred);

    _initialized = true;
  }

  /// 获取计数器值（O(1) 纯内存）
  int getCounter(String metricKey) {
    return _countersCache[metricKey] ?? 0;
  }

  /// 累加计数器并异步后台持久化
  Future<int> incrementCounter(String metricKey, [int delta = 1]) async {
    if (!_initialized) await init();
    final cur = _countersCache[metricKey] ?? 0;
    final next = cur + delta;
    _countersCache[metricKey] = next;
    unawaited(_flushCounters());
    return next;
  }

  /// 设置计数器绝对值并异步后台持久化
  Future<void> setCounter(String metricKey, int value) async {
    if (!_initialized) await init();
    _countersCache[metricKey] = value;
    unawaited(_flushCounters());
  }

  /// 判断某成就是否已解锁（O(1) 纯内存）
  bool isUnlocked(String achievementId) {
    return _unlockedCache.containsKey(achievementId);
  }

  /// 标记成就解锁（纯内存更新 + 异步后台持久化）
  Future<bool> markUnlocked(String achievementId) async {
    if (!_initialized) await init();
    if (_unlockedCache.containsKey(achievementId)) return false;
    _unlockedCache[achievementId] = DateTime.now().toIso8601String();
    unawaited(_flushUnlocked());
    AppLogger.repo.info(
      'AchievementStore: unlocked achievement $achievementId',
    );
    return true;
  }

  /// 判断奖励是否已领取（O(1) 纯内存）
  bool isClaimed(String achievementId) {
    return _claimedCache.contains(achievementId);
  }

  /// 标记奖励已领取
  Future<void> markClaimed(String achievementId) async {
    if (!_initialized) await init();
    _claimedCache.add(achievementId);
    unawaited(_flushClaimed());
  }

  /// 是否已计过 3 星（按 canonicalId 去重，设计 §8.3）
  bool hasStarred(String canonicalId) {
    return _starredCache.contains(canonicalId);
  }

  /// 记录一张新图获得 3 星（去重）：若已存在返回 false 不重复计
  Future<bool> addStarred(String canonicalId) async {
    if (!_initialized) await init();
    if (_starredCache.contains(canonicalId)) return false;
    _starredCache.add(canonicalId);
    unawaited(_flushStarred());
    return true;
  }

  /// 已计 3 星的不同图数量（账号资产口径）
  int get starredPuzzleCount => _starredCache.length;

  Future<void> _flushStarred() async {
    try {
      await _prefs?.setStringList(_keyStarred, _starredCache.toList());
    } catch (_) {}
  }

  Future<void> _flushClaimed() async {
    try {
      await _prefs?.setStringList(_keyClaimed, _claimedCache.toList());
    } catch (_) {}
  }

  /// 获取全部已解锁的成就 ID 列表
  List<String> getUnlockedAchievementIds() {
    return _unlockedCache.keys.toList();
  }

  Future<void> _flushCounters() async {
    try {
      await _prefs?.setString(_keyCounters, jsonEncode(_countersCache));
    } catch (_) {}
  }

  Future<void> _flushUnlocked() async {
    try {
      await _prefs?.setString(_keyUnlocked, jsonEncode(_unlockedCache));
    } catch (_) {}
  }
}
