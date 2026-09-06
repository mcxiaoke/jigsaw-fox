import 'package:flutter/foundation.dart';

/// 图集下载状态枚举
enum CollectionDownloadStatus { notDownloaded, downloading, downloaded, error }

/// 图集列表项元数据模型
/// 对齐 PuzzleEventItem 载荷结构 (支持 Zip 整包与 Array 数组双载荷，支持分类与状态追踪)
@immutable
class PuzzleCollectionItem {
  const PuzzleCollectionItem({
    required this.id,
    required this.title,
    this.desc = '',
    this.type = 'zip',
    this.collectionType = 'official',
    this.coverUrl,
    this.zipUrl,
    this.zipSha256,
    this.levels = const [],
    this.totalCount = 0,
    this.fileSizeBytes = 0,
    this.unlockCoins = 0,
    this.displayOrder = 0,
    this.status = 'active',
    this.isLocalDownloaded = false,
    this.downloadProgress = 0.0,
    this.downloadStatus = CollectionDownloadStatus.notDownloaded,
    this.startTime,
    this.endTime,
  });

  /// 图集唯一标识符 (如 "classic_art_vol1", "nature_wonders")
  final String id;

  /// 图集展示标题
  final String title;

  /// 图集详细介绍
  final String desc;

  /// 载荷类型 ('zip' | 'array')
  final String type;

  /// 图集类型/主题区分 ('official' 官方精选 | 'event' 限时活动 | 'addon' 扩展等)
  final String collectionType;

  /// 封面图 URL
  final String? coverUrl;

  /// Zip 下载包地址 (仅 type == 'zip' 时有效)
  final String? zipUrl;

  /// Zip 文件的 SHA256 哈希 (可选校验)
  final String? zipSha256;

  /// 在线关卡图片 URL 列表 (仅 type == 'array' 时有效)
  final List<String> levels;

  /// 关卡总数预估 (下载前展示)
  final int totalCount;

  /// 占用的物理磁盘或下载字节数
  final int fileSizeBytes;

  /// 解锁所需金币 (0 表示免费或由其他条件解锁)
  final int unlockCoins;

  /// 排序权重
  final int displayOrder;

  /// 状态 ('active' | 'upcoming' | 'disabled')
  final String status;

  /// 本地是否已下载并解压就绪
  final bool isLocalDownloaded;

  /// 下载进度 (0.0 ~ 1.0)
  final double downloadProgress;

  /// 实时下载状态
  final CollectionDownloadStatus downloadStatus;

  /// 活动类图集的开始时间 (可选)
  final DateTime? startTime;

  /// 活动类图集的结束时间 (可选)
  final DateTime? endTime;

  bool get isZipType => type.toLowerCase() == 'zip';
  bool get isArrayType => type.toLowerCase() == 'array';
  bool get isActive => status.toLowerCase() == 'active';
  bool get isUpcoming => status.toLowerCase() == 'upcoming';
  bool get isDisabled => status.toLowerCase() == 'disabled';
  bool get isEvent =>
      collectionType.toLowerCase() == 'event' || startTime != null;

  /// 格式化显示的友好体积 (如 "14.5 MB")
  String get displayFileSize {
    if (fileSizeBytes <= 0) return '';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 规范的类别显示文本
  String get displayTypeLabel {
    switch (collectionType.toLowerCase()) {
      case 'event':
        return '限时活动';
      case 'official':
      default:
        return '官方图集';
    }
  }

  PuzzleCollectionItem copyWith({
    String? id,
    String? title,
    String? desc,
    String? type,
    String? collectionType,
    String? coverUrl,
    String? zipUrl,
    String? zipSha256,
    List<String>? levels,
    int? totalCount,
    int? fileSizeBytes,
    int? unlockCoins,
    int? displayOrder,
    String? status,
    bool? isLocalDownloaded,
    double? downloadProgress,
    CollectionDownloadStatus? downloadStatus,
    DateTime? startTime,
    DateTime? endTime,
  }) {
    return PuzzleCollectionItem(
      id: id ?? this.id,
      title: title ?? this.title,
      desc: desc ?? this.desc,
      type: type ?? this.type,
      collectionType: collectionType ?? this.collectionType,
      coverUrl: coverUrl ?? this.coverUrl,
      zipUrl: zipUrl ?? this.zipUrl,
      zipSha256: zipSha256 ?? this.zipSha256,
      levels: levels ?? this.levels,
      totalCount: totalCount ?? this.totalCount,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      unlockCoins: unlockCoins ?? this.unlockCoins,
      displayOrder: displayOrder ?? this.displayOrder,
      status: status ?? this.status,
      isLocalDownloaded: isLocalDownloaded ?? this.isLocalDownloaded,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      downloadStatus: downloadStatus ?? this.downloadStatus,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }

  factory PuzzleCollectionItem.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return null;
      }
    }

    final rawLevels =
        (json['levels'] as List<dynamic>?)?.map((e) => e.toString()).toList() ??
        const [];

    final rawType = json['type']?.toString().toLowerCase() ?? 'zip';
    final rawColType =
        json['collectionType']?.toString().toLowerCase() ??
        (json['category']?.toString().toLowerCase() ?? 'official');

    final isDownloaded = json['isLocalDownloaded'] as bool? ?? false;

    return PuzzleCollectionItem(
      id: json['id']?.toString() ?? 'unknown_collection',
      title: json['title']?.toString() ?? '未命名图集',
      desc: json['desc']?.toString() ?? '',
      type: rawType,
      collectionType: rawColType,
      coverUrl: json['coverUrl']?.toString(),
      zipUrl: json['zipUrl']?.toString(),
      zipSha256: json['zipSha256']?.toString(),
      levels: rawLevels,
      totalCount: (json['totalCount'] as num?)?.toInt() ?? rawLevels.length,
      fileSizeBytes: (json['fileSizeBytes'] as num?)?.toInt() ?? 0,
      unlockCoins: (json['unlockCoins'] as num?)?.toInt() ?? 0,
      displayOrder: (json['displayOrder'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString().toLowerCase() ?? 'active',
      isLocalDownloaded: isDownloaded,
      downloadStatus: isDownloaded
          ? CollectionDownloadStatus.downloaded
          : CollectionDownloadStatus.notDownloaded,
      startTime: parseDate(json['startTime']),
      endTime: parseDate(json['endTime']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'desc': desc,
      'type': type,
      'collectionType': collectionType,
      'coverUrl': coverUrl,
      'zipUrl': zipUrl,
      'zipSha256': zipSha256,
      'levels': levels,
      'totalCount': totalCount,
      'fileSizeBytes': fileSizeBytes,
      'unlockCoins': unlockCoins,
      'displayOrder': displayOrder,
      'status': status,
      'isLocalDownloaded': isLocalDownloaded,
      'startTime': startTime?.toIso8601String(),
      'endTime': endTime?.toIso8601String(),
    };
  }

  @override
  String toString() =>
      'PuzzleCollectionItem(id: $id, title: $title, collectionType: $collectionType, type: $type, downloaded: $isLocalDownloaded)';
}
