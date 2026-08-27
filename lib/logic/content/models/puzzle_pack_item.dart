import 'package:flutter/foundation.dart';

/// 扩展图包元数据模型 (支持本地与网络导入溯源)
@immutable
class PuzzlePackItem {
  const PuzzlePackItem({
    required this.id,
    required this.title,
    this.description = '',
    this.author = '',
    required this.coverPath,
    required this.levelCount,
    required this.fileSizeBytes,
    required this.importedAt,
    required this.sourceType,
    required this.sourceOrigin,
    this.tags = const [],
  });

  /// 图包唯一物理 ID (如 pack_1787548920123_a8f1)
  final String id;

  /// 图包展示标题
  final String title;

  /// 图包描述
  final String description;

  /// 创作者署名
  final String author;

  /// 封面图片本地绝对路径
  final String coverPath;

  /// 包含的关卡总数
  final int levelCount;

  /// 占用的物理磁盘字节数
  final int fileSizeBytes;

  /// 导入时间 (ISO8601)
  final String importedAt;

  /// 导入来源类型: 'local_file' (本地ZIP) | 'network_url' (网络下载ZIP)
  final String sourceType;

  /// 原始来源物理路径或网络下载 URL (用于完整追溯)
  final String sourceOrigin;

  /// 图包标签列表
  final List<String> tags;

  /// 格式化显示的友好体积 (如 "14.5 MB")
  String get displayFileSize {
    if (fileSizeBytes <= 0) return '0 KB';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 规范合规的来源显示 (防侵权)
  String get displaySource {
    if (sourceType == 'local_file') {
      return '相册 / 本地';
    }
    return '网络';
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'author': author,
      'coverPath': coverPath,
      'levelCount': levelCount,
      'fileSizeBytes': fileSizeBytes,
      'importedAt': importedAt,
      'sourceType': sourceType,
      'sourceOrigin': sourceOrigin,
      'tags': tags,
    };
  }

  factory PuzzlePackItem.fromJson(Map<String, dynamic> json) {
    return PuzzlePackItem(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '未命名图包',
      description: json['description'] as String? ?? '',
      author: json['author'] as String? ?? '',
      coverPath: json['coverPath'] as String? ?? '',
      levelCount: json['levelCount'] as int? ?? 0,
      fileSizeBytes: json['fileSizeBytes'] as int? ?? 0,
      importedAt: json['importedAt'] as String? ?? DateTime.now().toIso8601String(),
      sourceType: json['sourceType'] as String? ?? 'local_file',
      sourceOrigin: json['sourceOrigin'] as String? ?? '',
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
    );
  }

  PuzzlePackItem copyWith({
    String? id,
    String? title,
    String? description,
    String? author,
    String? coverPath,
    int? levelCount,
    int? fileSizeBytes,
    String? importedAt,
    String? sourceType,
    String? sourceOrigin,
    List<String>? tags,
  }) {
    return PuzzlePackItem(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      author: author ?? this.author,
      coverPath: coverPath ?? this.coverPath,
      levelCount: levelCount ?? this.levelCount,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      importedAt: importedAt ?? this.importedAt,
      sourceType: sourceType ?? this.sourceType,
      sourceOrigin: sourceOrigin ?? this.sourceOrigin,
      tags: tags ?? this.tags,
    );
  }
}
