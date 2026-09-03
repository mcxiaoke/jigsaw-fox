import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive_ce.dart';

import 'app_logger.dart';
import '../data/storage_manager.dart';

/// 成就系统持久化存储（内存缓存 + 异步后台落盘）
///
/// 存储迁移（§2.2 / §3.3 / §4.3）：原 4 个 成就 prefs key prefs key
/// 拆为 app-state-v1 的 `ach:*` 原生类型单条（counter=int、unlock=String(ISO)、
/// claimed/starred=bool）。init() 一次性前缀扫描装满 4 个内存缓存。
///
/// **key 解析规则（§4.3）**：`ach:*` 的 key 含多段冒号（如
/// `ach:starred:main:002`），**禁止任何 split(':') 方案**——一律用显式前缀
/// 匹配 + substring 取剩余整体，天然支持含冒号的 cid。
class AchievementStore {
  AchievementStore._();
  static final AchievementStore instance = AchievementStore._();

  static const String _prefixCounter = 'ach:counter:';
  static const String _prefixUnlock = 'ach:unlock:';
  static const String _prefixClaimed = 'ach:claimed:';
  static const String _prefixStarred = 'ach:starred:';

  bool _initialized = false;

  // 100% 纯内存缓存，避免频繁解码与 I/O
  final Map<String, int> _countersCache = {};
  final Map<String, String> _unlockedCache = {};
  final Set<String> _claimedCache = {};
  final Set<String> _starredCache = {}; // 已计 3 星的 canonicalId 集合（设计 §8.3 去重）

  Box<dynamic> get _box => StorageManager.instance.state;

  Future<void> init() async {
    if (_initialized) return;
    _countersCache.clear();
    _unlockedCache.clear();
    _claimedCache.clear();
    _starredCache.clear();

    // 一次性前缀扫描（§3.3 例外 / §4.3）：先收集 key 再逐个读，不在迭代中写
    final keys = _box.keys.cast<String>().toList();
    for (final key in keys) {
      // 显式前缀匹配：substring 取剩余整体作为 id/cid/metric
      if (key.startsWith(_prefixCounter)) {
        final metric = key.substring(_prefixCounter.length);
        _countersCache[metric] = _box.get(key) as int? ?? 0;
      } else if (key.startsWith(_prefixUnlock)) {
        final id = key.substring(_prefixUnlock.length);
        final v = _box.get(key) as String?;
        if (v != null) _unlockedCache[id] = v;
      } else if (key.startsWith(_prefixClaimed)) {
        if (_box.get(key) == true) {
          _claimedCache.add(key.substring(_prefixClaimed.length));
        }
      } else if (key.startsWith(_prefixStarred)) {
        if (_box.get(key) == true) {
          _starredCache.add(key.substring(_prefixStarred.length));
        }
      }
    }

    _initialized = true;
  }

  /// 测试专用：强制重新前缀扫描（模拟冷启动，§10.3 成就缓存加载用例）
  @visibleForTesting
  Future<void> reloadForTest() async {
    _initialized = false;
    await init();
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
    unawaited(_putCounter(metricKey, next));
    return next;
  }

  /// 设置计数器绝对值并异步后台持久化
  Future<void> setCounter(String metricKey, int value) async {
    if (!_initialized) await init();
    _countersCache[metricKey] = value;
    unawaited(_putCounter(metricKey, value));
  }

  /// 判断某成就是否已解锁（O(1) 纯内存）
  bool isUnlocked(String achievementId) {
    return _unlockedCache.containsKey(achievementId);
  }

  /// 标记成就解锁（纯内存更新 + 异步后台持久化）
  Future<bool> markUnlocked(String achievementId) async {
    if (!_initialized) await init();
    if (_unlockedCache.containsKey(achievementId)) return false;
    final iso = DateTime.now().toIso8601String();
    _unlockedCache[achievementId] = iso;
    unawaited(_putUnlock(achievementId, iso));
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
    unawaited(_putClaimed(achievementId));
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
    unawaited(_putStarred(canonicalId));
    return true;
  }

  /// 已计 3 星的不同图数量（账号资产口径）
  int get starredPuzzleCount => _starredCache.length;

  /// 获取全部已解锁的成就 ID 列表
  List<String> getUnlockedAchievementIds() {
    return _unlockedCache.keys.toList();
  }

  // --- 单条落盘（原整 JSON Map / StringList 全量重写已被逐条 put 取代） ---

  Future<void> _putCounter(String metricKey, int value) async {
    try {
      await _box.put('$_prefixCounter$metricKey', value);
    } catch (_) {}
  }

  Future<void> _putUnlock(String achievementId, String iso) async {
    try {
      await _box.put('$_prefixUnlock$achievementId', iso);
    } catch (_) {}
  }

  Future<void> _putClaimed(String achievementId) async {
    try {
      await _box.put('$_prefixClaimed$achievementId', true);
    } catch (_) {}
  }

  Future<void> _putStarred(String canonicalId) async {
    try {
      await _box.put('$_prefixStarred$canonicalId', true);
    } catch (_) {}
  }

  /// 重置（§7.6 步骤 4，本次新建）：清 4 个内存缓存 + 删除 box 中 ach:* 条目
  /// （先收集后批量删，§5.4）
  Future<void> reset() async {
    _countersCache.clear();
    _unlockedCache.clear();
    _claimedCache.clear();
    _starredCache.clear();
    _initialized = true;
    try {
      final keys = _box.keys
          .cast<String>()
          .where(
            (k) =>
                k.startsWith(_prefixCounter) ||
                k.startsWith(_prefixUnlock) ||
                k.startsWith(_prefixClaimed) ||
                k.startsWith(_prefixStarred),
          )
          .toList();
      for (final key in keys) {
        try {
          await _box.delete(key);
        } catch (_) {}
      }
    } catch (e, st) {
      AppLogger.repo.warning(
        'AchievementStore.reset box cleanup failed',
        e,
        st,
      );
    }
    AppLogger.repo.info('AchievementStore.reset done');
  }
}
