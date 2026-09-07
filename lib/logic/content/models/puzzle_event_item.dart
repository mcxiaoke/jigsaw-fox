import 'package:jigsawpuzzle/utils/locale_helper.dart';

/// 活动列表项模型
class PuzzleEventItem {
  const PuzzleEventItem({
    required this.id,
    required this.title,
    required this.status,
    required this.type,
    this.titleZh,
    this.desc = '',
    this.descZh,
    this.coverUrl,
    this.zipUrl,
    this.zipUrls = const [],
    this.zipSha256,
    this.levels = const [],
    this.startTime,
    this.endTime,
    this.displayOrder = 0,
    this.totalCount = 0,
    this.fileSizeBytes = 0,
    this.isLocalDownloaded = false,
  });

  factory PuzzleEventItem.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return null;
      }
    }

    return PuzzleEventItem(
      id: json['id']?.toString() ?? 'unknown_event',
      title: json['title']?.toString() ?? '',
      titleZh: json['titleZh']?.toString(),
      status: json['status']?.toString().toLowerCase() ?? 'active',
      type: json['type']?.toString().toLowerCase() ?? 'zip',
      desc: json['desc']?.toString() ?? '',
      descZh: json['descZh']?.toString(),
      coverUrl: json['coverUrl']?.toString(),
      zipUrl: json['zipUrl']?.toString(),
      zipUrls:
          (json['zipUrls'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      zipSha256: json['zipSha256']?.toString(),
      levels:
          (json['levels'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      startTime: parseDate(json['startTime']),
      endTime: parseDate(json['endTime']),
      displayOrder: (json['displayOrder'] as num?)?.toInt() ?? 0,
      totalCount:
          (json['totalCount'] as num?)?.toInt() ??
          (json['count'] as num?)?.toInt() ??
          0,
      fileSizeBytes: (json['fileSizeBytes'] as num?)?.toInt() ?? 0,
      isLocalDownloaded: json['isLocalDownloaded'] as bool? ?? false,
    );
  }

  /// 活动唯一标识符 (如 "cyberpunk_2026")
  final String id;

  /// 活动展示标题 (默认英文)
  final String title;

  /// 活动中文标题 (可选)
  final String? titleZh;

  /// 活动状态 ('upcoming' | 'active' | 'outdated' | 'disabled')
  final String status;

  /// 载荷类型 ('zip' | 'array')
  final String type;

  /// 活动详情描述 (默认英文)
  final String desc;

  /// 活动中文描述 (可选)
  final String? descZh;

  /// 封面图 URL
  final String? coverUrl;

  /// Zip 下载包地址 (仅 type == 'zip' 时有效)
  final String? zipUrl;

  /// Zip 备用镜像地址列表 (D10：zipUrl 主地址失败时按序轮询；可为空)
  final List<String> zipUrls;

  /// Zip 文件的 SHA256 哈希 (可选校验)
  final String? zipSha256;

  /// 在线关卡图片 URL 列表 (仅 type == 'array' 时有效)
  final List<String> levels;

  /// 活动开始时间
  final DateTime? startTime;

  /// 活动结束时间
  final DateTime? endTime;

  /// 排序权重
  final int displayOrder;

  /// 关卡总数
  final int totalCount;

  /// 文件大小字节数
  final int fileSizeBytes;

  /// 本地是否已下载就绪
  final bool isLocalDownloaded;

  bool get isActive => status == 'active';
  bool get isDisabled => status == 'disabled';
  bool get isOutdated => status == 'outdated';
  bool get isUpcoming => status == 'upcoming';
  bool get isZipType => type == 'zip';
  bool get isArrayType => type == 'array';

  /// 格式化显示的友好体积 (如 "14.5 MB")
  String get displayFileSize {
    if (fileSizeBytes <= 0) return '';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 根据语言环境获取本地化标题
  /// 中文语言优先返回非空的 [titleZh]，若无则回退至默认英文 [title]；其它语言返回默认英文 [title]
  String localizedTitle([String? languageCode]) {
    if (LocaleHelper.isChinese(languageCode)) {
      final zh = titleZh?.trim();
      if (zh != null && zh.isNotEmpty) return zh;
    }
    return title;
  }

  /// 根据语言环境获取本地化描述
  /// 中文语言优先返回非空的 [descZh]，若无则回退至默认英文 [desc]；其它语言返回默认英文 [desc]
  String localizedDesc([String? languageCode]) {
    if (LocaleHelper.isChinese(languageCode)) {
      final zh = descZh?.trim();
      if (zh != null && zh.isNotEmpty) return zh;
    }
    return desc;
  }

  /// 便捷 getter：根据当前系统语言展示标题
  String get displayTitle => localizedTitle();

  /// 便捷 getter：根据当前系统语言展示描述
  String get displayDesc => localizedDesc();

  PuzzleEventItem copyWith({
    String? id,
    String? title,
    String? titleZh,
    String? status,
    String? type,
    String? desc,
    String? descZh,
    String? coverUrl,
    String? zipUrl,
    List<String>? zipUrls,
    String? zipSha256,
    List<String>? levels,
    DateTime? startTime,
    DateTime? endTime,
    int? displayOrder,
    int? totalCount,
    int? fileSizeBytes,
    bool? isLocalDownloaded,
  }) {
    return PuzzleEventItem(
      id: id ?? this.id,
      title: title ?? this.title,
      titleZh: titleZh ?? this.titleZh,
      status: status ?? this.status,
      type: type ?? this.type,
      desc: desc ?? this.desc,
      descZh: descZh ?? this.descZh,
      coverUrl: coverUrl ?? this.coverUrl,
      zipUrl: zipUrl ?? this.zipUrl,
      zipUrls: zipUrls ?? this.zipUrls,
      zipSha256: zipSha256 ?? this.zipSha256,
      levels: levels ?? this.levels,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      displayOrder: displayOrder ?? this.displayOrder,
      totalCount: totalCount ?? this.totalCount,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      isLocalDownloaded: isLocalDownloaded ?? this.isLocalDownloaded,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      if (titleZh != null) 'titleZh': titleZh,
      'status': status,
      'type': type,
      'desc': desc,
      if (descZh != null) 'descZh': descZh,
      'coverUrl': coverUrl,
      'zipUrl': zipUrl,
      if (zipUrls.isNotEmpty) 'zipUrls': zipUrls,
      'zipSha256': zipSha256,
      'levels': levels,
      'startTime': startTime?.toIso8601String(),
      'endTime': endTime?.toIso8601String(),
      'displayOrder': displayOrder,
      'totalCount': totalCount,
      'fileSizeBytes': fileSizeBytes,
      'isLocalDownloaded': isLocalDownloaded,
    };
  }

  @override
  String toString() =>
      'PuzzleEventItem(id: $id, title: $title, status: $status, type: $type)';
}
