import 'dart:io';

import 'package:flutter/foundation.dart';

/// 平台安装包信息
@immutable
class PlatformUpdateInfo {
  const PlatformUpdateInfo({
    required this.url,
    required this.sha256,
    required this.size,
    this.mirrors = const <String>[],
  });

  factory PlatformUpdateInfo.fromJson(Map<String, dynamic> json) {
    final rawMirrors = json['mirrors'];
    final mirrors = <String>[];
    if (rawMirrors is List) {
      for (final m in rawMirrors) {
        if (m is String && m.isNotEmpty) {
          mirrors.add(m);
        }
      }
    }

    return PlatformUpdateInfo(
      url: json['url'] as String? ?? '',
      sha256: json['sha256'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      mirrors: mirrors,
    );
  }

  /// 相对路径或绝对路径
  final String url;

  /// SHA256 哈希
  final String sha256;

  /// 文件字节大小
  final int size;

  /// 备用镜像绝对地址
  final List<String> mirrors;

  /// 拼接完整主源下载地址
  String fullUrl(String base) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    final normalizedBase = base.endsWith('/') ? base : '$base/';
    final cleanPath = url.startsWith('/') ? url.substring(1) : url;
    return '$normalizedBase$cleanPath';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'sha256': sha256,
    'size': size,
    'mirrors': mirrors,
  };
}

/// 自动更新清单（updates.json）
@immutable
class UpdateManifest {
  const UpdateManifest({
    required this.schema,
    required this.version,
    required this.versionCode,
    this.minVersionCode = 1,
    this.publishedAt = '',
    this.notes = const <String, String>{},
    this.platforms = const <String, PlatformUpdateInfo>{},
    this.androidAbis = const <String, PlatformUpdateInfo>{},
  });

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final rawPlatforms = json['platforms'];
    final platforms = <String, PlatformUpdateInfo>{};
    final androidAbis = <String, PlatformUpdateInfo>{};

    if (rawPlatforms is Map<String, dynamic>) {
      for (final entry in rawPlatforms.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        final valMap = entry.value as Map<String, dynamic>;

        if (entry.key == 'android') {
          // 判断是单包还是分 ABI Map
          if (valMap.containsKey('url')) {
            platforms['android'] = PlatformUpdateInfo.fromJson(valMap);
            androidAbis['all'] = platforms['android']!;
          } else {
            // 包含多个 ABI (arm64-v8a, armeabi-v7a, x86_64, all)
            for (final abiEntry in valMap.entries) {
              if (abiEntry.value is Map<String, dynamic>) {
                final abiInfo = PlatformUpdateInfo.fromJson(
                  abiEntry.value as Map<String, dynamic>,
                );
                androidAbis[abiEntry.key] = abiInfo;
              }
            }
            if (androidAbis.containsKey('all')) {
              platforms['android'] = androidAbis['all']!;
            } else if (androidAbis.isNotEmpty) {
              platforms['android'] = androidAbis.values.first;
            }
          }
        } else {
          platforms[entry.key] = PlatformUpdateInfo.fromJson(valMap);
        }
      }
    }

    final rawNotes = json['notes'];
    final notes = <String, String>{};
    if (rawNotes is Map<String, dynamic>) {
      for (final entry in rawNotes.entries) {
        if (entry.value is String) {
          notes[entry.key] = entry.value as String;
        }
      }
    }

    return UpdateManifest(
      schema: (json['schema'] as num?)?.toInt() ?? 1,
      version: json['version'] as String? ?? '',
      versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
      minVersionCode: (json['minVersionCode'] as num?)?.toInt() ?? 1,
      publishedAt: json['publishedAt'] as String? ?? '',
      notes: notes,
      platforms: platforms,
      androidAbis: androidAbis,
    );
  }

  final int schema;
  final String version;
  final int versionCode;
  final int minVersionCode;
  final String publishedAt;
  final Map<String, String> notes;
  final Map<String, PlatformUpdateInfo> platforms;
  final Map<String, PlatformUpdateInfo> androidAbis;

  /// 根据当前运行平台获取对应的安装包信息
  PlatformUpdateInfo? get forCurrentPlatform => getPackageForPlatform();

  /// 获取指定平台与 ABI 的安装包
  PlatformUpdateInfo? getPackageForPlatform({
    List<String>? supportedAbis,
    String? androidAbi,
  }) {
    if (kIsWeb) return null;
    if (Platform.isAndroid) {
      return getAndroidPackage(
        supportedAbis: supportedAbis,
        preferredAbi: androidAbi,
      );
    }
    if (Platform.isWindows) {
      return platforms['windows'];
    }
    return null;
  }

  /// 获取最匹配当前设备的 Android 安装包（按设备支持 ABI 优先级尝试，带降级兜底）
  PlatformUpdateInfo? getAndroidPackage({
    List<String>? supportedAbis,
    String? preferredAbi,
  }) {
    if (preferredAbi != null && androidAbis.containsKey(preferredAbi)) {
      return androidAbis[preferredAbi];
    }
    if (supportedAbis != null && supportedAbis.isNotEmpty) {
      for (final abi in supportedAbis) {
        if (androidAbis.containsKey(abi)) {
          return androidAbis[abi];
        }
      }
    }
    // 兜底策略：查找 all -> universal -> platforms['android'] -> 第一个可用包
    if (androidAbis.containsKey('all')) {
      return androidAbis['all'];
    }
    if (androidAbis.containsKey('universal')) {
      return androidAbis['universal'];
    }
    if (platforms.containsKey('android')) {
      return platforms['android'];
    }
    if (androidAbis.isNotEmpty) {
      return androidAbis.values.first;
    }
    return null;
  }

  /// 获取对应语言的更新日志说明
  String notesForLocale(String languageCode) {
    if (notes.isEmpty) return '';
    // 精确匹配 zh-CN / en-US
    if (notes.containsKey(languageCode)) {
      return notes[languageCode]!;
    }
    // 前缀匹配 zh -> zh-CN
    for (final entry in notes.entries) {
      if (entry.key.toLowerCase().startsWith(languageCode.toLowerCase())) {
        return entry.value;
      }
    }
    return notes['zh-CN'] ?? notes.values.first;
  }

  Map<String, dynamic> toJson() {
    final platformsMap = <String, dynamic>{};
    for (final entry in platforms.entries) {
      if (entry.key == 'android' && androidAbis.isNotEmpty) {
        platformsMap['android'] = androidAbis.map(
          (k, v) => MapEntry(k, v.toJson()),
        );
      } else {
        platformsMap[entry.key] = entry.value.toJson();
      }
    }

    return <String, dynamic>{
      'schema': schema,
      'version': version,
      'versionCode': versionCode,
      'minVersionCode': minVersionCode,
      'publishedAt': publishedAt,
      'notes': notes,
      'platforms': platformsMap,
    };
  }
}

/// 更新检查状态枚举
enum UpdateStatus {
  noUpdate,
  updateAvailable,
  forceUpdateRequired,
  skipped,
  error,
}

/// 更新检查结果封装
@immutable
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    this.manifest,
    this.platformInfo,
    this.currentVersion = '',
    this.currentVersionCode = 0,
    this.errorMessage,
  });

  final UpdateStatus status;
  final UpdateManifest? manifest;
  final PlatformUpdateInfo? platformInfo;
  final String currentVersion;
  final int currentVersionCode;
  final String? errorMessage;

  bool get hasUpdate =>
      status == UpdateStatus.updateAvailable ||
      status == UpdateStatus.forceUpdateRequired;

  bool get isForceUpdate => status == UpdateStatus.forceUpdateRequired;
}
