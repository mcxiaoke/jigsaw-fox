import 'canonical_id.dart';

/// 统一关卡运行时模型
class PuzzleLevelItem {
  const PuzzleLevelItem({
    required this.id,
    required this.imagePathOrUrl,
    required this.isLocalFile,
    this.title,
    this.order = 0,
    this.tags = const [],
    this.sourceModule = CanonicalId.prefixMain,
    this.eventId,
    this.dailyDate,
    this.isTimeLocked = false,
    this.isUnlocked = false,
    this.isCompleted = false,
    this.completedPieceCounts = const [],
    this.bestTimeSeconds = 0,
    this.hasSavedSnapshot = false,
  });

  /// 全局唯一 Canonical ID (如 "main:101", "daily:20260827", "event:cyberpunk:01")
  final String id;

  /// 本地绝对路径、Asset 路径或网络 CDN URL
  final String imagePathOrUrl;

  /// 资源是否已下载在本地磁盘 (可直接离线秒开)
  final bool isLocalFile;

  /// 自定义展示标题 (可选，若无则由 displayTitle 自动推导)
  final String? title;

  /// 排序权重 (如首页关卡 101, 102...)
  final int order;

  /// 关卡分类与多标签 (如 ["animal", "cute", "panda"])
  final List<String> tags;

  /// 来源模块 ('main' | 'daily' | 'events' | 'pack' | 'ugc')
  final String sourceModule;

  /// 所属活动 ID (仅活动关卡有效)
  final String? eventId;

  /// 所属日期 YYYYMMDD (仅每日挑战有效)
  final String? dailyDate;

  /// 是否受每日时间锁限制 (未来日期加锁防剧透)
  final bool isTimeLocked;

  // --- 玩家存档状态 ---
  final bool isUnlocked;
  final bool isCompleted;
  final List<int> completedPieceCounts;
  final int bestTimeSeconds;
  final bool hasSavedSnapshot;

  /// UI 展示标题快捷推导 (零元数据下的友好默认标题)
  String get displayTitle {
    if (title != null && title!.trim().isNotEmpty) {
      return title!.trim();
    }
    if (id.startsWith('${CanonicalId.prefixMain}:')) {
      return '#${id.substring(CanonicalId.prefixMain.length + 1)}';
    }
    if (id.startsWith('${CanonicalId.prefixDaily}:')) {
      final d = id.substring(CanonicalId.prefixDaily.length + 1);
      if (d.length == 8) {
        return '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)}';
      }
      return d;
    }
    // 默认取最后一段
    return id.split(':').last;
  }

  /// 复制并更新部分属性
  PuzzleLevelItem copyWith({
    String? id,
    String? imagePathOrUrl,
    bool? isLocalFile,
    String? title,
    int? order,
    List<String>? tags,
    String? sourceModule,
    String? eventId,
    String? dailyDate,
    bool? isTimeLocked,
    bool? isUnlocked,
    bool? isCompleted,
    List<int>? completedPieceCounts,
    int? bestTimeSeconds,
    bool? hasSavedSnapshot,
  }) {
    return PuzzleLevelItem(
      id: id ?? this.id,
      imagePathOrUrl: imagePathOrUrl ?? this.imagePathOrUrl,
      isLocalFile: isLocalFile ?? this.isLocalFile,
      title: title ?? this.title,
      order: order ?? this.order,
      tags: tags ?? this.tags,
      sourceModule: sourceModule ?? this.sourceModule,
      eventId: eventId ?? this.eventId,
      dailyDate: dailyDate ?? this.dailyDate,
      isTimeLocked: isTimeLocked ?? this.isTimeLocked,
      isUnlocked: isUnlocked ?? this.isUnlocked,
      isCompleted: isCompleted ?? this.isCompleted,
      completedPieceCounts: completedPieceCounts ?? this.completedPieceCounts,
      bestTimeSeconds: bestTimeSeconds ?? this.bestTimeSeconds,
      hasSavedSnapshot: hasSavedSnapshot ?? this.hasSavedSnapshot,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'imagePathOrUrl': imagePathOrUrl,
      'isLocalFile': isLocalFile,
      'title': title,
      'order': order,
      'tags': tags,
      'sourceModule': sourceModule,
      'eventId': eventId,
      'dailyDate': dailyDate,
      'isTimeLocked': isTimeLocked,
    };
  }

  factory PuzzleLevelItem.fromJson(Map<String, dynamic> json) {
    return PuzzleLevelItem(
      id: json['id'] as String? ?? 'unknown',
      imagePathOrUrl: json['imagePathOrUrl'] as String? ?? '',
      isLocalFile: json['isLocalFile'] as bool? ?? false,
      title: json['title'] as String?,
      order: json['order'] as int? ?? 0,
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
          const [],
      sourceModule: json['sourceModule'] as String? ?? CanonicalId.prefixMain,
      eventId: json['eventId'] as String?,
      dailyDate: json['dailyDate'] as String?,
      isTimeLocked: json['isTimeLocked'] as bool? ?? false,
    );
  }

  @override
  String toString() =>
      'PuzzleLevelItem(id: $id, tags: $tags, isLocal: $isLocalFile, locked: $isTimeLocked)';
}
