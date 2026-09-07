import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';

/// Represents an image downloaded from online image sources (Pixabay, Unsplash, Pexels, etc.)
enum DownloadedQuality {
  q4k,
  q2k,
  q1080,
  q720,
  sd;

  String get key => name;

  /// 画质档展示文案（按当前语言）
  String localizedLabel() {
    final tr = LocaleSettings.instance.currentTranslations.downloads;
    return switch (this) {
      DownloadedQuality.q4k => tr.q4k,
      DownloadedQuality.q2k => tr.q2k,
      DownloadedQuality.q1080 => tr.q1080,
      DownloadedQuality.q720 => tr.q720,
      DownloadedQuality.sd => tr.qsd,
    };
  }
}

class DownloadedImageItem {
  const DownloadedImageItem({
    required this.id,
    required this.localPath,
    required this.sourcePlatform,
    required this.sourceUrl,
    required this.width,
    required this.height,
    required this.fileSizeBytes,
    required this.downloadedAt,
  });

  factory DownloadedImageItem.fromJson(Map<String, dynamic> json) {
    return DownloadedImageItem(
      id:
          json['id'] as String? ??
          'img_${DateTime.now().millisecondsSinceEpoch}',
      localPath: json['localPath'] as String? ?? '',
      sourcePlatform: json['sourcePlatform'] as String? ?? 'online',
      sourceUrl: json['sourceUrl'] as String? ?? '',
      width: json['width'] as int? ?? 1080,
      height: json['height'] as int? ?? 1080,
      fileSizeBytes: json['fileSizeBytes'] as int? ?? 0,
      downloadedAt: json['downloadedAt'] != null
          ? DateTime.tryParse(json['downloadedAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  final String id;
  final String localPath;
  final String sourcePlatform;
  final String sourceUrl;
  final int width;
  final int height;
  final int fileSizeBytes;
  final DateTime downloadedAt;

  String get resolutionLabel => '$width × $height';

  /// 画质档位（阈值逻辑不变，文案改由 UI 层按语言渲染）
  DownloadedQuality get qualityTier {
    if (width >= 3840 || height >= 2160) return DownloadedQuality.q4k;
    if (width >= 2560 || height >= 1440) return DownloadedQuality.q2k;
    if (width >= 1920 || height >= 1080) return DownloadedQuality.q1080;
    if (width >= 1280 || height >= 720) return DownloadedQuality.q720;
    return DownloadedQuality.sd;
  }

  String get fileSizeLabel {
    if (fileSizeBytes <= 0) return '0 KB';
    final kb = fileSizeBytes / 1024.0;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }
    final mb = kb / 1024.0;
    return '${mb.toStringAsFixed(1)} MB';
  }

  DownloadedImageItem copyWith({
    String? id,
    String? localPath,
    String? sourcePlatform,
    String? sourceUrl,
    int? width,
    int? height,
    int? fileSizeBytes,
    DateTime? downloadedAt,
  }) {
    return DownloadedImageItem(
      id: id ?? this.id,
      localPath: localPath ?? this.localPath,
      sourcePlatform: sourcePlatform ?? this.sourcePlatform,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      width: width ?? this.width,
      height: height ?? this.height,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      downloadedAt: downloadedAt ?? this.downloadedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'localPath': localPath,
    'sourcePlatform': sourcePlatform,
    'sourceUrl': sourceUrl,
    'width': width,
    'height': height,
    'fileSizeBytes': fileSizeBytes,
    'downloadedAt': downloadedAt.toIso8601String(),
  };
}
