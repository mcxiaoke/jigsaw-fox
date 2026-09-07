import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';

/// 统一关卡运行时模型
class PuzzleLevelItem {
  const PuzzleLevelItem({
    required this.id,
    this.url = '',
    this.localPath,
    this.hash,
    this._isLocalFile,
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
    this.addedAt,
    this.unlockCoins,
    this.unlockCode,
  });

  factory PuzzleLevelItem.fromJson(Map<String, dynamic> json) {
    return PuzzleLevelItem(
      id: json['id'] as String? ?? 'unknown',
      url: json['url'] as String? ?? '',
      localPath: json['localPath'] as String?,
      isLocalFile: json['isLocalFile'] as bool?,
      hash: json['hash'] as String?,
      title: json['title'] as String?,
      order: json['order'] as int? ?? 0,
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
          const [],
      sourceModule: json['sourceModule'] as String? ?? CanonicalId.prefixMain,
      eventId: json['eventId'] as String?,
      dailyDate: json['dailyDate'] as String?,
      isTimeLocked: json['isTimeLocked'] as bool? ?? false,
      addedAt: json['addedAt'] != null
          ? DateTime.tryParse(json['addedAt'] as String)
          : null,
      unlockCoins: json['unlockCoins'] as int?,
      unlockCode: json['unlockCode'] as String?,
    );
  }

  /// 全局唯一 Canonical ID (如 "main:101", "daily:20260827", "event:cyberpunk:01")
  final String id;

  /// 远端网络绝对/相对 URL (如 "http://.../main/images/0101.webp" 或 "main/images/0101.webp")
  /// 终生保持稳定，不被本地下载路径所篡改覆盖
  final String url;

  /// 本地持久化缓存绝对路径 (如果已下载/解压落盘，如 "C:/.../101.webp")
  final String? localPath;

  /// 资源内容指纹 (SHA-256)，用于补丁换图与缓存失效检测
  final String? hash;

  final bool? _isLocalFile;

  /// 资源是否已下载在本地磁盘 (优先依据 localPath 是否存在且非空推导，也可显式指定)
  bool get isLocalFile =>
      _isLocalFile ??
      (localPath != null &&
          localPath!.isNotEmpty &&
          !localPath!.startsWith('http://') &&
          !localPath!.startsWith('https://'));

  /// 供图像加载器使用的实际路径：优先使用 localPath，无则回退使用 url
  String get displayPath =>
      (localPath != null && localPath!.isNotEmpty) ? localPath! : url;

  /// 兼容老接口访问
  String get imagePathOrUrl => displayPath;

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
  final DateTime? addedAt;
  final int? unlockCoins;
  final String? unlockCode;

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
    String? url,
    String? localPath,
    bool clearLocalPath = false,
    bool? isLocalFile,
    String? hash,
    bool clearHash = false,
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
    DateTime? addedAt,
    bool clearAddedAt = false,
    int? unlockCoins,
    bool clearUnlockCoins = false,
    String? unlockCode,
    bool clearUnlockCode = false,
  }) {
    return PuzzleLevelItem(
      id: id ?? this.id,
      url: url ?? this.url,
      localPath: clearLocalPath ? null : (localPath ?? this.localPath),
      isLocalFile: isLocalFile ?? this.isLocalFile,
      hash: clearHash ? null : (hash ?? this.hash),
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
      addedAt: clearAddedAt ? null : (addedAt ?? this.addedAt),
      unlockCoins: clearUnlockCoins ? null : (unlockCoins ?? this.unlockCoins),
      unlockCode: clearUnlockCode ? null : (unlockCode ?? this.unlockCode),
    );
  }

  bool get isNew {
    final a = addedAt;
    if (a == null || isCompleted) return false;
    return DateTime.now().difference(a).inDays < 7;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'url': url,
      if (localPath != null) 'localPath': localPath,
      'isLocalFile': isLocalFile,
      if (hash != null) 'hash': hash,
      'title': title,
      'order': order,
      'tags': tags,
      'sourceModule': sourceModule,
      'eventId': eventId,
      'dailyDate': dailyDate,
      'isTimeLocked': isTimeLocked,
      'addedAt': addedAt?.toIso8601String(),
      if (unlockCoins != null) 'unlockCoins': unlockCoins,
      if (unlockCode != null) 'unlockCode': unlockCode,
    };
  }

  @override
  String toString() =>
      'PuzzleLevelItem(id: $id, tags: $tags, isLocal: $isLocalFile, locked: $isTimeLocked)';
}
