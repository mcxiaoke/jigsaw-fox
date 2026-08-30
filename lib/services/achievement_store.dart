import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// 成就系统持久化存储（SharedPreferences JSON）
class AchievementStore {
  AchievementStore._();
  static final AchievementStore instance = AchievementStore._();

  static const String _keyCounters = 'jigsaw_achievement_counters';
  static const String _keyUnlocked = 'jigsaw_achievement_unlocked';
  static const String _keyClaimed = 'jigsaw_achievement_claimed';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  /// 获取计数器值
  int getCounter(String metricKey) {
    final raw = _prefs?.getString(_keyCounters);
    if (raw == null) return 0;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return (map[metricKey] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 累加计数器并持久化
  Future<int> incrementCounter(String metricKey, [int delta = 1]) async {
    await init();
    final raw = _prefs?.getString(_keyCounters);
    final map = <String, dynamic>{};
    if (raw != null) {
      try {
        map.addAll(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    final cur = (map[metricKey] as int?) ?? 0;
    final next = cur + delta;
    map[metricKey] = next;
    await _prefs?.setString(_keyCounters, jsonEncode(map));
    return next;
  }

  /// 设置计数器绝对值（如连续打卡天数或最大值）
  Future<void> setCounter(String metricKey, int value) async {
    await init();
    final raw = _prefs?.getString(_keyCounters);
    final map = <String, dynamic>{};
    if (raw != null) {
      try {
        map.addAll(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    map[metricKey] = value;
    await _prefs?.setString(_keyCounters, jsonEncode(map));
  }

  /// 判断某成就是否已解锁
  bool isUnlocked(String achievementId) {
    final raw = _prefs?.getString(_keyUnlocked);
    if (raw == null) return false;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.containsKey(achievementId);
    } catch (_) {
      return false;
    }
  }

  /// 标记成就解锁（写入解锁时间戳）
  Future<bool> markUnlocked(String achievementId) async {
    await init();
    if (isUnlocked(achievementId)) return false;
    final raw = _prefs?.getString(_keyUnlocked);
    final map = <String, dynamic>{};
    if (raw != null) {
      try {
        map.addAll(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    map[achievementId] = DateTime.now().toIso8601String();
    await _prefs?.setString(_keyUnlocked, jsonEncode(map));
    AppLogger.repo.info('AchievementStore: unlocked achievement ');
    return true;
  }

  /// 判断奖励是否已领取
  bool isClaimed(String achievementId) {
    final list = _prefs?.getStringList(_keyClaimed) ?? [];
    return list.contains(achievementId);
  }

  /// 标记奖励已领取
  Future<void> markClaimed(String achievementId) async {
    await init();
    final set = Set<String>.from(_prefs?.getStringList(_keyClaimed) ?? []);
    set.add(achievementId);
    await _prefs?.setStringList(_keyClaimed, set.toList());
  }

  /// 获取全部已解锁的成就 ID 列表
  List<String> getUnlockedAchievementIds() {
    final raw = _prefs?.getString(_keyUnlocked);
    if (raw == null) return const [];
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.keys.toList();
    } catch (_) {
      return const [];
    }
  }
}
