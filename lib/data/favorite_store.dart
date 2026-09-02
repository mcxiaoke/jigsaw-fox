import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_logger.dart';

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
class FavoriteStore {
  FavoriteStore._();
  static final FavoriteStore instance = FavoriteStore._();

  static const String _storageKey = 'jigsaw_favorites_v1';
  SharedPreferences? _prefs;
  final Map<String, FavoriteEntry> _entriesCache = {};

  /// 全局响应式 ID 集合通知器（供心形按钮和红心高亮监听）
  final ValueNotifier<Set<String>> idsNotifier = ValueNotifier<Set<String>>({});

  Future<void> init() async {
    if (_prefs != null) return;
    _prefs = await SharedPreferences.getInstance();
    await _loadFromDisk();
  }

  Future<void> _loadFromDisk() async {
    final raw = _prefs?.getString(_storageKey);
    _entriesCache.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            final entry = FavoriteEntry.fromJson(item);
            if (entry.canonicalId.isNotEmpty) {
              _entriesCache[entry.canonicalId] = entry;
            }
          }
        }
      } catch (e, st) {
        AppLogger.repo.warning('FavoriteStore._loadFromDisk fail', e, st);
      }
    }
    idsNotifier.value = Set.unmodifiable(_entriesCache.keys);
  }

  Future<void> _saveToDisk() async {
    try {
      final list = _entriesCache.values.map((e) => e.toJson()).toList();
      await _prefs?.setString(_storageKey, jsonEncode(list));
    } catch (e, st) {
      AppLogger.repo.warning('FavoriteStore._saveToDisk fail', e, st);
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
    } else {
      _entriesCache[canonicalId] = FavoriteEntry(
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
    }
    idsNotifier.value = Set.unmodifiable(_entriesCache.keys);
    await _saveToDisk();
    AppLogger.repo.info(
      'FavoriteStore.toggle cid=$canonicalId nextState=${!isFav} total=${_entriesCache.length}',
    );
    return !isFav;
  }

  /// 按收藏时间倒序返回全部收藏条目
  Future<List<FavoriteEntry>> favoritesSortedByTime() async {
    await init();
    final list = _entriesCache.values.toList();
    list.sort((a, b) => b.favoritedAt.compareTo(a.favoritedAt));
    return list;
  }

  /// 移除单条收藏
  Future<void> remove(String canonicalId) async {
    await init();
    if (_entriesCache.remove(canonicalId) != null) {
      idsNotifier.value = Set.unmodifiable(_entriesCache.keys);
      await _saveToDisk();
    }
  }

  /// 清理孤儿收藏（可选维护工具）
  Future<void> pruneOrphans(Set<String> validCanonicalIds) async {
    await init();
    final before = _entriesCache.length;
    _entriesCache.removeWhere((id, _) => !validCanonicalIds.contains(id));
    if (_entriesCache.length != before) {
      idsNotifier.value = Set.unmodifiable(_entriesCache.keys);
      await _saveToDisk();
      AppLogger.repo.info(
        'FavoriteStore.pruneOrphans removed ${before - _entriesCache.length} entries',
      );
    }
  }
}
