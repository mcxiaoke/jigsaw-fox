import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive_ce.dart';

import '../services/app_logger.dart';
import 'storage_manager.dart';

/// 单条收藏条目模型（支持源被删后的孤儿卡优雅兜底展示）
class FavoriteEntry {
  const FavoriteEntry({
    required this.canonicalId,
    required this.favoritedAt,
    this.titleSnapshot,
    this.imageSnapshot,
    this.sourceLabelSnapshot = '主线',
    this.isLocalFileSnapshot = false,
    this.aspectRatioLabel = 'square1x1',
    this.author,
    this.tags = const [],
    this.preferredDifficultyKey,
    this.sortOrder = 0,
    this.extra = const {},
  });

  /// 全局规范主键 (如 "main:001", "daily:20260902", "ugc:1787548651000")
  final String canonicalId;

  /// 收藏时间（收藏子 Tab 默认倒序排序主键）
  final DateTime favoritedAt;

  /// 标题快照（源被删除/离线时兜底展示）
  final String? titleSnapshot;

  /// 缩略图路径/URL 快照
  final String? imageSnapshot;

  /// 来源标签快照（如 "主线" / "每日" / "活动" / "扩展包" / "自制"）
  final String sourceLabelSnapshot;

  /// 资源是否为本地文件快照（决定走 FileImage 还是 AssetImage/网络图）
  final bool isLocalFileSnapshot;

  /// 宽高比标签快照（如 "square1x1" / "portrait2x3" / "landscape3x2"，防止孤儿卡布局拉伸错位）
  final String aspectRatioLabel;

  /// 创作者/出处署名
  final String? author;

  /// 标签列表（预留筛选）
  final List<String> tags;

  /// 收藏时选中的偏好难度键
  final String? preferredDifficultyKey;

  /// 用户自定义排序权重（预留拖拽置顶）
  final int sortOrder;

  /// 未知扩展字段透传字典
  final Map<String, dynamic> extra;

  FavoriteEntry copyWith({
    String? canonicalId,
    DateTime? favoritedAt,
    String? titleSnapshot,
    String? imageSnapshot,
    String? sourceLabelSnapshot,
    bool? isLocalFileSnapshot,
    String? aspectRatioLabel,
    String? author,
    List<String>? tags,
    String? preferredDifficultyKey,
    int? sortOrder,
    Map<String, dynamic>? extra,
  }) {
    return FavoriteEntry(
      canonicalId: canonicalId ?? this.canonicalId,
      favoritedAt: favoritedAt ?? this.favoritedAt,
      titleSnapshot: titleSnapshot ?? this.titleSnapshot,
      imageSnapshot: imageSnapshot ?? this.imageSnapshot,
      sourceLabelSnapshot: sourceLabelSnapshot ?? this.sourceLabelSnapshot,
      isLocalFileSnapshot: isLocalFileSnapshot ?? this.isLocalFileSnapshot,
      aspectRatioLabel: aspectRatioLabel ?? this.aspectRatioLabel,
      author: author ?? this.author,
      tags: tags ?? this.tags,
      preferredDifficultyKey:
          preferredDifficultyKey ?? this.preferredDifficultyKey,
      sortOrder: sortOrder ?? this.sortOrder,
      extra: extra ?? this.extra,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'canonicalId': canonicalId,
      'favoritedAt': favoritedAt.toIso8601String(),
      'sourceLabelSnapshot': sourceLabelSnapshot,
      'isLocalFileSnapshot': isLocalFileSnapshot,
      'aspectRatioLabel': aspectRatioLabel,
      'sortOrder': sortOrder,
    };
    if (titleSnapshot != null) m['titleSnapshot'] = titleSnapshot;
    if (imageSnapshot != null) m['imageSnapshot'] = imageSnapshot;
    if (author != null) m['author'] = author;
    if (tags.isNotEmpty) m['tags'] = tags;
    if (preferredDifficultyKey != null) {
      m['preferredDifficultyKey'] = preferredDifficultyKey;
    }
    extra.forEach((k, v) {
      if (!m.containsKey(k)) m[k] = v;
    });
    return m;
  }

  factory FavoriteEntry.fromJson(Map<String, dynamic> json) {
    const known = {
      'canonicalId',
      'favoritedAt',
      'titleSnapshot',
      'imageSnapshot',
      'sourceLabelSnapshot',
      'isLocalFileSnapshot',
      'aspectRatioLabel',
      'author',
      'tags',
      'preferredDifficultyKey',
      'sortOrder',
    };
    final extra = <String, dynamic>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) extra[e.key] = e.value;
    }

    return FavoriteEntry(
      canonicalId: json['canonicalId'] as String? ?? '',
      favoritedAt: json['favoritedAt'] != null
          ? (DateTime.tryParse(json['favoritedAt'] as String) ?? DateTime.now())
          : DateTime.now(),
      titleSnapshot: json['titleSnapshot'] as String?,
      imageSnapshot: json['imageSnapshot'] as String?,
      sourceLabelSnapshot: json['sourceLabelSnapshot'] as String? ?? '主线',
      isLocalFileSnapshot: (json['isLocalFileSnapshot'] as bool?) ?? false,
      aspectRatioLabel: json['aspectRatioLabel'] as String? ?? 'square1x1',
      author: json['author'] as String?,
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
          const [],
      preferredDifficultyKey: json['preferredDifficultyKey'] as String?,
      sortOrder: (json['sortOrder'] as int?) ?? 0,
      extra: extra,
    );
  }
}

/// 收藏夹全局持久化管理单例
///
/// 存储迁移（设计 §2.2 / §3.3）：原 原收藏大 key 整 JSON 数组大 key
/// 改为 `game-collections-v1` 的 `favorite:{cid}` 逐条存储；init 时一次性前缀
/// 读入 `_entriesCache`，日常读走纯内存，写/删直接同步触发 Hive 单 key 操作。
class FavoriteStore {
  FavoriteStore._();
  static final FavoriteStore instance = FavoriteStore._();

  static const String _keyPrefix = 'favorite:';
  bool _initialized = false;
  final Map<String, FavoriteEntry> _entriesCache = {};

  /// 全局响应式 ID 集合通知器（供心形按钮和红心高亮监听）
  final ValueNotifier<Set<String>> idsNotifier = ValueNotifier<Set<String>>({});

  Box<dynamic> get _box => StorageManager.instance.collections;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    _entriesCache.clear();
    try {
      // 先收集后处理（§5.4：box.keys 迭代中不做写操作）
      final keys = _box.keys
          .cast<String>()
          .where((k) => k.startsWith(_keyPrefix))
          .toList();
      for (final key in keys) {
        final m = getJson(_box, key);
        if (m == null) continue;
        final entry = FavoriteEntry.fromJson(m);
        if (entry.canonicalId.isNotEmpty) {
          _entriesCache[entry.canonicalId] = entry;
        }
      }
    } catch (e, st) {
      AppLogger.repo.warning('FavoriteStore._loadFromDisk fail', e, st);
    }
    idsNotifier.value = Set.unmodifiable(_entriesCache.keys);
  }

  /// 单条落盘（整 JSON 数组全量重写已被逐条 put 取代）
  Future<void> _saveEntry(FavoriteEntry entry) async {
    try {
      await putJson(_box, '$_keyPrefix${entry.canonicalId}', entry.toJson());
    } catch (e, st) {
      AppLogger.repo.warning('FavoriteStore._saveEntry fail', e, st);
    }
  }

  /// 单条删除
  Future<void> _deleteEntry(String canonicalId) async {
    try {
      await _box.delete('$_keyPrefix$canonicalId');
    } catch (e, st) {
      AppLogger.repo.warning('FavoriteStore._deleteEntry fail', e, st);
    }
  }

  /// 内存同步读取当前所有已收藏 ID
  Set<String> get favoriteIds => Set.unmodifiable(_entriesCache.keys);

  /// 同步检查某拼图是否已收藏
  bool isFavorite(String canonicalId) => _entriesCache.containsKey(canonicalId);

  /// 切换收藏状态：若已收藏则取消；若未收藏则添加
  Future<bool> toggleFavorite(
    String canonicalId, {
    String? title,
    String? image,
    String? sourceLabel,
    bool? isLocalFile,
    String? aspectRatioLabel,
    String? author,
    List<String>? tags,
    String? preferredDifficultyKey,
  }) async {
    await init();
    final isFav = isFavorite(canonicalId);
    if (isFav) {
      _entriesCache.remove(canonicalId);
      await _deleteEntry(canonicalId);
    } else {
      final entry = FavoriteEntry(
        canonicalId: canonicalId,
        favoritedAt: DateTime.now(),
        titleSnapshot: title,
        imageSnapshot: image,
        sourceLabelSnapshot: sourceLabel ?? '主线',
        isLocalFileSnapshot: isLocalFile ?? false,
        aspectRatioLabel: aspectRatioLabel ?? 'square1x1',
        author: author,
        tags: tags ?? const [],
        preferredDifficultyKey: preferredDifficultyKey,
      );
      _entriesCache[canonicalId] = entry;
      await _saveEntry(entry);
    }
    idsNotifier.value = Set.unmodifiable(_entriesCache.keys);
    AppLogger.repo.info(
      'FavoriteStore.toggle cid=$canonicalId nextState=${!isFav} total=${_entriesCache.length}',
    );
    return !isFav;
  }

  /// 按收藏时间倒序返回全部收藏条目（sortOrder 作为次优先级权重，§3.3）
  Future<List<FavoriteEntry>> favoritesSortedByTime() async {
    await init();
    final list = _entriesCache.values.toList();
    list.sort((a, b) {
      final byTime = b.favoritedAt.compareTo(a.favoritedAt);
      if (byTime != 0) return byTime;
      return b.sortOrder.compareTo(a.sortOrder);
    });
    return list;
  }

  /// 移除单条收藏
  Future<void> remove(String canonicalId) async {
    await init();
    if (_entriesCache.remove(canonicalId) != null) {
      idsNotifier.value = Set.unmodifiable(_entriesCache.keys);
      await _deleteEntry(canonicalId);
    }
  }

  /// 清理孤儿收藏（可选维护工具）
  Future<void> pruneOrphans(Set<String> validCanonicalIds) async {
    await init();
    final before = _entriesCache.length;
    // 先收集后批量删（§5.4）
    final orphanIds = _entriesCache.keys
        .where((id) => !validCanonicalIds.contains(id))
        .toList();
    for (final id in orphanIds) {
      _entriesCache.remove(id);
      await _deleteEntry(id);
    }
    if (_entriesCache.length != before) {
      idsNotifier.value = Set.unmodifiable(_entriesCache.keys);
      AppLogger.repo.info(
        'FavoriteStore.pruneOrphans removed ${before - _entriesCache.length} entries',
      );
    }
  }

  /// 重置（§7.6 步骤 4，本次新建）：清内存缓存 + 通知器。
  ///
  /// **注意**：本方法只清内存，**不清 `game-collections-v1` 的 `favorite:*`
  /// 盘上条目**——正常调用方 `resetAllData()` 步骤 1 已 `collections.clear()`
  /// 先行清盘，二者配合无残留；若未来被脱离 `resetAllData()` 独立调用，
  /// 需自行先 `clear` box（可参照 `AchievementStore.reset()` 的
  /// 「先收集后批量删」实现），否则盘上会遗留孤儿 `favorite:` key。
  Future<void> reset() async {
    _entriesCache.clear();
    idsNotifier.value = const <String>{};
    _initialized = false;
    AppLogger.repo.info('FavoriteStore.reset done');
  }
}
